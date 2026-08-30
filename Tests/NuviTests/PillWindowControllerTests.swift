import AppKit
import XCTest
@testable import Nuvi

@MainActor
final class PillWindowControllerTests: XCTestCase {
    func testPlacementPrefersFrontmostWindowScreen() {
        let frontmost = geometry(x: 0)
        let pointer = geometry(x: 1_440)
        let main = geometry(x: 2_880)

        let selected = PillWindowController.selectPlacementScreen(
            frontmostScreen: frontmost,
            pointerScreen: pointer,
            mainScreen: main,
            availableScreens: [main]
        )

        XCTAssertEqual(selected, frontmost)
    }

    func testPlacementUsesActivePointerScreenWhenNoFrontmostWindowExists() {
        let pointer = geometry(x: 1_440)
        let main = geometry(x: 0)

        let selected = PillWindowController.selectPlacementScreen(
            frontmostScreen: nil,
            pointerScreen: pointer,
            mainScreen: main,
            availableScreens: [main]
        )

        XCTAssertEqual(selected, pointer)
    }

    func testPlacementFallsBackToMainScreenWithoutWindowOrPointer() {
        let main = geometry(x: 0)
        let available = geometry(x: 1_440)

        let selected = PillWindowController.selectPlacementScreen(
            frontmostScreen: nil,
            pointerScreen: nil,
            mainScreen: main,
            availableScreens: [available]
        )

        XCTAssertEqual(selected, main)
    }

    func testPlacementFallsBackToFirstAvailableScreenWhenMainScreenIsUnavailable() {
        let available = geometry(x: 1_440)

        let selected = PillWindowController.selectPlacementScreen(
            frontmostScreen: nil,
            pointerScreen: nil,
            mainScreen: nil,
            availableScreens: [available]
        )

        XCTAssertEqual(selected, available)
    }

    private func geometry(x: CGFloat) -> PillWindowController.ScreenGeometry {
        PillWindowController.ScreenGeometry(
            visibleFrame: NSRect(x: x, y: 0, width: 1_440, height: 900)
        )
    }
}
