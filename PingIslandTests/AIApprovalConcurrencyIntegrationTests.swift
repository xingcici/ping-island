import Foundation
import XCTest
@testable import Ping_Island

@MainActor
final class AIApprovalConcurrencyIntegrationTests: XCTestCase {
    private struct CapturedResponse: Equatable {
        let ingress: SessionIngress
        let toolUseID: String
        let decision: AIApprovalDecisionChoice
        let reason: String?
    }

    private final class ResponseRecorder {
        private(set) var responses: [CapturedResponse] = []

        func record(
            ingress: SessionIngress,
            toolUseID: String,
            decision: AIApprovalDecisionChoice,
            reason: String?
        ) {
            responses.append(CapturedResponse(
                ingress: ingress,
                toolUseID: toolUseID,
                decision: decision,
                reason: reason
            ))
        }
    }

    private struct EmptyCredentialStore: AIApprovalCredentialStoring {
        func apiKey() -> String? { nil }
        func saveAPIKey(_ apiKey: String) -> Bool { true }
        func deleteAPIKey() {}
    }

    private actor HighRiskTransport: AIApprovalHTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            let delay: Duration
            if body.contains("tool-1") {
                delay = .milliseconds(90)
            } else if body.contains("tool-2") {
                delay = .milliseconds(10)
            } else {
                delay = .milliseconds(50)
            }
            try await Task.sleep(for: delay)

