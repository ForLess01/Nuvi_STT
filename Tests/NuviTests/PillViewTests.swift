import XCTest
@testable import Nuvi

final class PillViewTests: XCTestCase {
    func testInsertedStateAlwaysOverridesAStaleTranscript() {
        XCTAssertEqual(
            PillDisplayText.resolve(
                state: .inserted,
                transcript: "This text must never appear beside the check",
                stateLabel: "Inserted"
            ),
            "Inserted"
        )
    }

    func testCopiedStateAlwaysOverridesAStaleTranscript() {
        XCTAssertEqual(
            PillDisplayText.resolve(
                state: .copied,
                transcript: "This text must never appear beside the check",
                stateLabel: "Copied"
            ),
            "Copied"
        )
    }

    func testActiveTranscriptionStillShowsItsPreview() {
        XCTAssertEqual(
            PillDisplayText.resolve(
                state: .listening,
                transcript: "Live preview",
                stateLabel: "Listening…"
            ),
            "Live preview"
        )
    }

    func testLiveListeningAlwaysShowsLiveInsteadOfTranscript() {
        XCTAssertEqual(
            PillDisplayText.resolve(
                state: .listening,
                transcript: "This partial must stay out of the pill",
                stateLabel: "Listening…",
                isLiveSession: true
            ),
            "LIVE"
        )
    }

    func testLiveTranscribingAlwaysShowsLiveInsteadOfTranscript() {
        XCTAssertEqual(
            PillDisplayText.resolve(
                state: .transcribing,
                transcript: "This final must stay out of the pill",
                stateLabel: "Transcribing…",
                isLiveSession: true
            ),
            "LIVE"
        )
    }
}
