import XCTest
@testable import Nuvi

@MainActor
final class ModesStoreTests: XCTestCase {
    func testEffectiveModeUsesBoundModeBeforeActiveMode() {
        let store = ModesStore()
        let active = Mode(name: "Default")
        let bound = Mode(name: "Terminal", autoActivateBundleID: "com.apple.Terminal")
        store.modes = [active, bound]
        store.activeModeID = active.id

        XCTAssertEqual(store.effectiveMode(frontmostBundleID: "com.apple.Terminal"), bound)
        XCTAssertEqual(store.effectiveMode(frontmostBundleID: "com.apple.TextEdit"), active)
    }
}
