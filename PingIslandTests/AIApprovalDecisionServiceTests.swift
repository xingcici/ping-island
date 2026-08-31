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

    private actor ErrorTransport: AIApprovalHTTPTransport {
        private let error: Error
        private var requestCount = 0

        init(error: Error) {
            self.error = error
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requestCount += 1
            throw error
        }

        func capturedRequestCount() -> Int {
            requestCount
        }
    }

    private actor ConcurrencyProbe {
        private var activeCount = 0
        private var maximumActiveCount = 0
        private var completedCount = 0

        func enter() {
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)
        }

        func leave() {
            activeCount -= 1
            completedCount += 1
        }

        func snapshot() -> (maximum: Int, completed: Int) {
            (maximumActiveCount, completedCount)
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
        XCTAssertNil(json["enable_thinking"])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let userMessage = try XCTUnwrap(messages.last?["content"] as? String)
        let modelContext = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(userMessage.utf8)) as? [String: Any]
        )
        XCTAssertEqual(modelContext["context_strategy"] as? String, "summary_recent_window")
        XCTAssertEqual(modelContext["latest_user_instruction"] as? String, "Inspect the README")
    }

    func testQwen37FlashDisablesThinkingInRequestBody() async throws {
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

        _ = try await client.decide(
            configuration: configuration(model: " qwen3.7-flash-2026-08-01 "),
            context: context()
        )

        let capturedRequests = await transport.capturedRequests()
        let request = try XCTUnwrap(capturedRequests.first)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["enable_thinking"] as? Bool, false)
        XCTAssertNotNil(json["response_format"])
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

    func testInvalidDecisionPayloadFailsClosed() async throws {
        let endpoint = URL(string: "https://example.com/v1/chat/completions")!
        let invalidPayloads = [
            "{\"decision\":\"maybe\",\"risk\":\"low\",\"reason\":\"Unknown\"}",
            "{\"decision\":\"approve\",\"risk\":\"extreme\",\"reason\":\"Unknown\"}",
            "{\"decision\":\"approve\",\"risk\":\"low\",\"reason\":\"   \"}"
        ]

        for content in invalidPayloads {
            let responseData = try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": content]]]
            ])
            let transport = StubTransport(responses: [
                (responseData, HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            ])
            let client = OpenAICompatibleApprovalClient(transport: transport)

            do {
                _ = try await client.decide(configuration: configuration(), context: context())
                XCTFail("Invalid model output must not produce an approval decision")
            } catch {
                XCTAssertEqual(error as? AIApprovalServiceError, .invalidResponse)
            }
        }
    }

    func testUnauthorizedResponseDoesNotRetryOrHideProviderMessage() async throws {
        let endpoint = URL(string: "https://example.com/v1/chat/completions")!
        let responseData = try JSONSerialization.data(withJSONObject: [
            "error": ["message": "Authorization required"]
        ])
        let transport = StubTransport(responses: [
            (responseData, HTTPURLResponse(url: endpoint, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        ])
        let client = OpenAICompatibleApprovalClient(transport: transport)

        do {
            _ = try await client.decide(configuration: configuration(), context: context())
            XCTFail("HTTP 401 must fail closed")
        } catch {
            XCTAssertEqual(
                error as? AIApprovalServiceError,
                .httpError(401, "Authorization required")
            )
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testTransportTimeoutMapsToStableApprovalErrorWithoutRetry() async throws {
        let transport = ErrorTransport(error: URLError(.timedOut))
        let client = OpenAICompatibleApprovalClient(transport: transport)

        do {
            _ = try await client.decide(configuration: configuration(), context: context())
            XCTFail("A timed out request must fall back to manual approval")
        } catch {
            XCTAssertEqual(error as? AIApprovalServiceError, .timedOut)
        }
        let requestCount = await transport.capturedRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testConfigurationValidationRejectsMissingModelAndUnsafeEndpoints() async throws {
        let client = OpenAICompatibleApprovalClient(transport: StubTransport(responses: []))
        let invalidConfigurations = [
            AIApprovalConfiguration(
                isEnabledByUser: true,
                manualRiskLevels: [],
                baseURL: "not-a-url",
                model: "test-model",
                policy: "",
                apiKey: nil
            ),
            AIApprovalConfiguration(
                isEnabledByUser: true,
                manualRiskLevels: [],
                baseURL: "http://models.example.com/v1",
                model: "test-model",
                policy: "",
                apiKey: nil
            ),
            AIApprovalConfiguration(
                isEnabledByUser: true,
                manualRiskLevels: [],
                baseURL: "https://example.com/v1",
                model: "   ",
                policy: "",
                apiKey: nil
            )
        ]
        let expectedErrors: [AIApprovalServiceError] = [.invalidBaseURL, .insecureHTTPHost, .missingModel]

        for (configuration, expectedError) in zip(invalidConfigurations, expectedErrors) {
            do {
                _ = try await client.decide(configuration: configuration, context: context())
                XCTFail("Invalid configuration must fail before sending a request")
            } catch {
                XCTAssertEqual(error as? AIApprovalServiceError, expectedError)
            }
        }
    }

    func testConcurrencyLimiterCapsParallelEvaluationsAndDrainsQueue() async {
        let limiter = AIApprovalConcurrencyLimiter(limit: 4)
        let probe = ConcurrencyProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await limiter.run {
                        await probe.enter()
                        try? await Task.sleep(for: .milliseconds(20))
                        await probe.leave()
                    }
                }
            }
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.maximum, 4)
        XCTAssertEqual(snapshot.completed, 20)
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

    func testExecutionPolicyCoversEveryRiskDecisionAndManualSelection() {
        let risks = AIApprovalRisk.allCases
        let selections: [Set<AIApprovalRisk>] = [
            [],
            [.low], [.medium], [.high],
            [.low, .medium], [.low, .high], [.medium, .high],
            Set(risks)
        ]

        for selection in selections {
            for risk in risks {
                for choice in [AIApprovalDecisionChoice.approve, .deny] {
                    let decision = AIApprovalDecision(
                        decision: choice,
                        risk: risk,
                        reason: "matrix"
                    )
                    XCTAssertEqual(
                        AIApprovalExecutionPolicy.shouldExecute(
                            isEnabled: true,
                            manualRiskLevels: selection,
                            decision: decision
                        ),
                        !selection.contains(risk),
                        "choice=\(choice.rawValue) risk=\(risk.rawValue) selection=\(selection)"
                    )
                }
            }
        }
    }

    func testRiskFloorPromotesGitResetHardToHighRisk() {
        let mediumDecision = AIApprovalDecision(
            decision: .approve,
            risk: .medium,
            reason: "Scoped temporary repository"
        )
        let destructiveContext = AIApprovalRequestContext(
            sessionID: "session-1",
            toolUseID: "tool-reset-hard",
            ingress: .hookBridge,
            provider: "codex",
            client: "Codex",
            cwd: "/workspace/project",
            toolName: "Bash",
            interventionTitle: "Approve command",
            interventionMessage: "Run git reset",
            toolInput: [
                "command": AnyCodable("/usr/bin/git -C /workspace/project reset --hard")
            ],
            recentConversation: []
        )
        let reversibleContext = AIApprovalRequestContext(
            sessionID: "session-1",
            toolUseID: "tool-reset-soft",
            ingress: .hookBridge,
            provider: "codex",
            client: "Codex",
            cwd: "/workspace/project",
            toolName: "Bash",
            interventionTitle: "Approve command",
            interventionMessage: "Run git reset",
            toolInput: ["command": AnyCodable("git reset --soft HEAD~1")],
            recentConversation: []
        )

        XCTAssertEqual(
            AIApprovalRiskFloor.applying(to: mediumDecision, context: destructiveContext).risk,
            .high
        )
        XCTAssertEqual(
            AIApprovalRiskFloor.applying(to: mediumDecision, context: reversibleContext).risk,
            .medium
        )
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

    func testPresentationPolicySuppressesAutomaticallyResolvedApproval() {
        let resolved = AIApprovalPresentationState(
            toolUseID: "tool-1",
            phase: .automaticallyResolved(
                decision: .approve,
                risk: .low,
                reason: "Safe"
            )
        )

        XCTAssertFalse(AIApprovalPresentationPolicy.shouldPresentManualApproval(
            needsApprovalResponse: true,
            state: resolved
        ))
        XCTAssertFalse(AIApprovalPresentationPolicy.shouldPresentAutomatically(
            needsApprovalResponse: true,
            state: resolved,
            showEvaluatingHint: true
        ))
    }

    func testRequestStateStorePreservesConcurrentToolsInOneSession() {
        var store = AIApprovalRequestStateStore()
        let evaluating = AIApprovalPresentationState(toolUseID: "tool-1", phase: .evaluating)
        let recommendation = AIApprovalPresentationState(
            toolUseID: "tool-2",
            phase: .recommendation(decision: .deny, risk: .high, reason: "Needs review")
        )
        let failed = AIApprovalPresentationState(
            toolUseID: "tool-3",
            phase: .failed(message: "Unavailable")
        )

        store.set(evaluating, sessionID: "session-1")
        store.set(recommendation, sessionID: "session-1")
        store.set(failed, sessionID: "session-1")

        XCTAssertEqual(store.states.count, 3)
        XCTAssertEqual(store.state(sessionID: "session-1", toolUseID: "tool-1"), evaluating)
        XCTAssertEqual(store.state(sessionID: "session-1", toolUseID: "tool-2"), recommendation)
        XCTAssertEqual(store.state(sessionID: "session-1", toolUseID: "tool-3"), failed)

        store.remove(sessionID: "session-1", toolUseID: "tool-1")

        XCTAssertNil(store.state(sessionID: "session-1", toolUseID: "tool-1"))
        XCTAssertEqual(store.state(sessionID: "session-1", toolUseID: "tool-2"), recommendation)
        XCTAssertEqual(store.state(sessionID: "session-1", toolUseID: "tool-3"), failed)
    }

    func testRequestPolicyKeepsQueuedToolsPendingBehindActivePermission() {
        let session = SessionState(
            sessionId: "session-1",
            cwd: "/workspace/project",
            phase: .waitingForApproval(PermissionContext(
                toolUseId: "tool-3",
                toolName: "Bash",
                toolInput: nil,
                receivedAt: Date()
            )),
            chatItems: [
                pendingToolItem(id: "tool-1"),
                pendingToolItem(id: "tool-2"),
                pendingToolItem(id: "tool-3")
            ]
        )

        XCTAssertTrue(AIApprovalRequestPolicy.isPending(session, toolUseID: "tool-1"))
        XCTAssertTrue(AIApprovalRequestPolicy.isPending(session, toolUseID: "tool-2"))
        XCTAssertTrue(AIApprovalRequestPolicy.isPending(session, toolUseID: "tool-3"))
        XCTAssertFalse(AIApprovalRequestPolicy.isPending(session, toolUseID: "tool-missing"))
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
            chatItems: history,
            conversationInfo: ConversationInfo(
                summary: "Implement the approval feature",
                lastMessage: "assistant 7",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "user 0",
                lastUserMessageDate: Date()
            )
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
        XCTAssertEqual(context.conversationSummary, "Implement the approval feature")
    }

    func testContextBudgeterUsesSummaryRecentWindowAndHardPayloadLimit() throws {
        let entries = (0..<120).map { index in
            AIApprovalRequestContext.ConversationEntry(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "message-\(index)-" + String(repeating: "上下文🙂\u{0000}", count: 180)
            )
        } + [
            .init(
                role: "user",
                content: "LATEST-USER-INSTRUCTION " + String(repeating: "最后指令🙂", count: 3_000) + " END-LATEST"
            ),
            .init(role: "assistant", content: "latest assistant response")
        ]
        let largeToolInput = String(repeating: "diff-line-修改🙂\n", count: 8_000)
        let context = AIApprovalRequestContext(
            sessionID: "session-large",
            toolUseID: "tool-large",
            ingress: .hookBridge,
            provider: "claude",
            client: "Claude Code",
            cwd: "/workspace/project",
            toolName: "Bash",
            interventionTitle: "Approve a large patch",
            interventionMessage: "Apply the requested patch",
            toolInput: [
                "command": AnyCodable("apply-patch"),
                "diff": AnyCodable(largeToolInput)
            ],
            conversationSummary: String(repeating: "长期会话摘要🙂", count: 2_000),
            recentConversation: entries
        )

        let prepared = AIApprovalContextBudgeter.prepare(context: context)

        XCTAssertLessThanOrEqual(prepared.byteCount, AIApprovalContextBudgeter.maximumPayloadBytes)
        XCTAssertTrue(prepared.wasTruncated)
        XCTAssertGreaterThan(prepared.omittedConversationEntries, 0)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(prepared.json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["context_strategy"] as? String, "summary_recent_window")
        XCTAssertTrue((payload["session_summary"] as? String)?.contains("truncated") == true)
        let latestUserInstruction = try XCTUnwrap(payload["latest_user_instruction"] as? String)
        XCTAssertTrue(latestUserInstruction.hasPrefix("LATEST-USER-INSTRUCTION"))
        XCTAssertTrue(latestUserInstruction.hasSuffix("END-LATEST"))
        let recentConversation = try XCTUnwrap(payload["recent_conversation"] as? [[String: Any]])
        XCTAssertEqual(recentConversation.last?["content"] as? String, "latest assistant response")
        let toolInput = try XCTUnwrap(payload["tool_input"] as? [String: Any])
        let originalToolInputData = try JSONSerialization.data(
            withJSONObject: ["command": "apply-patch", "diff": largeToolInput],
            options: [.sortedKeys]
        )
        XCTAssertEqual(toolInput["_ping_island_truncated"] as? Bool, true)
        XCTAssertEqual(toolInput["original_utf8_bytes"] as? Int, originalToolInputData.count)
        XCTAssertEqual((toolInput["sha256"] as? String)?.count, 64)
        let priorityFields = try XCTUnwrap(toolInput["priority_fields"] as? [String: Any])
        XCTAssertEqual(priorityFields["command"] as? String, "apply-patch")
        let budget = try XCTUnwrap(payload["context_budget"] as? [String: Any])
        XCTAssertEqual(budget["context_truncated"] as? Bool, true)

        XCTAssertEqual(context.recentConversation.count, 122)
        XCTAssertEqual(context.toolInput["diff"]?.value as? String, largeToolInput)
    }

    func testContextBudgeterKeepsSmallContextComplete() throws {
        let context = AIApprovalRequestContext(
            sessionID: "session-small",
            toolUseID: "tool-small",
            ingress: .hookBridge,
            provider: "codex",
            client: "Codex",
            cwd: "/workspace/project",
            toolName: "Read",
            interventionTitle: "Approve read",
            interventionMessage: "Read README.md",
            toolInput: ["path": AnyCodable("README.md")],
            conversationSummary: "Inspect documentation",
            recentConversation: [
                .init(role: "user", content: "Inspect the README"),
                .init(role: "assistant", content: "I will read it")
            ]
        )

        let prepared = AIApprovalContextBudgeter.prepare(context: context)

        XCTAssertFalse(prepared.wasTruncated)
        XCTAssertEqual(prepared.omittedConversationEntries, 0)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(prepared.json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["session_summary"] as? String, "Inspect documentation")
        XCTAssertEqual(payload["latest_user_instruction"] as? String, "Inspect the README")
        let recentConversation = try XCTUnwrap(payload["recent_conversation"] as? [[String: Any]])
        XCTAssertEqual(recentConversation.count, 2)
        let toolInput = try XCTUnwrap(payload["tool_input"] as? [String: Any])
        XCTAssertEqual(toolInput["path"] as? String, "README.md")
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
        XCTAssertEqual(exportedContext["conversationSummary"] as? String, "Complete summary")

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

    @MainActor
    func testModelContextBudgetingDoesNotAlterFullAuditRecord() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-approval-full-audit-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = AIApprovalAuditStore(fileURL: directory.appendingPathComponent("audit.json"))
        let service = AIApprovalDecisionService(auditStore: auditStore)
        let fullToolValue = String(repeating: "complete-tool-input🙂", count: 5_000)
        let fullConversationValue = String(repeating: "complete-conversation🙂", count: 5_000)
        let context = AIApprovalRequestContext(
            sessionID: "session-full-audit",
            toolUseID: "tool-full-audit",
            ingress: .hookBridge,
            provider: "claude",
            client: "Claude Code",
            cwd: "/workspace/project",
            toolName: "Bash",
            interventionTitle: "Approve command",
            interventionMessage: "Run the complete command",
            toolInput: ["command": AnyCodable(fullToolValue)],
            conversationSummary: "Complete provider summary",
            recentConversation: [.init(role: "user", content: fullConversationValue)]
        )

        let prepared = AIApprovalContextBudgeter.prepare(context: context)
        XCTAssertTrue(prepared.wasTruncated)
        _ = service.record(
            configuration: configuration(),
            context: context,
            evaluation: nil,
            outcome: .manualReview
        )

        let storedContext = try XCTUnwrap(auditStore.records.first?.context)
        XCTAssertEqual(storedContext.toolInput["command"]?.value as? String, fullToolValue)
        XCTAssertEqual(storedContext.conversationSummary, "Complete provider summary")
        XCTAssertEqual(storedContext.conversation.first?.content, fullConversationValue)
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

    private func configuration(
        apiKey: String? = nil,
        model: String = "test-model"
    ) -> AIApprovalConfiguration {
        AIApprovalConfiguration(
            isEnabledByUser: true,
            manualRiskLevels: [],
            baseURL: "https://example.com/v1",
            model: model,
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
                conversationSummary: "Complete summary",
                conversation: [.init(role: "user", content: "Inspect the README")]
            )
        )
    }

    private func pendingToolItem(id: String) -> ChatHistoryItem {
        ChatHistoryItem(
            id: id,
            type: .toolCall(ToolCallItem(
                name: "Bash",
                input: ["command": "true"],
                status: .waitingForApproval,
                result: nil,
                structuredResult: nil,
                subagentTools: []
            )),
            timestamp: Date()
        )
    }
}
