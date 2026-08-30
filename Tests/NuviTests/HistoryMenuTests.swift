import AppKit
import XCTest
@testable import Nuvi

@MainActor
final class HistoryMenuTests: XCTestCase {
    func testRecentMenuUsesNewestFiveEntriesInStoreOrder() {
        let entries = (0..<7).map { index in
            HistoryEntry(text: "transcription-\(index)", date: Date(timeIntervalSince1970: Double(100 - index)))
        }

        let model = RecentTranscriptionsMenuModel.make(entries: entries, isHistoryEnabled: true)

        guard case .entries(let items) = model else {
            return XCTFail("Expected recent transcription items")
        }
        XCTAssertEqual(items.map(\.fullText), Array(entries.prefix(5)).map(\.text))
    }

    func testRecentMenuDoesNotExposeEntriesWhenHistoryIsDisabledOrEmpty() {
        XCTAssertEqual(
            RecentTranscriptionsMenuModel.make(
                entries: [HistoryEntry(text: "private content")],
                isHistoryEnabled: false
            ),
            .disabled
        )
        XCTAssertEqual(
            RecentTranscriptionsMenuModel.make(entries: [], isHistoryEnabled: true),
            .empty
        )
    }

    func testRecentMenuTruncatesOnlyVisibleTitleAndPreservesFullText() {
        let fullText = String(repeating: "Long transcription content ", count: 8)
        let model = RecentTranscriptionsMenuModel.make(
            entries: [HistoryEntry(text: fullText)],
            isHistoryEnabled: true
        )

        guard case .entries(let items) = model, let item = items.first else {
            return XCTFail("Expected a recent item")
        }
        XCTAssertLessThan(item.title.count, fullText.count)
        XCTAssertTrue(item.title.hasSuffix("…"))
        XCTAssertEqual(item.fullText, fullText)
    }

    func testCopyHelperWritesCompleteTextToInjectedPasteboard() {
        let pasteboard = NSPasteboard(name: .init("NuviTests.HistoryMenu.\(UUID().uuidString)"))
        let fullText = "First line\nSecond line with complete content"

        XCTAssertTrue(StatusItemController.copyRecentTranscription(fullText, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), fullText)
    }

    func testRecentMenuDelegateRebuildsItemsAndActionCopiesRepresentedFullText() {
        let fullText = String(repeating: "Complete transcription line ", count: 6) + "tail"
        let store = HistoryStore(isHistoryEnabled: { true })
        store.add(fullText)
        var copied: [String] = []
        let controller = RecentTranscriptionsMenuController(
            historyStore: store,
            isHistoryEnabled: { true },
            copyText: { text in
                copied.append(text)
                return true
            }
        )

        controller.menuNeedsUpdate(controller.menu)

        let item = try! XCTUnwrap(controller.menu.items.first)
        XCTAssertTrue(item.title.hasSuffix("…"))
        XCTAssertEqual(item.representedObject as? String, fullText)
        controller.copyRecentAction(item)
        XCTAssertEqual(copied, [fullText])
    }

    func testMenuCopyFollowsSelectedInterfaceLanguageIncludingLiveWarning() {
        let english = StatusMenuCopy(language: .english)
        let spanish = StatusMenuCopy(language: .spanish)

        XCTAssertEqual(english.recentTranscriptions, "Recent Transcriptions")
        XCTAssertEqual(spanish.recentTranscriptions, "Transcripciones recientes")
        XCTAssertEqual(english.deliveryLabel(.standard), "Standard")
        XCTAssertEqual(spanish.deliveryLabel(.standard), "Estándar")
        XCTAssertEqual(english.deliveryLabel(.live), "Live (Beta)")
        XCTAssertEqual(spanish.deliveryLabel(.live), "En vivo (Beta)")
        XCTAssertEqual(english.translation, "Translation (Beta)")
        XCTAssertEqual(spanish.translation, "Traducción (Beta)")
        XCTAssertEqual(english.translationLabel(.englishUS), "English (US)")
        XCTAssertEqual(spanish.translationLabel(.englishUS), "Inglés (EE. UU.)")
        XCTAssertTrue(english.translationDetail.contains("Automatic source detection"))
        XCTAssertTrue(spanish.translationDetail.contains("Detección automática"))
        XCTAssertTrue(english.enableLiveTitle.contains("Beta"))
        XCTAssertTrue(spanish.enableLiveTitle.contains("Beta"))
        XCTAssertTrue(english.liveWarning(for: .parakeet).contains("more CPU and energy"))
        XCTAssertTrue(spanish.liveWarning(for: .parakeet).contains("más CPU y energía"))
        XCTAssertFalse(english.liveWarning(for: .parakeet).contains("deliver only when they finish"))
    }

    func testEveryCurrentEngineKeepsLiveAvailableWithLocalizedLimitations() {
        let english = StatusMenuCopy(language: .english)
        let spanish = StatusMenuCopy(language: .spanish)

        XCTAssertTrue(
            english.liveWarning(for: .whisperKit, modelID: "openai_whisper-tiny")
                .contains("works with this model")
        )
        XCTAssertTrue(
            spanish.liveWarning(for: .whisperKit, modelID: "openai_whisper-large-v3")
                .contains("En vivo es compatible")
        )
        XCTAssertTrue(
            english.liveWarning(for: .parakeet, modelID: "parakeet-tdt-0.6b-v2")
                .contains("optimized for English")
        )
        XCTAssertTrue(
            spanish.liveDetail(for: .auto, modelID: "openai_whisper-base")
                .contains("mantiene el flujo")
        )
        XCTAssertFalse(
            english.liveDetail(for: .whisperKit, modelID: "openai_whisper-base")
                .localizedCaseInsensitiveContains("unavailable")
        )
    }

