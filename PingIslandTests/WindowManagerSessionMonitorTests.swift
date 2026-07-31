import XCTest
@testable import Ping_Island

@MainActor
final class WindowManagerSessionMonitorTests: XCTestCase {
    func testWindowManagerRetainsInjectedSessionMonitor() {
        let sessionMonitor = SessionMonitor(observeSharedState: false)

        let windowManager = WindowManager(sessionMonitor: sessionMonitor)

        XCTAssertTrue(windowManager.sessionMonitor === sessionMonitor)
    }
}
