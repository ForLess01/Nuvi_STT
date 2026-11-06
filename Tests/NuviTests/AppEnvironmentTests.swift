import XCTest
@testable import Nuvi

@MainActor
final class AppEnvironmentTests: XCTestCase {
    func testPillPresentationBeginsOnlyAfterCaptureIsAdmitted() {
        XCTAssertFalse(AppEnvironment.shouldShowPill(for: .preparing))
        XCTAssertTrue(AppEnvironment.shouldShowPill(for: .listening))
        XCTAssertTrue(AppEnvironment.shouldShowPill(for: .transcribing))
        XCTAssertFalse(AppEnvironment.shouldShowPill(for: .idle))
        XCTAssertTrue(AppEnvironment.shouldEnableCancelHotkey(for: .preparing))
        XCTAssertFalse(AppEnvironment.shouldEnableCancelHotkey(for: .idle))
    }
    func testOlderIdenticalNoticeCannotHideNewNotice() {
        var callbacks: [@MainActor () -> Void] = []
        let lifetime = TransientNoticeLifetime(scheduler: { _, action in callbacks.append(action) })
        var hides = 0
        lifetime.schedule(after: 2, isCurrent: { true }, hide: { hides += 1 })
        lifetime.invalidate()
        lifetime.schedule(after: 2, isCurrent: { true }, hide: { hides += 1 })
        callbacks[0]()
        XCTAssertEqual(hides, 0)
        callbacks[1]()
        XCTAssertEqual(hides, 1)
    }
}
