import XCTest
@testable import Nuvi

final class SettingsStoreTests: XCTestCase {
    func testConfigurationNormalizesParakeetModelAwayFromWhisperAndAuto() {
        XCTAssertEqual(
            TranscriptionConfiguration(engine: .whisperKit, modelID: "parakeet-tdt-0.6b-v3").normalized.modelID,
            TranscriptionConfiguration.defaultWhisperModelID
        )
        XCTAssertEqual(
            TranscriptionConfiguration(engine: .auto, modelID: "parakeet-tdt-0.6b-v2").normalized.modelID,
            TranscriptionConfiguration.defaultWhisperModelID
        )
    }

    func testConfigurationNormalizesWhisperModelAwayFromParakeet() {
        XCTAssertEqual(
            TranscriptionConfiguration(engine: .parakeet, modelID: "openai_whisper-tiny").normalized.modelID,
            TranscriptionConfiguration.defaultParakeetModelID
        )
    }

    func testConfigurationPreservesValidDownloadedModelIDs() {
        XCTAssertEqual(
            TranscriptionConfiguration(engine: .parakeet, modelID: "parakeet-tdt-0.6b-v2").normalized.modelID,
            "parakeet-tdt-0.6b-v2"
        )
        XCTAssertEqual(
            TranscriptionConfiguration(engine: .whisperKit, modelID: "openai_whisper-medium").normalized.modelID,
            "openai_whisper-medium"
        )
    }

    func testAutoPreservesAValidWhisperModel() {
        XCTAssertEqual(
            TranscriptionConfiguration(engine: .auto, modelID: "openai_whisper-small").normalized.modelID,
            "openai_whisper-small"
        )
    }

    func testFactoryNormalizesConfigurationBeforeConstructingAdapter() {
        let proposed = TranscriptionConfiguration(engine: .whisperKit, modelID: "parakeet-tdt-0.6b-v3")
        let whisper = TranscriptionEngineFactory.make(configuration: proposed) as? WhisperKitEngine
        XCTAssertEqual(whisper?.configuredModelID, TranscriptionConfiguration.defaultWhisperModelID)

        let parakeet = TranscriptionEngineFactory.make(
            configuration: TranscriptionConfiguration(engine: .parakeet, modelID: "openai_whisper-tiny")
        ) as? ParakeetEngine
        XCTAssertEqual(parakeet?.configuredModelID, TranscriptionConfiguration.defaultParakeetModelID)

        let hybrid = TranscriptionEngineFactory.make(
            configuration: TranscriptionConfiguration(engine: .auto, modelID: "openai_whisper-small")
        ) as? HybridTranscriptionEngine
        XCTAssertEqual(
            hybrid?.configuredFallbackModelID,
            "openai_whisper-small"
        )
    }

    func testEngineAdaptersDefensivelyNormalizeExplicitModelIDs() {
        XCTAssertEqual(
            WhisperKitEngine(modelName: "parakeet-tdt-0.6b-v3").configuredModelID,
            TranscriptionConfiguration.defaultWhisperModelID
        )
        XCTAssertEqual(
            ParakeetEngine(modelId: "openai_whisper-tiny").configuredModelID,
            TranscriptionConfiguration.defaultParakeetModelID
        )
    }

    func testChangingEnginePersistsACompatibleModelAsOneConfiguration() {
        let suite = "NuviTests.SettingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.selectModel(id: "parakeet-tdt-0.6b-v3", engine: .parakeet)

        store.enginePreference = .whisperKit

        XCTAssertEqual(store.transcriptionConfiguration.engine, .whisperKit)
        XCTAssertEqual(store.transcriptionConfiguration.modelID, TranscriptionConfiguration.defaultWhisperModelID)
    }

    func testDictationDeliveryModeDefaultsToStandardAndPersistsLive() {
        let suite = "NuviTests.DeliveryMode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.dictationDeliveryMode, .standard)
        store.dictationDeliveryMode = .live
        XCTAssertEqual(SettingsStore(defaults: defaults).dictationDeliveryMode, .live)
    }

    func testOutputPreferenceChangesNotifyOtherConfigurationSurfaces() {
        let suite = "NuviTests.OutputPreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let changed = expectation(description: "output preferences changed")
        changed.expectedFulfillmentCount = 2
        let observer = NotificationCenter.default.addObserver(
            forName: .nuviOutputPreferencesDidChange,
            object: store,
            queue: nil
        ) { _ in
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.translationTarget = .englishUK
        store.dictationDeliveryMode = .live

        wait(for: [changed], timeout: 0.1)
    }

    func testPresentationVisibilityDefaultsOnAndPersistsIndependentChoices() {
        let suite = "NuviTests.PresentationPreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)

        XCTAssertTrue(store.showPill)
        XCTAssertTrue(store.showMenuBarStatus)

        store.showPill = false
        store.showMenuBarStatus = false

        let restored = SettingsStore(defaults: defaults)
        XCTAssertFalse(restored.showPill)
        XCTAssertFalse(restored.showMenuBarStatus)
    }

    func testPresentationVisibilityChangesNotifyRuntimeSurfaces() {
        let suite = "NuviTests.PresentationNotifications.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let changed = expectation(description: "presentation preferences changed")
        changed.expectedFulfillmentCount = 2
        let observer = NotificationCenter.default.addObserver(
            forName: .nuviPresentationPreferencesDidChange,
            object: store,
            queue: nil
        ) { _ in
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.showPill = false
        store.showMenuBarStatus = false

        wait(for: [changed], timeout: 0.1)
    }
}
