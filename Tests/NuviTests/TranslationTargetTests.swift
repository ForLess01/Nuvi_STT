import Foundation
import XCTest
@testable import Nuvi

final class TranslationTargetTests: XCTestCase {
    func testTargetsExposeOriginalThenRequestedRegionalOutputs() {
        XCTAssertEqual(
            TranslationTarget.allCases,
            [.original, .englishUS, .englishUK, .portugueseBrazil]
        )
        XCTAssertEqual(TranslationTarget.englishUS.language?.minimalIdentifier, "en")
        XCTAssertEqual(TranslationTarget.englishUK.language?.minimalIdentifier, "en-GB")
        XCTAssertEqual(TranslationTarget.portugueseBrazil.language?.minimalIdentifier, "pt")
        XCTAssertNil(TranslationTarget.original.language)
    }

    func testTranslationTargetPersistsAndDefaultsToOriginal() {
        let suite = "NuviTests.TranslationTarget.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.translationTarget, .original)
        store.translationTarget = .englishUK
        XCTAssertEqual(SettingsStore(defaults: defaults).translationTarget, .englishUK)
    }

    func testSameLanguageOutputBypassesUnsupportedTranslationPair() {
        XCTAssertFalse(
            TranslationCoordinator.requiresTranslation(
                "This sentence is already written in English.",
                target: .englishUK
            )
        )
        XCTAssertFalse(
            TranslationCoordinator.requiresTranslation(
                "Esta frase já está escrita em português.",
                target: .portugueseBrazil
            )
        )
        XCTAssertTrue(
            TranslationCoordinator.requiresTranslation(
                "Esta oración está escrita en español.",
                target: .englishUS
            )
        )
    }

    func testAutomaticSourceDetectionTranslatesTheActualTextWithoutEmptyPreflight() {
        XCTAssertFalse(
            TranslationCoordinator.shouldPrepareTranslation(sourceLanguage: nil)
        )
        XCTAssertTrue(
            TranslationCoordinator.shouldPrepareTranslation(
                sourceLanguage: Locale.Language(identifier: "es")
            )
        )
    }
}
