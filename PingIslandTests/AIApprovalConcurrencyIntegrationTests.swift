import Foundation
import XCTest
@testable import Ping_Island

@MainActor
final class AIApprovalConcurrencyIntegrationTests: XCTestCase {
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
