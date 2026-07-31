import XCTest
@testable import Ping_Island

final class AIApprovalDecisionServiceTests: XCTestCase {
    private actor StubTransport: AIApprovalHTTPTransport {
        private var responses: [(Data, URLResponse)]
        private var requests: [URLRequest] = []

        init(responses: [(Data, URLResponse)]) {
            self.responses = responses
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            guard !responses.isEmpty else {
                throw URLError(.badServerResponse)
            }
            return responses.removeFirst()
        }

        func capturedRequests() -> [URLRequest] {
            requests
        }
    }

    func testChatCompletionsURLAppendsEndpoint() throws {
        XCTAssertEqual(
            try OpenAICompatibleApprovalClient.chatCompletionsURL(from: "https://example.com/v1/").absoluteString,
            "https://example.com/v1/chat/completions"
        )
        XCTAssertEqual(
            try OpenAICompatibleApprovalClient.chatCompletionsURL(
                from: "https://example.com/openai/chat/completions"
            ).absoluteString,
            "https://example.com/openai/chat/completions"
        )
    }

    func testHTTPOnlyAllowsLoopbackHosts() throws {
        XCTAssertNoThrow(try OpenAICompatibleApprovalClient.chatCompletionsURL(from: "http://localhost:11434/v1"))
        XCTAssertNoThrow(try OpenAICompatibleApprovalClient.chatCompletionsURL(from: "http://127.0.0.1:8080/v1"))
        XCTAssertThrowsError(
            try OpenAICompatibleApprovalClient.chatCompletionsURL(from: "http://models.example.com/v1")
        ) { error in
            XCTAssertEqual(error as? AIApprovalServiceError, .insecureHTTPHost)
        }
    }

