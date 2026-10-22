import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

/// The waiting sound rings once for each request that arrives while the app watches, and for nothing else.
final class RequestChimeTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_000_000)

    func request(_ id: String, at: Date) -> PermissionRequest {
        PermissionRequest(id: id, source: .claude, sessionID: "s", toolName: "Bash", summary: "ls", detail: nil, cwd: nil, at: at)
    }

    func testRingsOncePerNewRequest() {
        var chime = RequestChime(startedAt: start)
        let later = start + 60
        let first = request("a", at: later)
        XCTAssertTrue(chime.rings(for: [first], now: later, paused: false))
        XCTAssertFalse(chime.rings(for: [first], now: later + 1, paused: false), "a redraw rings nothing")
        XCTAssertTrue(chime.rings(for: [first, request("b", at: later + 2)], now: later + 2, paused: false))
        XCTAssertFalse(chime.rings(for: [], now: later + 3, paused: false))
        XCTAssertFalse(chime.rings(for: [first], now: later + 4, paused: false), "dropped and brought back is not new")
    }

    func testFoundAtLaunchOrWhilePausedStaysSilent() {
        var chime = RequestChime(startedAt: start)
        XCTAssertFalse(chime.rings(for: [request("read", at: start + 1)], now: start + 1, paused: false),
                       "the first readings find what already waited")
        XCTAssertFalse(chime.rings(for: [request("old", at: start - 30)], now: start + 60, paused: false),
                       "asked before the app started")
        XCTAssertFalse(chime.rings(for: [request("p", at: start + 60)], now: start + 60, paused: true))
        XCTAssertFalse(chime.rings(for: [request("p", at: start + 60)], now: start + 70, paused: false),
                       "resuming does not ring for what arrived while paused")
    }
}
