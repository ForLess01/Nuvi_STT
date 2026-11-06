import XCTest
@testable import Nuvi

@MainActor
final class HotkeyManagerTests: XCTestCase {
    func testConflictingShortcutRetainsPreviousValueAndPersistence() {
        let name = "NuviTests.Shortcuts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ShortcutsStore(defaults: defaults)
        store.pushToTalk = KeyCombo(modifierOnly: .option)
        let original = store.pushToTalk
        let persisted = defaults.data(forKey: "nuvi.sc.ptt")
        var duplicate = store.toggle
        duplicate.keyLabel = "Different display label"
        store.pushToTalk = duplicate
        XCTAssertEqual(store.pushToTalk, original)
        XCTAssertEqual(defaults.data(forKey: "nuvi.sc.ptt"), persisted)
    }
    func testDisabledPTTAndAcceptedShortcutPersistWithoutCollision() {
        let name = "NuviTests.Shortcuts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ShortcutsStore(defaults: defaults)
        store.pushToTalk = KeyCombo(modifierOnly: .option)
        XCTAssertEqual(ShortcutsStore(defaults: defaults).pushToTalk, store.pushToTalk)
        store.pushToTalk = nil
        XCTAssertNil(store.pushToTalk)
        XCTAssertNil(defaults.data(forKey: "nuvi.sc.ptt"))
        XCTAssertNil(store.issue)
        let previous = store.cycleMode
        store.cycleMode = store.toggle
        XCTAssertEqual(store.cycleMode, previous)
        XCTAssertEqual(store.issue, .conflict)
    }

    func testFailedRegistrationIsVisibleNotActiveAndDoesNotRebuildRecursively() {
        let name = "NuviTests.Shortcuts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ShortcutsStore(defaults: defaults)
        var attempts = 0
        var removals = 0
        let manager = HotkeyManager(store: store, factory: { id, _, _, _ in
            .init(register: { attempts += 1; return id != HotkeyID.toggleDictation },
                  unregister: { removals += 1 })
        })
        manager.start()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(removals, 1)
        XCTAssertEqual(manager.activeRegistrationCount, 1)
        XCTAssertEqual(store.issue, .registrationFailed)
        store.toggle = store.toggle
        XCTAssertEqual(store.issue, .registrationFailed)
        store.pushToTalk = KeyCombo(modifierOnly: .option)
        XCTAssertEqual(attempts, 5)
        XCTAssertEqual(removals, 3)
        XCTAssertEqual(manager.activeRegistrationCount, 2)
        XCTAssertEqual(store.issue, .registrationFailed)
    }

    func testLegacyDuplicatePreferencesAreNotRegisteredTwiceOrRewritten() throws {
        let name = "NuviTests.Shortcuts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let duplicate = try JSONEncoder().encode(KeyCombo.toggleDefault)
        defaults.set(duplicate, forKey: "nuvi.sc.ptt")
        let store = ShortcutsStore(defaults: defaults)
        let manager = HotkeyManager(store: store, factory: { _, _, _, _ in
            .init(register: { true }, unregister: {})
        })
        manager.start()
        XCTAssertEqual(manager.activeRegistrationCount, 2)
        XCTAssertEqual(store.issue, .conflict)
        XCTAssertEqual(defaults.data(forKey: "nuvi.sc.ptt"), duplicate)
    }

    func testNativeModifierMaskCollisionsIgnoreFunctionAndDisplayLabel() {
        let plain = KeyCombo(keyCode: 40, cocoaModifiers: .command, keyLabel: "K")
        let withFunction = KeyCombo(keyCode: 40, cocoaModifiers: [.command, .function], keyLabel: "Other")
        XCTAssertTrue(ShortcutsStore.conflicts(plain, withFunction))
        XCTAssertFalse(ShortcutsStore.conflicts(KeyCombo(modifierOnly: .command),
                                              KeyCombo(modifierOnly: [.command, .function])))
    }

    func testModifierRegistrationRollsBackPartialMonitorInstallation() {
        var installed = 0
        var removed = 0
        let hotkey = ModifierHotkey(mask: .command,
            installGlobal: { _, _ in nil },
            installLocal: { _, _ in installed += 1; return installed },
            removeMonitor: { _ in removed += 1 }, onPress: {})
        XCTAssertFalse(hotkey.register())
        XCTAssertEqual(installed, 3)
        XCTAssertEqual(removed, 3)
        hotkey.unregister()
        XCTAssertEqual(removed, 3)
    }

    func testModifierReregistrationReleasesOldMonitors() {
        var installed = 0
        var removed = 0
        let hotkey = ModifierHotkey(mask: .command,
            installGlobal: { _, _ in installed += 1; return installed },
            installLocal: { _, _ in installed += 1; return installed },
            removeMonitor: { _ in removed += 1 }, onPress: {})
        XCTAssertTrue(hotkey.register())
        XCTAssertTrue(hotkey.register())
        XCTAssertEqual(installed, 12)
        XCTAssertEqual(removed, 6)
        hotkey.unregister()
        XCTAssertEqual(removed, 12)
    }
    func testCancelShortcutIsReservedWithoutChangingPersistence() {
        let name = "NuviTests.Shortcuts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ShortcutsStore(defaults: defaults)
        let previous = store.toggle
        store.toggle = KeyCombo(keyCode: 53, cocoaModifiers: [], keyLabel: "esc")
        XCTAssertEqual(store.toggle, previous)
        XCTAssertNil(defaults.data(forKey: "nuvi.sc.toggle"))
        XCTAssertEqual(store.issue, .conflict)
    }
}
