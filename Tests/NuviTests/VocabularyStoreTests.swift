import XCTest
@testable import Nuvi

@MainActor
final class VocabularyStoreTests: XCTestCase {
    func testApplyReplacesUnicodeWholeWords() {
        let store = VocabularyStore()
        store.rules = [VocabularyRule(from: "año", to: "year")]

        XCTAssertEqual(store.apply(to: "este año termina"), "este year termina")
        XCTAssertEqual(store.apply(to: "este AÑO termina"), "este year termina")
        XCTAssertEqual(store.apply(to: "caño no cambia"), "caño no cambia")
    }

    func testApplyEscapesReplacementTemplate() {
        let store = VocabularyStore()
        store.rules = [VocabularyRule(from: "precio", to: "$10")]

        XCTAssertEqual(store.apply(to: "precio final"), "$10 final")
    }
}
