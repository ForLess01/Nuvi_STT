import XCTest
@testable import Nuvi

final class NuviSoundTests: XCTestCase {
    func testSoundPresetCatalogHasThirtyOptions() {
        XCTAssertEqual(SoundPreset.allCases.count, 30)
    }

    func testDefaultSoundMappingsArePurposeful() {
        XCTAssertEqual(SoundEvent.start.defaultPreset, .pop)
        XCTAssertEqual(SoundEvent.stop.defaultPreset, .tink)
        XCTAssertEqual(SoundEvent.inserted.defaultPreset, .cleanInsert)
        XCTAssertEqual(SoundEvent.copied.defaultPreset, .funk)
        XCTAssertEqual(SoundEvent.cancel.defaultPreset, .bottle)
        XCTAssertEqual(SoundEvent.error.defaultPreset, .errorPunch)
    }
}
