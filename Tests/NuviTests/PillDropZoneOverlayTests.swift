import AVFoundation
import AppKit
import XCTest
@testable import Nuvi

@MainActor
final class PillDropZoneOverlayTests: XCTestCase {
    private let standardScreen = ScreenGeometry(
        visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
        frame: NSRect(x: 0, y: 0, width: 1_440, height: 900)
    )
    private let testContentSize = NSSize(width: 140, height: 42)

    // MARK: - 1. Window Configuration & Properties

    func testOverlayWindowConfiguration() {
        let overlay = PillDropZoneOverlay()

        XCTAssertTrue(overlay.isFloatingPanel)
        XCTAssertEqual(overlay.level, .floating)
        XCTAssertEqual(overlay.backgroundColor, .clear)
        XCTAssertFalse(overlay.isOpaque)
        XCTAssertFalse(overlay.hasShadow)
        XCTAssertTrue(overlay.ignoresMouseEvents, "CRITICAL: ignoresMouseEvents must be true so clicks pass through")
        XCTAssertFalse(overlay.isMovableByWindowBackground)
        XCTAssertFalse(overlay.hidesOnDeactivate)

        XCTAssertTrue(overlay.styleMask.contains(.borderless))
        XCTAssertTrue(overlay.styleMask.contains(.nonactivatingPanel))

        XCTAssertTrue(overlay.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(overlay.collectionBehavior.contains(.stationary))
        XCTAssertTrue(overlay.collectionBehavior.contains(.ignoresCycle))
        XCTAssertTrue(overlay.collectionBehavior.contains(.fullScreenAuxiliary))

        XCTAssertEqual(overlay.alphaValue, 0.0)
    }

    // MARK: - 2. Drop Zone Rects Calculation

    func testDropZoneRectsCalculationForPresets() {
        let screenInset: CGFloat = 22.0

        // Top Left
        let topLeftRect = PillDropZoneOverlay.dropZoneRect(
            for: .topLeft,
            contentSize: testContentSize,
            screen: standardScreen
        )
        XCTAssertEqual(topLeftRect.origin.x, screenInset)
        XCTAssertEqual(topLeftRect.origin.y, 900 - screenInset - testContentSize.height)
        XCTAssertEqual(topLeftRect.size, testContentSize)

        // Top Center
        let topCenterRect = PillDropZoneOverlay.dropZoneRect(
            for: .topCenter,
            contentSize: testContentSize,
            screen: standardScreen
        )
        XCTAssertEqual(topCenterRect.origin.x, 720 - testContentSize.width / 2.0, accuracy: 0.001)
        XCTAssertEqual(topCenterRect.origin.y, 900 - screenInset - testContentSize.height)
        XCTAssertEqual(topCenterRect.size, testContentSize)

        // Screen Center
        let centerRect = PillDropZoneOverlay.dropZoneRect(
            for: .screenCenter,
            contentSize: testContentSize,
            screen: standardScreen
        )
        XCTAssertEqual(centerRect.origin.x, 720 - testContentSize.width / 2.0, accuracy: 0.001)
        XCTAssertEqual(centerRect.origin.y, 450 - testContentSize.height / 2.0, accuracy: 0.001)
        XCTAssertEqual(centerRect.size, testContentSize)

        // Bottom Right
        let bottomRightRect = PillDropZoneOverlay.dropZoneRect(
            for: .bottomRight,
            contentSize: testContentSize,
            screen: standardScreen
        )
        XCTAssertEqual(bottomRightRect.origin.x, 1440 - screenInset - testContentSize.width)
        XCTAssertEqual(bottomRightRect.origin.y, screenInset)
        XCTAssertEqual(bottomRightRect.size, testContentSize)

        // Bottom Center
        let bottomCenterRect = PillDropZoneOverlay.dropZoneRect(
            for: .bottomCenter,
            contentSize: testContentSize,
            screen: standardScreen
        )
        XCTAssertEqual(bottomCenterRect.origin.x, 720 - testContentSize.width / 2.0, accuracy: 0.001)
        XCTAssertEqual(bottomCenterRect.origin.y, screenInset)
        XCTAssertEqual(bottomCenterRect.size, testContentSize)
    }

    func testAll17PresetsHaveValidDropZoneRectsInsideVisibleFrame() {
        for preset in PillPosition.allPresets {
            let rect = PillDropZoneOverlay.dropZoneRect(
                for: preset,
                contentSize: testContentSize,
                screen: standardScreen
            )

            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertGreaterThan(rect.height, 0)

            // Must be completely within visibleFrame
            XCTAssertGreaterThanOrEqual(rect.minX, standardScreen.visibleFrame.minX)
            XCTAssertLessThanOrEqual(rect.maxX, standardScreen.visibleFrame.maxX)
            XCTAssertGreaterThanOrEqual(rect.minY, standardScreen.visibleFrame.minY)
            XCTAssertLessThanOrEqual(rect.maxY, standardScreen.visibleFrame.maxY)
        }
    }

    func testFallbackToDefaultDropZoneSizeWhenContentSizeIsZero() {
        let zeroSize = NSSize.zero
        let rect = PillDropZoneOverlay.dropZoneRect(
            for: .screenCenter,
            contentSize: zeroSize,
            screen: standardScreen
        )

        XCTAssertEqual(rect.width, PillDropZoneOverlay.Appearance.defaultWidth)
        XCTAssertEqual(rect.height, PillDropZoneOverlay.Appearance.defaultHeight)
    }

    func testSecondaryScreenWithNonZeroOriginCalculatesCorrectRects() {
        let secondaryScreen = ScreenGeometry(
            visibleFrame: NSRect(x: 1440, y: 100, width: 1920, height: 1080),
            frame: NSRect(x: 1440, y: 0, width: 1920, height: 1200)
        )

        let rect = PillDropZoneOverlay.dropZoneRect(
            for: .topLeft,
            contentSize: testContentSize,
            screen: secondaryScreen
        )

        let expectedX = 1440 + 22.0
        let expectedY = 100 + 1080 - 22.0 - testContentSize.height
        XCTAssertEqual(rect.origin.x, expectedX)
        XCTAssertEqual(rect.origin.y, expectedY)
    }

    // MARK: - 3. Overlay Lifecycle (Show & Hide)

    func testShowAndHideLifecycle() {
        let overlay = PillDropZoneOverlay()
        XCTAssertEqual(overlay.alphaValue, 0.0)

        overlay.show(
            on: standardScreen,
            contentSize: testContentSize,
            activePreset: .topLeft,
            animated: false
        )

        XCTAssertTrue(overlay.isVisible)
        XCTAssertEqual(overlay.alphaValue, 1.0)
        XCTAssertEqual(overlay.activePreset, .topLeft)
        XCTAssertTrue(overlay.isPresetHighlighted(.topLeft))

        overlay.hide(animated: false)

        XCTAssertEqual(overlay.alphaValue, 0.0)
        XCTAssertFalse(overlay.isVisible)
    }

    // MARK: - 4. Active Preset Highlighting

    func testPresetHighlightingTransitions() {
        let overlay = PillDropZoneOverlay()
        overlay.show(
            on: standardScreen,
            contentSize: testContentSize,
            activePreset: nil,
            animated: false
        )

        // Initially no preset is highlighted
        XCTAssertNil(overlay.activePreset)
        for preset in PillPosition.allPresets {
            XCTAssertFalse(overlay.isPresetHighlighted(preset))
        }

        // Highlight topCenter
        overlay.updateHighlight(activePreset: .topCenter, animated: false)
        XCTAssertEqual(overlay.activePreset, .topCenter)
        XCTAssertTrue(overlay.isPresetHighlighted(.topCenter))
        XCTAssertFalse(overlay.isPresetHighlighted(.topLeft))
        XCTAssertFalse(overlay.isPresetHighlighted(.bottomRight))

        // Switch highlight to bottomRight
        overlay.updateHighlight(activePreset: .bottomRight, animated: false)
        XCTAssertEqual(overlay.activePreset, .bottomRight)
        XCTAssertTrue(overlay.isPresetHighlighted(.bottomRight))
        XCTAssertFalse(overlay.isPresetHighlighted(.topCenter))

        // Clear highlight
        overlay.updateHighlight(activePreset: nil, animated: false)
        XCTAssertNil(overlay.activePreset)
        for preset in PillPosition.allPresets {
            XCTAssertFalse(overlay.isPresetHighlighted(preset))
        }
    }

    // MARK: - 5. Nearest Preset Magnetism

    func testNearestPresetCalculation() {
        let topLeftOrigin = PillPosition.origin(
            for: .topLeft,
            contentSize: testContentSize,
            screen: standardScreen
        )

        // Within 36pt threshold -> snaps to .topLeft
        let nearTopLeft = NSPoint(x: topLeftOrigin.x + 10, y: topLeftOrigin.y - 15)
        let foundPreset = PillPosition.nearestPreset(
            from: nearTopLeft,
            contentSize: testContentSize,
            screen: standardScreen,
            threshold: 36.0
        )
        XCTAssertEqual(foundPreset, .topLeft)

        // Far away from any preset (> 36pt) -> nil
        let farPoint = NSPoint(x: 450, y: 520)
        let noPreset = PillPosition.nearestPreset(
            from: farPoint,
            contentSize: testContentSize,
            screen: standardScreen,
            threshold: 36.0
        )
        XCTAssertNil(noPreset)
    }

    func testAll17PresetsAreRepresentedInOverlay() {
        let overlay = PillDropZoneOverlay()
        overlay.show(
            on: standardScreen,
            contentSize: testContentSize,
            activePreset: nil,
            animated: false
        )

        XCTAssertEqual(PillPosition.allPresets.count, 17)
        for preset in PillPosition.allPresets {
            let screenRect = overlay.dropZoneRectOnScreen(for: preset)
            XCTAssertNotNil(screenRect)
            let windowRect = overlay.dropZoneWindowRect(for: preset)
            XCTAssertNotNil(windowRect)
            XCTAssertEqual(windowRect?.size.width, testContentSize.width)
            XCTAssertEqual(windowRect?.size.height, testContentSize.height)
        }
    }

    // MARK: - 6. Window Controller Overlay Integration

    func testPillWindowControllerRetainsDropZoneOverlay() {
        let overlay = PillDropZoneOverlay()
        let audio = TestAudioCapture()
        let engine = TestEngine()
        let dictation = DictationController(
            audio: audio,
            engine: engine,
            history: HistoryStore(),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: TestTextInjector()
        )
        let translation = TranslationCoordinator()
        let controller = PillWindowController(
            controller: dictation,
            translation: translation,
            screenProvider: { self.standardScreen },
            dropZoneOverlay: overlay
        )

        XCTAssertIdentical(controller.dropZoneOverlay, overlay)
        XCTAssertEqual(overlay.alphaValue, 0.0)

        // When pill window hides, overlay is also hidden
        controller.hide()
        XCTAssertFalse(overlay.isVisible)
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