    func testClientSendsBearerAndParsesStructuredDecision() async throws {
        let endpoint = URL(string: "https://example.com/v1/chat/completions")!
        let responseData = try JSONSerialization.data(withJSONObject: [
            "choices": [[
                "message": [
                    "content": "{\"decision\":\"approve\",\"risk\":\"low\",\"reason\":\"Read-only inspection\"}"
                ]
            ]]
        ])
        let transport = StubTransport(responses: [
            (responseData, HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        ])
        let client = OpenAICompatibleApprovalClient(transport: transport)

        let result = try await client.decide(
            configuration: configuration(apiKey: "test-key"),
            context: context()
        )

        XCTAssertEqual(result.decision, AIApprovalDecision(
            decision: .approve,
            risk: .low,
            reason: "Read-only inspection"
        ))
        let capturedRequests = await transport.capturedRequests()
        let request = try XCTUnwrap(capturedRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let responseFormat = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
    }

    func testUnsupportedSchemaFallsBackWithoutResponseFormat() async throws {
        let endpoint = URL(string: "https://example.com/v1/chat/completions")!
        let unsupportedData = try JSONSerialization.data(withJSONObject: [
            "error": ["message": "response_format is unsupported"]
        ])
        let successData = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": "{\"decision\":\"deny\",\"risk\":\"high\",\"reason\":\"Destructive\"}"]]]
        ])
        let transport = StubTransport(responses: [
            (unsupportedData, HTTPURLResponse(url: endpoint, statusCode: 400, httpVersion: nil, headerFields: nil)!),
            (successData, HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        ])
        let client = OpenAICompatibleApprovalClient(transport: transport)

        let result = try await client.decide(configuration: configuration(), context: context())

        XCTAssertEqual(result.decision.decision, .deny)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        let secondBody = try XCTUnwrap(requests.last?.httpBody)
        let secondJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: secondBody) as? [String: Any])
        XCTAssertNil(secondJSON["response_format"])
    }

    func testRateLimitResponseRetriesBeforeFailingApproval() async throws {
        let endpoint = URL(string: "https://example.com/v1/chat/completions")!
        let limitedData = try JSONSerialization.data(withJSONObject: [
            "error": ["message": "try again"]
        ])
        let successData = try JSONSerialization.data(withJSONObject: [
            "choices": [[
                "message": [
                    "content": "{\"decision\":\"approve\",\"risk\":\"low\",\"reason\":\"Safe\"}"
                ]
            ]]
        ])
        let transport = StubTransport(responses: [
            (limitedData, HTTPURLResponse(url: endpoint, statusCode: 429, httpVersion: nil, headerFields: nil)!),
            (successData, HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        ])
        let client = OpenAICompatibleApprovalClient(transport: transport)

        let result = try await client.decide(configuration: configuration(), context: context())

        XCTAssertEqual(result.decision.decision, .approve)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func testExecutionPolicyUsesManualRiskSelection() {
        let lowApprove = AIApprovalDecision(decision: .approve, risk: .low, reason: "ok")
        let highApprove = AIApprovalDecision(decision: .approve, risk: .high, reason: "risky")
        let lowDeny = AIApprovalDecision(decision: .deny, risk: .low, reason: "deny")

        XCTAssertFalse(AIApprovalExecutionPolicy.shouldExecute(
            isEnabled: false, manualRiskLevels: [], decision: lowApprove
        ))
        XCTAssertTrue(AIApprovalExecutionPolicy.shouldExecute(
            isEnabled: true, manualRiskLevels: [.medium, .high], decision: lowApprove
        ))
        XCTAssertFalse(AIApprovalExecutionPolicy.shouldExecute(
            isEnabled: true, manualRiskLevels: [.medium, .high], decision: highApprove
        ))
        XCTAssertTrue(AIApprovalExecutionPolicy.shouldExecute(
            isEnabled: true, manualRiskLevels: [.medium, .high], decision: lowDeny
        ))
    }

    func testPresentationPolicyKeepsEvaluationSilentUnlessHintIsEnabled() {
        let evaluating = AIApprovalPresentationState(toolUseID: "tool-1", phase: .evaluating)

        XCTAssertFalse(AIApprovalPresentationPolicy.shouldPresentManualApproval(
            needsApprovalResponse: true,
            state: evaluating
        ))
        XCTAssertFalse(AIApprovalPresentationPolicy.shouldPresentAutomatically(
            needsApprovalResponse: true,
            state: evaluating,
            showEvaluatingHint: false
        ))
        XCTAssertTrue(AIApprovalPresentationPolicy.shouldPresentAutomatically(
            needsApprovalResponse: true,
            state: evaluating,
            showEvaluatingHint: true
        ))
    }

    func testPresentationPolicySurfacesManualRecommendationAndFailure() {
        let recommendation = AIApprovalPresentationState(
            toolUseID: "tool-1",
            phase: .recommendation(decision: .approve, risk: .high, reason: "Needs review")
        )
        let failed = AIApprovalPresentationState(
            toolUseID: "tool-2",
            phase: .failed(message: "Unavailable")
        )

        for state in [recommendation, failed] {
            XCTAssertTrue(AIApprovalPresentationPolicy.shouldPresentManualApproval(
                needsApprovalResponse: true,
                state: state
            ))
            XCTAssertTrue(AIApprovalPresentationPolicy.shouldPresentAutomatically(
                needsApprovalResponse: true,
                state: state,
                showEvaluatingHint: false
            ))
        }
    }

    func testContextBuilderPreservesCompleteConversationAndToolFields() throws {
        let intervention = SessionIntervention(
            id: "tool-1",
            kind: .approval,
            title: "Approve command",
            message: "Run a command",
            options: [],
            questions: [],
            supportsSessionScope: true,
            metadata: ["originalToolUseId": "tool-1"]
        )
        let history = (0..<8).map { index in
            ChatHistoryItem(
                id: "message-\(index)",
                type: index.isMultiple(of: 2) ? .user("user \(index)") : .assistant("assistant \(index)"),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        } + [
            ChatHistoryItem(id: "thinking", type: .thinking("private thought"), timestamp: Date())
        ]
        let session = SessionState(
            sessionId: "session-1",
            cwd: "/workspace/project",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            intervention: intervention,
            phase: .waitingForApproval(PermissionContext(
                toolUseId: "tool-1",
                toolName: "Bash",
                toolInput: nil,
                receivedAt: Date()
            )),
            chatItems: history
        )
        let event = HookEvent(
            sessionId: "session-1",
            cwd: "/workspace/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            pid: nil,
            tty: nil,
            tool: "Bash",
            toolInput: [
                "command": AnyCodable("make test"),
                "api_token": AnyCodable("must-not-leak")
            ],
            toolUseId: "tool-1",
            notificationType: nil,
            message: nil
        )

        let context = try XCTUnwrap(AIApprovalContextBuilder.makeContext(event: event, session: session))

        XCTAssertEqual(context.recentConversation.count, 8)
        XCTAssertFalse(context.recentConversation.contains { $0.content.contains("private thought") })
        XCTAssertEqual(context.toolInput["api_token"]?.value as? String, "must-not-leak")
        XCTAssertEqual(context.toolInput["command"]?.value as? String, "make test")
    }

    @MainActor
    func testAuditStorePrunesExpiredAndExcessRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-approval-audit-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("audit.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AIApprovalAuditStore(fileURL: fileURL)
        let now = Date()
        store.append(auditRecord(createdAt: now.addingTimeInterval(-AIApprovalAuditStore.retentionInterval - 1)), now: now)
        store.append(auditRecord(createdAt: now), now: now)

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.createdAt, now)
        let exported = try XCTUnwrap(
            JSONSerialization.jsonObject(with: store.exportData()) as? [[String: Any]]
        )
        XCTAssertEqual(exported.first?["sessionID"] as? String, "session-1")
        let exportedContext = try XCTUnwrap(exported.first?["context"] as? [String: Any])
        let exportedToolInput = try XCTUnwrap(exportedContext["toolInput"] as? [String: Any])
        XCTAssertEqual(exportedToolInput["api_token"] as? String, "complete-value")

        let excessRecords = (0...AIApprovalAuditStore.maximumRecordCount).map { offset in
            auditRecord(createdAt: now.addingTimeInterval(-TimeInterval(offset)))
        }
        try JSONEncoder().encode(excessRecords).write(to: fileURL, options: .atomic)
        let cappedStore = AIApprovalAuditStore(fileURL: fileURL)
        XCTAssertEqual(cappedStore.records.count, AIApprovalAuditStore.maximumRecordCount)

        cappedStore.clear()
        XCTAssertTrue(cappedStore.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testAuditSummaryPreservesTokenLikeHookValues() {
        let context = AIApprovalRequestContext(
            sessionID: "session-1",
            toolUseID: "tool-1",
            ingress: .hookBridge,
            provider: "claude",
            client: "Claude Code",
            cwd: "/workspace/project",
            toolName: "Bash",
            interventionTitle: "Approve command",
            interventionMessage: "Run a command",
            toolInput: ["command": AnyCodable("curl -H 'Authorization: sk-secret123' https://example.com")],
            recentConversation: []
        )

        let summary = AIApprovalContextBuilder.auditSummary(from: context)

        XCTAssertTrue(summary.contains("sk-secret123"))
        XCTAssertFalse(summary.contains("[redacted]"))
    }

    @MainActor
    func testAuditErrorDoesNotPersistConfiguredAPIKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-approval-error-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = AIApprovalAuditStore(fileURL: directory.appendingPathComponent("audit.json"))
        let service = AIApprovalDecisionService(auditStore: auditStore)
        let apiKey = "provider-specific-secret-value"

        _ = service.record(
            configuration: configuration(apiKey: apiKey),
            context: context(),
            evaluation: nil,
            outcome: .failed,
            error: AIApprovalServiceError.httpError(400, "Credential \(apiKey) was rejected")
        )

        let storedError = try XCTUnwrap(auditStore.records.first?.error)
        XCTAssertFalse(storedError.contains(apiKey))
        XCTAssertTrue(storedError.contains("[redacted]"))
    }

    private func configuration(apiKey: String? = nil) -> AIApprovalConfiguration {
        AIApprovalConfiguration(
            isEnabledByUser: true,
            manualRiskLevels: [],
            baseURL: "https://example.com/v1",
            model: "test-model",
            policy: "Approve read-only inspection.",
            apiKey: apiKey
        )
    }

    private func context() -> AIApprovalRequestContext {
        AIApprovalRequestContext(
            sessionID: "session-1",
            toolUseID: "tool-1",
            ingress: .hookBridge,
            provider: "claude",
            client: "Claude Code",
            cwd: "/workspace/project",
            toolName: "Read",
            interventionTitle: "Approve read",
            interventionMessage: "Read a project file",
            toolInput: ["path": AnyCodable("README.md")],
            recentConversation: [.init(role: "user", content: "Inspect the README")]
        )
    }

    private func auditRecord(createdAt: Date) -> AIApprovalAuditRecord {
        AIApprovalAuditRecord(
            id: UUID(),
            createdAt: createdAt,
            sessionID: "session-1",
            toolUseID: "tool-1",
            provider: "claude",
            client: "Claude Code",
            model: "test-model",
            toolName: "Read",
            toolSummary: "README.md",
            decision: .approve,
            risk: .low,
            reason: "Read-only",
            latencyMilliseconds: 10,
            outcome: .autoApproved,
            error: nil,
            context: AIApprovalAuditContext(
                toolUseID: "tool-1",
                ingress: "hookBridge",
                cwd: "/workspace/project",
                interventionTitle: "Approve read",
                interventionMessage: "Read a project file",
                toolInput: ["api_token": AnyCodable("complete-value")],
                conversation: [.init(role: "user", content: "Inspect the README")]
            )
        )
    }
}
