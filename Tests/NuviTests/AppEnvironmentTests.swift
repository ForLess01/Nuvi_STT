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
}