    func testMenuBarStatusCanBeHiddenOrLocalizedWithoutRemovingTheIsologo() {
        XCTAssertNil(
            MenuBarStatusPresentation.label(
                for: .listening,
                language: .english,
                showsStatus: false,
                isLiveSession: false
            )
        )
        XCTAssertNil(
            MenuBarStatusPresentation.label(
                for: .idle,
                language: .english,
                showsStatus: true,
                isLiveSession: false
            )
        )
        XCTAssertEqual(
            MenuBarStatusPresentation.label(
                for: .listening,
                language: .english,
                showsStatus: true,
                isLiveSession: false
            ),
            "Listening…"
        )
        XCTAssertEqual(
            MenuBarStatusPresentation.label(
                for: .listening,
                language: .spanish,
                showsStatus: true,
                isLiveSession: false
            ),
            "Escuchando…"
        )
        XCTAssertEqual(
            MenuBarStatusPresentation.label(
                for: .transcribing,
                language: .spanish,
                showsStatus: true,
                isLiveSession: true
            ),
            "LIVE"
        )
    }

    func testRecentMenuEmptyStateRelocalizesOnEveryOpen() {
        let store = HistoryStore(isHistoryEnabled: { true })
        var language = AppLanguage.english
        let controller = RecentTranscriptionsMenuController(
            historyStore: store,
            isHistoryEnabled: { true },
            language: { language },
            copyText: { _ in true }
        )

        controller.menuNeedsUpdate(controller.menu)
        XCTAssertEqual(controller.menu.items.first?.title, "No recent transcriptions")

        language = .spanish
        controller.menuNeedsUpdate(controller.menu)
        XCTAssertEqual(controller.menu.items.first?.title, "No hay transcripciones recientes")
    }

    func testMenuBarUsesOfficialIsologoAtLegibleNativeSize() {
        let image = NuviBrand.menuBarImage(pointSize: 20)

        XCTAssertFalse(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 20, height: 20))

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 40,
            pixelsHigh: 40,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = image.size
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(origin: .zero, size: image.size))
        }
        NSGraphicsContext.restoreGraphicsState()

        var occupiedX: [Int] = []
        var occupiedY: [Int] = []
        var lavenderPixels = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15 {
                occupiedX.append(x)
                occupiedY.append(y)
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.blueComponent > color.redComponent,
                   color.redComponent > color.greenComponent {
                    lavenderPixels += 1
                }
            }
        }

        let width = try! XCTUnwrap(occupiedX.max()) - (try! XCTUnwrap(occupiedX.min())) + 1
        let height = try! XCTUnwrap(occupiedY.max()) - (try! XCTUnwrap(occupiedY.min())) + 1
        XCTAssertGreaterThanOrEqual(width, 30, "The official mark must not collapse into a dot")
        XCTAssertGreaterThanOrEqual(height, 30, "The official mark must remain recognizable at native scale")
        XCTAssertGreaterThan(lavenderPixels, 4, "The official lavender identity dot must be retained")
    }

    func testBrandPaletteUsesOnlyApprovedHexValues() {
        XCTAssertEqual(NuviPalette.softWhiteHex, "#F4F5F7")
        XCTAssertEqual(NuviPalette.charcoalHex, "#0F1116")
        XCTAssertEqual(NuviPalette.lavenderHex, "#B89BFF")
    }

    func testHistoryStoreDefaultsToMemoryOnlyAndNeverUsesApplicationSupport() {
        let store = HistoryStore(isHistoryEnabled: { true })
        store.add("isolated")

        XCTAssertNil(store.persistenceURL)
        XCTAssertEqual(store.entries.map(\.text), ["isolated"])
    }

    func testHistoryStoreLoadsAndSavesOnlyAtInjectedURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NuviTests-History-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = HistoryStore(persistenceURL: url, isHistoryEnabled: { true })
        first.add("persisted privately")
        first.flushPersistence()

        let second = HistoryStore(persistenceURL: url, isHistoryEnabled: { true })
        XCTAssertEqual(second.entries.map(\.text), ["persisted privately"])
        XCTAssertEqual(second.persistenceURL, url)
    }

    func testDisabledHistoryPurgesExistingFileAndDoesNotLoadOrAddPersistedContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NuviTests-History-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        let fileManager = FileManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([HistoryEntry(text: "must remain hidden")]).write(to: url)
        XCTAssertTrue(fileManager.fileExists(atPath: url.path))

        let store = HistoryStore(
            persistenceURL: url,
            isHistoryEnabled: { false },
            fileManager: fileManager
        )
        store.add("must not be retained")

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: url.path))
    }

    func testClearWaitsForQueuedSaveBeforePhysicallyDeletingHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NuviTests-History-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        let fileManager = FileManager()
        defer { try? fileManager.removeItem(at: directory) }

        let store = HistoryStore(
            persistenceURL: url,
            isHistoryEnabled: { true },
            fileManager: fileManager
        )
        store.add("queued before clear")
        store.clear()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: url.path))

        store.flushPersistence()
        XCTAssertFalse(fileManager.fileExists(atPath: url.path))
    }

    func testHistoryStoreCapsEntriesLoadedFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NuviTests-History-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        let fileManager = FileManager()
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode((0..<501).map { HistoryEntry(text: "entry-\($0)") }).write(to: url)

        let store = HistoryStore(
            persistenceURL: url,
            isHistoryEnabled: { true },
            fileManager: fileManager
        )

        XCTAssertEqual(store.entries.count, 500)
        XCTAssertEqual(store.entries.first?.text, "entry-0")
    }
}