            let decision = """
            {"decision":"approve","risk":"high","reason":"Requires manual review"}
            """
            let payload: [String: Any] = [
                "choices": [["message": ["content": decision]]]
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let url = request.url,
                  let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) else {
                throw URLError(.badServerResponse)
            }
            return (data, response)
        }
    }

    private actor RoutedTransport: AIApprovalHTTPTransport {
        private let decisions: [String: AIApprovalDecision]
        private let delays: [String: Duration]
        private var requestCounts: [String: Int] = [:]
        private var activeRequestCount = 0
        private var maximumActiveRequestCount = 0

        init(
            decisions: [String: AIApprovalDecision],
            delays: [String: Duration] = [:]
        ) {
            self.decisions = decisions
            self.delays = delays
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            guard let toolUseID = decisions.keys.first(where: { body.contains($0) }),
                  let decision = decisions[toolUseID] else {
                throw URLError(.badServerResponse)
            }
            requestCounts[toolUseID, default: 0] += 1
            activeRequestCount += 1
            maximumActiveRequestCount = max(maximumActiveRequestCount, activeRequestCount)
            defer { activeRequestCount -= 1 }
            if let delay = delays[toolUseID] {
                try await Task.sleep(for: delay)
            }
            let contentData = try JSONEncoder().encode(decision)
            let content = String(decoding: contentData, as: UTF8.self)
            let payload: [String: Any] = [
                "choices": [["message": ["content": content]]]
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                  ) else {
                throw URLError(.badServerResponse)
            }
            return (data, response)
        }

        func totalRequestCount() -> Int {
            requestCounts.values.reduce(0, +)
        }

        func requestCount(for toolUseID: String) -> Int {
            requestCounts[toolUseID, default: 0]
        }

        func maximumConcurrentRequestCount() -> Int {
            maximumActiveRequestCount
        }
    }

    private actor InvalidResponseTransport: AIApprovalHTTPTransport {
        private var requestCount = 0

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requestCount += 1
            let payload: [String: Any] = [
                "choices": [["message": ["content": "not-json"]]]
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (data, response)
        }

        func capturedRequestCount() -> Int {
            requestCount
        }
    }

    func testConcurrentHighRiskHooksRemainQueuedForSequentialManualReview() async throws {
        let settingsSuiteName = "ai-approval-concurrency-settings-\(UUID().uuidString)"
        let settingsDefaults = try XCTUnwrap(UserDefaults(suiteName: settingsSuiteName))
        defer {
            settingsDefaults.removePersistentDomain(forName: settingsSuiteName)
        }
        let settings = AppSettingsStore(
            defaults: settingsDefaults,
            bridgeRuntimeConfigWriter: { _ in }
        )
        settings.aiApprovalEnabled = true
        settings.aiApprovalManualRiskLevels = [.high]
        settings.aiApprovalBaseURL = "https://example.com/v1"
        settings.aiApprovalModel = "deterministic-high-risk-model"
        settings.aiApprovalPolicy = "Require manual review for this test."

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-approval-concurrency-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = AIApprovalAuditStore(fileURL: directory.appendingPathComponent("audit.json"))
        let service = AIApprovalDecisionService(
            client: OpenAICompatibleApprovalClient(transport: HighRiskTransport()),
            credentialStore: EmptyCredentialStore(),
            auditStore: auditStore,
            concurrencyLimiter: AIApprovalConcurrencyLimiter(limit: 4)
        )
        let monitor = SessionMonitor(
            aiApprovalService: service,
            aiApprovalSettings: settings
        )
        let sessionID = "concurrent-ai-approval-\(UUID().uuidString)"
        let toolUseIDs = Set(["tool-1", "tool-2", "tool-3"])
        let events = toolUseIDs.map { toolUseID in
            HookEvent(
                sessionId: sessionID,
                cwd: "/workspace/project",
                event: "PermissionRequest",
                status: "waiting_for_approval",
                provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil,
                tty: nil,
                tool: "Bash",
                toolInput: ["command": AnyCodable("sudo rm -rf /nonexistent/\(toolUseID)")],
                toolUseId: toolUseID,
                notificationType: nil,
                message: "Concurrent high-risk approval test",
                bridgeExpectsResponse: true
            )
        }

        await withTaskGroup(of: Void.self) { group in
            for event in events {
                group.addTask {
                    await monitor.handleIncomingHookEvent(event)
                }
            }
        }

        let allRecommendationsReady = await eventually {
            let records = auditStore.records.filter { $0.sessionID == sessionID }
            return records.count == 3 && records.allSatisfy { $0.outcome == .manualReview }
        }
        XCTAssertTrue(allRecommendationsReady)

        let queuedSessionValue = await SessionStore.shared.session(for: sessionID)
        let queuedSession = try XCTUnwrap(queuedSessionValue)
        XCTAssertEqual(pendingToolUseIDs(in: queuedSession), toolUseIDs)

        var handledToolUseIDs = Set<String>()
        for expectedRemainingCount in stride(from: 3, through: 1, by: -1) {
            let currentToolUseID = await currentManualToolUseID(
                sessionID: sessionID,
                monitor: monitor
            )
            let toolUseID = try XCTUnwrap(currentToolUseID)
            XCTAssertTrue(handledToolUseIDs.insert(toolUseID).inserted)

            monitor.approvePermission(sessionId: sessionID)

            let requestWasResolved = await eventually {
                guard let session = await SessionStore.shared.session(for: sessionID) else {
                    return false
                }
                return pendingToolUseIDs(in: session).count == expectedRemainingCount - 1
            }
            XCTAssertTrue(requestWasResolved)
        }

        XCTAssertEqual(handledToolUseIDs, toolUseIDs)
        let queueWasDrained = await eventually {
            guard let session = await SessionStore.shared.session(for: sessionID) else {
                return false
            }
            return session.phase == .processing && monitor.aiApprovalState(for: sessionID) == nil
        }
        XCTAssertTrue(queueWasDrained)
        XCTAssertFalse(
            auditStore.records
                .filter { $0.sessionID == sessionID }
                .contains { $0.outcome == .failed }
        )

        await SessionStore.shared.process(.sessionArchived(sessionId: sessionID))
    }

    func testMixedAutomaticApproveDenyAndManualReviewResolveEveryToolExactlyOnce() async throws {
        let settingsSuiteName = "ai-approval-mixed-settings-\(UUID().uuidString)"
        let settingsDefaults = try XCTUnwrap(UserDefaults(suiteName: settingsSuiteName))
        defer { settingsDefaults.removePersistentDomain(forName: settingsSuiteName) }
        let settings = configuredSettings(defaults: settingsDefaults, manualRiskLevels: [.high])
        let directory = temporaryAuditDirectory(prefix: "ai-approval-mixed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = AIApprovalAuditStore(fileURL: directory.appendingPathComponent("audit.json"))
        let decisions: [String: AIApprovalDecision] = [
            "tool-low": .init(decision: .approve, risk: .low, reason: "Read-only"),
            "tool-medium": .init(decision: .deny, risk: .medium, reason: "Unexpected mutation"),
            "tool-high": .init(decision: .approve, risk: .high, reason: "Privileged command")
        ]
        let transport = RoutedTransport(
            decisions: decisions,
            delays: [
                "tool-low": .milliseconds(90),
                "tool-medium": .milliseconds(10),
                "tool-high": .milliseconds(50)
            ]
        )
        let recorder = ResponseRecorder()
        let monitor = makeMonitor(
            settings: settings,
            transport: transport,
            auditStore: auditStore,
            recorder: recorder
        )
        let sessionID = "mixed-ai-approval-\(UUID().uuidString)"

        let events = decisions.keys.map {
            permissionEvent(sessionID: sessionID, toolUseID: $0)
        }
        await withTaskGroup(of: Void.self) { group in
            for event in events {
                group.addTask {
                    await monitor.handleIncomingHookEvent(event)
                }
            }
        }

        let settled = await eventually {
            auditStore.records.filter { $0.sessionID == sessionID }.count == 3
                && recorder.responses.count == 2
        }
        XCTAssertTrue(settled)
        let outcomes = Dictionary(uniqueKeysWithValues: auditStore.records
            .filter { $0.sessionID == sessionID }
            .compactMap { record in record.toolUseID.map { ($0, record.outcome) } })
        XCTAssertEqual(outcomes["tool-low"], .autoApproved)
        XCTAssertEqual(outcomes["tool-medium"], .autoDenied)
        XCTAssertEqual(outcomes["tool-high"], .manualReview)
        XCTAssertEqual(Set(recorder.responses.map(\.toolUseID)), Set(["tool-low", "tool-medium"]))
        XCTAssertEqual(recorder.responses.first(where: { $0.toolUseID == "tool-low" })?.decision, .approve)
        XCTAssertEqual(recorder.responses.first(where: { $0.toolUseID == "tool-medium" })?.decision, .deny)

        let sessionValue = await SessionStore.shared.session(for: sessionID)
        let session = try XCTUnwrap(sessionValue)
        XCTAssertEqual(pendingToolUseIDs(in: session), Set(["tool-high"]))
        XCTAssertEqual(monitor.aiApprovalState(for: sessionID)?.toolUseID, "tool-high")

        monitor.approvePermission(sessionId: sessionID)
        let manualRequestResolved = await eventually {
            guard let current = await SessionStore.shared.session(for: sessionID) else { return false }
            return current.phase == .processing && pendingToolUseIDs(in: current).isEmpty
        }
        XCTAssertTrue(manualRequestResolved)
        XCTAssertEqual(recorder.responses.count, 2)
        await SessionStore.shared.process(.sessionArchived(sessionId: sessionID))
    }

    func testUserResolutionDuringEvaluationCancelsModelWithoutDuplicateHookResponse() async throws {
        let settingsSuiteName = "ai-approval-user-race-settings-\(UUID().uuidString)"
        let settingsDefaults = try XCTUnwrap(UserDefaults(suiteName: settingsSuiteName))
        defer { settingsDefaults.removePersistentDomain(forName: settingsSuiteName) }
        let settings = configuredSettings(defaults: settingsDefaults, manualRiskLevels: [])
        let directory = temporaryAuditDirectory(prefix: "ai-approval-user-race")
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = AIApprovalAuditStore(fileURL: directory.appendingPathComponent("audit.json"))
        let toolUseID = "tool-user-wins"
        let transport = RoutedTransport(
            decisions: [toolUseID: .init(decision: .deny, risk: .high, reason: "Model deny")],
            delays: [toolUseID: .milliseconds(400)]
        )
        let recorder = ResponseRecorder()
        let monitor = makeMonitor(
            settings: settings,
            transport: transport,
            auditStore: auditStore,
            recorder: recorder
        )
        let sessionID = "user-race-ai-approval-\(UUID().uuidString)"

        await monitor.handleIncomingHookEvent(permissionEvent(sessionID: sessionID, toolUseID: toolUseID))
        let evaluationStarted = await eventually {
            guard monitor.aiApprovalState(for: sessionID)?.isEvaluating == true else { return false }
            return await SessionStore.shared.session(for: sessionID) != nil
        }
        XCTAssertTrue(evaluationStarted)

        monitor.approvePermission(sessionId: sessionID)

        let supersededWasAudited = await eventually {
            auditStore.records.contains {
                $0.sessionID == sessionID && $0.toolUseID == toolUseID && $0.outcome == .superseded
            }
        }
        XCTAssertTrue(supersededWasAudited)
        try? await Task.sleep(for: .milliseconds(450))
        let finalSessionValue = await SessionStore.shared.session(for: sessionID)
        let finalSession = try XCTUnwrap(finalSessionValue)
        XCTAssertEqual(finalSession.phase, .processing)
        XCTAssertNil(monitor.aiApprovalState(for: sessionID))
        XCTAssertTrue(recorder.responses.isEmpty)
        await SessionStore.shared.process(.sessionArchived(sessionId: sessionID))
    }

    func testModelFailureFallsBackToManualApprovalWithoutSendingHookResponse() async throws {
        let settingsSuiteName = "ai-approval-failure-settings-\(UUID().uuidString)"
        let settingsDefaults = try XCTUnwrap(UserDefaults(suiteName: settingsSuiteName))
        defer { settingsDefaults.removePersistentDomain(forName: settingsSuiteName) }
        let settings = configuredSettings(defaults: settingsDefaults, manualRiskLevels: [])
        let directory = temporaryAuditDirectory(prefix: "ai-approval-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = AIApprovalAuditStore(fileURL: directory.appendingPathComponent("audit.json"))
        let transport = InvalidResponseTransport()
        let recorder = ResponseRecorder()
        let monitor = makeMonitor(
            settings: settings,
            transport: transport,
            auditStore: auditStore,
            recorder: recorder
        )
        let sessionID = "failed-ai-approval-\(UUID().uuidString)"
        let toolUseID = "tool-invalid-model-output"

        await monitor.handleIncomingHookEvent(permissionEvent(sessionID: sessionID, toolUseID: toolUseID))

        let failureWasPresented = await eventually {
            guard case .failed = monitor.aiApprovalState(for: sessionID)?.phase else { return false }
            return auditStore.records.contains {
                $0.sessionID == sessionID && $0.outcome == .failed
            }
        }
        XCTAssertTrue(failureWasPresented)
        let sessionValue = await SessionStore.shared.session(for: sessionID)
        let session = try XCTUnwrap(sessionValue)
        XCTAssertEqual(pendingToolUseIDs(in: session), Set([toolUseID]))
        XCTAssertTrue(recorder.responses.isEmpty)
        let requestCount = await transport.capturedRequestCount()
        XCTAssertEqual(requestCount, 1)

        monitor.denyPermission(sessionId: sessionID, reason: "Manual fallback")
        let fallbackWasResolved = await eventually {
            guard let current = await SessionStore.shared.session(for: sessionID) else { return false }
            return current.phase == .processing
        }
        XCTAssertTrue(fallbackWasResolved)
        await SessionStore.shared.process(.sessionArchived(sessionId: sessionID))
    }

    func testDuplicateConcurrentHookDeliveryEvaluatesAndRespondsOnlyOnce() async throws {
        let settingsSuiteName = "ai-approval-duplicate-settings-\(UUID().uuidString)"
        let settingsDefaults = try XCTUnwrap(UserDefaults(suiteName: settingsSuiteName))
        defer { settingsDefaults.removePersistentDomain(forName: settingsSuiteName) }
        let settings = configuredSettings(defaults: settingsDefaults, manualRiskLevels: [])
        let directory = temporaryAuditDirectory(prefix: "ai-approval-duplicate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = AIApprovalAuditStore(fileURL: directory.appendingPathComponent("audit.json"))
        let toolUseID = "tool-duplicate"
        let transport = RoutedTransport(
            decisions: [toolUseID: .init(decision: .approve, risk: .low, reason: "Safe")],
            delays: [toolUseID: .milliseconds(80)]
        )
        let recorder = ResponseRecorder()
        let monitor = makeMonitor(
            settings: settings,
            transport: transport,
            auditStore: auditStore,
            recorder: recorder
        )
        let sessionID = "duplicate-ai-approval-\(UUID().uuidString)"
        let event = permissionEvent(sessionID: sessionID, toolUseID: toolUseID)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await monitor.handleIncomingHookEvent(event)
                }
            }
        }

        let duplicateSettled = await eventually {
            recorder.responses.count == 1
                && auditStore.records.filter { $0.sessionID == sessionID }.count == 1
        }
        XCTAssertTrue(duplicateSettled)
        let requestCount = await transport.requestCount(for: toolUseID)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(recorder.responses, [CapturedResponse(
            ingress: .hookBridge,
            toolUseID: toolUseID,
            decision: .approve,
            reason: nil
        )])
        await SessionStore.shared.process(.sessionArchived(sessionId: sessionID))
    }

    func testHighVolumeCrossSessionHooksRespectLimitAndAllComplete() async throws {
        let settingsSuiteName = "ai-approval-cross-session-settings-\(UUID().uuidString)"
        let settingsDefaults = try XCTUnwrap(UserDefaults(suiteName: settingsSuiteName))
        defer { settingsDefaults.removePersistentDomain(forName: settingsSuiteName) }
        let settings = configuredSettings(defaults: settingsDefaults, manualRiskLevels: [])
        let directory = temporaryAuditDirectory(prefix: "ai-approval-cross-session")
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = AIApprovalAuditStore(fileURL: directory.appendingPathComponent("audit.json"))
        let toolUseIDs = (0..<16).map { "cross-tool-\($0)" }
        let decisions = Dictionary(uniqueKeysWithValues: toolUseIDs.map {
            ($0, AIApprovalDecision(decision: .approve, risk: .low, reason: "Safe batch request"))
        })
        let delays = Dictionary(uniqueKeysWithValues: toolUseIDs.map { ($0, Duration.milliseconds(60)) })
        let transport = RoutedTransport(decisions: decisions, delays: delays)
        let recorder = ResponseRecorder()
        let monitor = makeMonitor(
            settings: settings,
            transport: transport,
            auditStore: auditStore,
            recorder: recorder
        )
        let sessionIDs = toolUseIDs.map { "cross-session-\($0)-\(UUID().uuidString)" }
        let events = zip(sessionIDs, toolUseIDs).map {
            permissionEvent(sessionID: $0.0, toolUseID: $0.1)
        }

        await withTaskGroup(of: Void.self) { group in
            for event in events {
                group.addTask {
                    await monitor.handleIncomingHookEvent(event)
                }
            }
        }

        let allRequestsSettled = await eventually(timeout: .seconds(6)) {
            recorder.responses.count == toolUseIDs.count
                && auditStore.records.filter { sessionIDs.contains($0.sessionID) }.count == toolUseIDs.count
        }
        XCTAssertTrue(allRequestsSettled)
        XCTAssertEqual(Set(recorder.responses.map(\.toolUseID)), Set(toolUseIDs))
        let requestCount = await transport.totalRequestCount()
        let maximumConcurrentCount = await transport.maximumConcurrentRequestCount()
        XCTAssertEqual(requestCount, toolUseIDs.count)
        XCTAssertEqual(maximumConcurrentCount, 4)
        XCTAssertTrue(auditStore.records
            .filter { sessionIDs.contains($0.sessionID) }
            .allSatisfy { $0.outcome == .autoApproved })

        for sessionID in sessionIDs {
            await SessionStore.shared.process(.sessionArchived(sessionId: sessionID))
        }
    }

    func testEvaluatingHintSettingOnlyChangesAutomaticPresentation() async throws {
        let settingsSuiteName = "ai-approval-hint-settings-\(UUID().uuidString)"
        let settingsDefaults = try XCTUnwrap(UserDefaults(suiteName: settingsSuiteName))
        defer { settingsDefaults.removePersistentDomain(forName: settingsSuiteName) }
        let settings = configuredSettings(defaults: settingsDefaults, manualRiskLevels: [])
        settings.aiApprovalShowEvaluatingHint = false
        let directory = temporaryAuditDirectory(prefix: "ai-approval-hint")
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = AIApprovalAuditStore(fileURL: directory.appendingPathComponent("audit.json"))
        let toolUseID = "tool-hint"
        let transport = RoutedTransport(
            decisions: [toolUseID: .init(decision: .approve, risk: .low, reason: "Safe")],
            delays: [toolUseID: .milliseconds(400)]
        )
        let recorder = ResponseRecorder()
        let monitor = makeMonitor(
            settings: settings,
            transport: transport,
            auditStore: auditStore,
            recorder: recorder
        )
        let sessionID = "hint-ai-approval-\(UUID().uuidString)"

        await monitor.handleIncomingHookEvent(permissionEvent(sessionID: sessionID, toolUseID: toolUseID))
        let sessionValue = await SessionStore.shared.session(for: sessionID)
        let session = try XCTUnwrap(sessionValue)
        let hintEvaluationStarted = await eventually {
            monitor.aiApprovalState(for: sessionID)?.isEvaluating == true
        }
        XCTAssertTrue(hintEvaluationStarted)
        XCTAssertTrue(monitor.sessionsEligibleForAutomaticPresentation(from: [session]).isEmpty)

        settings.aiApprovalShowEvaluatingHint = true
        XCTAssertEqual(
            monitor.sessionsEligibleForAutomaticPresentation(from: [session]).map(\.sessionId),
            [sessionID]
        )

        monitor.approvePermission(sessionId: sessionID)
        let hintWasCleared = await eventually { monitor.aiApprovalState(for: sessionID) == nil }
        XCTAssertTrue(hintWasCleared)
        await SessionStore.shared.process(.sessionArchived(sessionId: sessionID))
    }

    func testIneligibleHookKindsNeverInvokeModel() async throws {
        let settingsSuiteName = "ai-approval-ineligible-settings-\(UUID().uuidString)"
        let settingsDefaults = try XCTUnwrap(UserDefaults(suiteName: settingsSuiteName))
        defer { settingsDefaults.removePersistentDomain(forName: settingsSuiteName) }
        let settings = configuredSettings(defaults: settingsDefaults, manualRiskLevels: [])
        let directory = temporaryAuditDirectory(prefix: "ai-approval-ineligible")
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = AIApprovalAuditStore(fileURL: directory.appendingPathComponent("audit.json"))
        let transport = RoutedTransport(decisions: [:])
        let recorder = ResponseRecorder()
        let monitor = makeMonitor(
            settings: settings,
            transport: transport,
            auditStore: auditStore,
            recorder: recorder
        )
        let baseID = UUID().uuidString
        let events = [
            HookEvent(
                sessionId: "ask-\(baseID)", cwd: "/workspace/project", event: "PermissionRequest",
                status: "waiting_for_approval", provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil, tty: nil, tool: "AskUserQuestion",
                toolInput: ["questions": AnyCodable([["question": "Continue?"]])],
                toolUseId: "tool-ask", notificationType: nil, message: "Question",
                bridgeExpectsResponse: true
            ),
            HookEvent(
                sessionId: "notify-only-\(baseID)", cwd: "/workspace/project", event: "PermissionRequest",
                status: "waiting_for_approval", provider: .claude,
                clientInfo: SessionClientInfo(kind: .custom, name: "Notify only"),
                pid: nil, tty: nil, tool: "Bash", toolInput: ["command": AnyCodable("true")],
                toolUseId: "tool-notify-only", notificationType: nil, message: nil,
                bridgeExpectsResponse: false
            ),
            HookEvent(
                sessionId: "suppressed-\(baseID)", cwd: "/workspace/project", event: "PermissionRequest",
                status: "waiting_for_approval", provider: .claude,
                clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
                pid: nil, tty: nil, tool: "Bash", toolInput: ["command": AnyCodable("true")],
                toolUseId: "tool-suppressed", notificationType: nil, message: nil,
                bridgeExpectsResponse: true, suppressInAppPrompt: true
            ),
            HookEvent(
                sessionId: "bypass-\(baseID)", cwd: "/workspace/project", event: "PermissionRequest",
                status: "waiting_for_approval", provider: .codex,
                clientInfo: SessionClientInfo(kind: .codexCLI, name: "Codex"),
                pid: nil, tty: nil, tool: "Bash", toolInput: ["command": AnyCodable("true")],
                toolUseId: "tool-bypass", notificationType: nil, message: nil,
                bridgeExpectsResponse: true, codexBypassPermissions: true
            )
        ]

        for event in events {
            await monitor.handleIncomingHookEvent(event)
        }
        try? await Task.sleep(for: .milliseconds(100))

        let requestCount = await transport.totalRequestCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertTrue(auditStore.records.isEmpty)
        XCTAssertTrue(recorder.responses.isEmpty)
        for event in events {
            XCTAssertNil(monitor.aiApprovalState(for: event.sessionId))
            await SessionStore.shared.process(.sessionArchived(sessionId: event.sessionId))
        }
    }

    private func currentManualToolUseID(
        sessionID: String,
        monitor: SessionMonitor
    ) async -> String? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if let session = await SessionStore.shared.session(for: sessionID),
               let toolUseID = session.activePermission?.toolUseId,
               let state = monitor.aiApprovalState(for: sessionID),
               state.toolUseID == toolUseID,
               case .recommendation(_, .high, _) = state.phase {
                return toolUseID
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private func configuredSettings(
        defaults: UserDefaults,
        manualRiskLevels: Set<AIApprovalRisk>
    ) -> AppSettingsStore {
        let settings = AppSettingsStore(
            defaults: defaults,
            bridgeRuntimeConfigWriter: { _ in }
        )
        settings.aiApprovalEnabled = true
        settings.aiApprovalManualRiskLevels = manualRiskLevels
        settings.aiApprovalBaseURL = "https://example.com/v1"
        settings.aiApprovalModel = "deterministic-approval-model"
        settings.aiApprovalPolicy = "Deterministic integration test policy."
        return settings
    }

    private func temporaryAuditDirectory(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeMonitor<T: AIApprovalHTTPTransport>(
        settings: AppSettingsStore,
        transport: T,
        auditStore: AIApprovalAuditStore,
        recorder: ResponseRecorder
    ) -> SessionMonitor {
        let service = AIApprovalDecisionService(
            client: OpenAICompatibleApprovalClient(transport: transport),
            credentialStore: EmptyCredentialStore(),
            auditStore: auditStore,
            concurrencyLimiter: AIApprovalConcurrencyLimiter(limit: 4)
        )
        return SessionMonitor(
            aiApprovalService: service,
            aiApprovalSettings: settings,
            aiApprovalResponseHandler: { ingress, toolUseID, decision, reason in
                recorder.record(
                    ingress: ingress,
                    toolUseID: toolUseID,
                    decision: decision,
                    reason: reason
                )
            }
        )
    }

    nonisolated private func permissionEvent(sessionID: String, toolUseID: String) -> HookEvent {
        HookEvent(
            sessionId: sessionID,
            cwd: "/workspace/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            pid: nil,
            tty: nil,
            tool: "Bash",
            toolInput: ["command": AnyCodable("echo \(toolUseID)")],
            toolUseId: toolUseID,
            notificationType: nil,
            message: "Approval integration test",
            bridgeExpectsResponse: true
        )
    }

    private func eventually(
        timeout: Duration = .seconds(3),
        condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    private func pendingToolUseIDs(in session: SessionState) -> Set<String> {
        Set(session.chatItems.compactMap { item in
            guard case .toolCall(let tool) = item.type,
                  tool.status == .waitingForApproval else {
                return nil
            }
            return item.id
        })
    }
}
