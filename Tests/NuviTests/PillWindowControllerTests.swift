import AVFoundation
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

    func testPlacementCalculatesOriginsForVariousPresets() {
        let screen = geometry(x: 0)
        let contentSize = NSSize(width: 240, height: 44)
        let padding: CGFloat = 34
        let inset: CGFloat = 22

        // Top Left
        let topLeft = PillWindowController.calculateOrigin(
            for: .topLeft, contentSize: contentSize, screen: screen
        )
        XCTAssertEqual(topLeft.x, inset - padding)
        XCTAssertEqual(topLeft.y, 900 - inset - contentSize.height - padding)

        // Top Center
        let topCenter = PillWindowController.calculateOrigin(
            for: .topCenter, contentSize: contentSize, screen: screen
        )
        XCTAssertEqual(topCenter.x, 720 - contentSize.width / 2 - padding)
        XCTAssertEqual(topCenter.y, 900 - inset - contentSize.height - padding)

        // Bottom Right
        let bottomRight = PillWindowController.calculateOrigin(
            for: .bottomRight, contentSize: contentSize, screen: screen
        )
        XCTAssertEqual(bottomRight.x, 1440 - inset - contentSize.width - padding)
        XCTAssertEqual(bottomRight.y, inset - padding)

        // Custom
        let custom = PillWindowController.calculateOrigin(
            for: .custom(xRatio: 0.5, yRatio: 0.5), contentSize: contentSize, screen: screen
        )
        let center = PillWindowController.calculateOrigin(
            for: .screenCenter, contentSize: contentSize, screen: screen
        )
        XCTAssertEqual(custom.x, center.x, accuracy: 0.001)
        XCTAssertEqual(custom.y, center.y, accuracy: 0.001)
    }

    func testPillPositionSettingsStorePersistsAndNotifies() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "NuviTest.\(UUID().uuidString)")!)
        XCTAssertEqual(store.pillPosition, .topLeft)

        let exp = expectation(description: "Received pill position notification")
        let observer = NotificationCenter.default.addObserver(
            forName: .nuviPillPositionDidChange,
            object: store,
            queue: nil
        ) { _ in
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.pillPosition = .topCenter
        XCTAssertEqual(store.pillPosition, .topCenter)
        wait(for: [exp], timeout: 1.0)
    }

    func testPillPanelIsNotMovableByWindowBackground() {
        let controller = makeController()
        XCTAssertFalse(controller.pillPanel.isMovableByWindowBackground)
    }

    func testDragBeganShowsDropZoneOverlay() {
        let overlay = PillDropZoneOverlay()
        let controller = makeController(overlay: overlay)
        XCTAssertFalse(overlay.isVisible)

        controller.pillPanel.onDragBegan?()

        XCTAssertTrue(overlay.isVisible)
    }

    func testDragMovedMagneticallySnapsWithinThresholdAndUpdatesHighlight() {
        let overlay = PillDropZoneOverlay()
        let screen = geometry(x: 0)
        let controller = makeController(screen: screen, overlay: overlay)
        controller.updatePosition()
        let targetOrigin = controller.pillPanel.frame.origin

        controller.pillPanel.onDragBegan?()

        // Drag moved within locking threshold of .topLeft (approx 8.5pt away)
        let lockOrigin = NSPoint(x: targetOrigin.x + 6, y: targetOrigin.y - 6)
        guard let lockedOrigin = controller.pillPanel.onDragMoved?(lockOrigin) else {
            XCTFail("Expected non-nil lockedOrigin")
            return
        }

        XCTAssertEqual(lockedOrigin.x, targetOrigin.x, accuracy: 0.001)
        XCTAssertEqual(lockedOrigin.y, targetOrigin.y, accuracy: 0.001)
        XCTAssertEqual(overlay.activePreset, .topLeft)

        // Drag moved within progressive pull range (approx 35pt away)
        let nearOrigin = NSPoint(x: targetOrigin.x + 25, y: targetOrigin.y - 25)
        guard let pulledOrigin = controller.pillPanel.onDragMoved?(nearOrigin) else {
            XCTFail("Expected non-nil pulledOrigin")
            return
        }

        // Magnetism pulls it closer to targetOrigin than raw nearOrigin
        let rawDist = hypot(nearOrigin.x - targetOrigin.x, nearOrigin.y - targetOrigin.y)
        let pulledDist = hypot(pulledOrigin.x - targetOrigin.x, pulledOrigin.y - targetOrigin.y)
        XCTAssertLessThan(pulledDist, rawDist)
        XCTAssertEqual(overlay.activePreset, .topLeft)
    }

    func testDragMovedBeyondThresholdFollowsCursorAndClearsHighlight() {
        let overlay = PillDropZoneOverlay()
        let controller = makeController(overlay: overlay)

        controller.pillPanel.onDragBegan?()

        // Far away point from any preset
        let farPoint = NSPoint(x: 450, y: 520)
        guard let finalOrigin = controller.pillPanel.onDragMoved?(farPoint) else {
            XCTFail("Expected non-nil finalOrigin")
            return
        }

        XCTAssertEqual(finalOrigin.x, farPoint.x)
        XCTAssertEqual(finalOrigin.y, farPoint.y)
        XCTAssertNil(overlay.activePreset)
    }

    func testDragEndedSnapsToNearestPresetAndHidesOverlay() {
        let savedPosition = SettingsStore.shared.pillPosition
        defer { SettingsStore.shared.pillPosition = savedPosition }

        let overlay = PillDropZoneOverlay()
        let screen = geometry(x: 0)
        let controller = makeController(screen: screen, overlay: overlay)
        SettingsStore.shared.pillPosition = .topCenter
        controller.updatePosition()
        let targetOrigin = controller.pillPanel.frame.origin
        SettingsStore.shared.pillPosition = .bottomRight

        controller.pillPanel.onDragBegan?()
        XCTAssertTrue(overlay.isVisible)

        let nearOrigin = NSPoint(x: targetOrigin.x + 15, y: targetOrigin.y - 15)
        controller.pillPanel.onDragEnded?(nearOrigin)

        XCTAssertEqual(SettingsStore.shared.pillPosition, .topCenter)
        XCTAssertTrue(overlay.isHiding || !overlay.isVisible)
    }

    func testDragEndedBeyondThresholdSetsCustomPositionAndHidesOverlay() {
        let savedPosition = SettingsStore.shared.pillPosition
        defer { SettingsStore.shared.pillPosition = savedPosition }

        let overlay = PillDropZoneOverlay()
        let controller = makeController(overlay: overlay)

        controller.pillPanel.onDragBegan?()
        XCTAssertTrue(overlay.isVisible)

        let farPoint = NSPoint(x: 450, y: 520)
        controller.pillPanel.onDragEnded?(farPoint)

        XCTAssertTrue(SettingsStore.shared.pillPosition.isCustom)
        XCTAssertTrue(overlay.isHiding || !overlay.isVisible)
    }

    private func makeController(
        screen: PillWindowController.ScreenGeometry? = nil,
        overlay: PillDropZoneOverlay? = nil
    ) -> PillWindowController {
        let testScreen = screen ?? geometry(x: 0)
        let dictation = DictationController(
            audio: TestAudioCapture(),
            engine: TestEngine(),
            history: HistoryStore(),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: TestTextInjector()
        )
        let translation = TranslationCoordinator()
        return PillWindowController(
            controller: dictation,
            translation: translation,
            screenProvider: { testScreen },
            dropZoneOverlay: overlay
        )
    }

    private func geometry(x: CGFloat) -> PillWindowController.ScreenGeometry {
        PillWindowController.ScreenGeometry(
            visibleFrame: NSRect(x: x, y: 0, width: 1_440, height: 900)
        )
    }
}

// MARK: - Test Doubles

private final class TestAudioCapture: AudioCapturing, @unchecked Sendable {
    var onLevel: (@Sendable (Float) -> Void)?
    var onSpectrum: (@Sendable (AudioSpectrum) -> Void)?
    func requestPermission() async -> Bool { true }
    func start() throws -> AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { $0.finish() }
    }
    func stop() {}
}

private final class TestEngine: TranscriptionEngine, @unchecked Sendable {
    let identifier = "test"
    func prepare(locale: Locale) async throws {}
    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class TestTextInjector: TextInserting {
    func insert(_ text: String, restoreClipboard: Bool) -> InjectionResult { .inserted }
}
