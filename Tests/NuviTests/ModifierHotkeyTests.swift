import XCTest
import AppKit
@testable import Nuvi

@MainActor
final class ModifierHotkeyTests: XCTestCase {
    private func waitUntil(
        timeout: TimeInterval = 1.0,
        _ predicate: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testModifierHotkeyLifecycle() async {
        var pressed = false
        var released = false

        let hotkey = ModifierHotkey(
            mask: .function,
            activationDelay: 0.02,
            watchdogInterval: 0.02,
            currentModifierFlags: { [] },
            onPress: { pressed = true },
            onRelease: { released = true }
        )

        hotkey.register()
        hotkey.unregister()

        XCTAssertFalse(pressed)
        XCTAssertFalse(released)
    }

    func testSystemDefinedCancelsPendingActivation() async {
        var pressed = false
        var released = false
        let currentFlags: NSEvent.ModifierFlags = [.function]

        let hotkey = ModifierHotkey(
            mask: .function,
            activationDelay: 0.08,
            watchdogInterval: 0.05,
            currentModifierFlags: { currentFlags },
            onPress: { pressed = true },
            onRelease: { released = true }
        )
        hotkey.register()
        defer { hotkey.unregister() }

        // Modifier pressed
        hotkey.handleFlagsChanged(.function)
        // Media key / system-defined event fires while Fn held before activation delay
        hotkey.handleKeyDownOrSystemDefined()

        try? await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertFalse(pressed, "Pending activation should have been cancelled by systemDefined event")
        XCTAssertFalse(released)
        XCTAssertFalse(hotkey.isActive)
    }

    func testSystemDefinedReleasesActivePTT() async {
        var pressed = false
        var released = false
        let currentFlags: NSEvent.ModifierFlags = [.function]

        let hotkey = ModifierHotkey(
            mask: .function,
            activationDelay: 0.03,
            watchdogInterval: 0.05,
            currentModifierFlags: { currentFlags },
            onPress: { pressed = true },
            onRelease: { released = true }
        )
        hotkey.register()
        defer { hotkey.unregister() }

        hotkey.handleFlagsChanged(.function)
        await waitUntil(timeout: 1.0) { pressed }
        XCTAssertTrue(pressed)
        XCTAssertFalse(released)
        XCTAssertTrue(hotkey.isActive)

        // While PTT is actively down, media key / system-defined event fires
        hotkey.handleKeyDownOrSystemDefined()
        await waitUntil(timeout: 1.0) { released }

        XCTAssertTrue(released, "Active PTT should be released when systemDefined event fires")
        XCTAssertFalse(hotkey.isActive)
    }

    func testKeyDownCancelsPendingActivation() async {
        var pressed = false
        var released = false
        let currentFlags: NSEvent.ModifierFlags = [.function]

        let hotkey = ModifierHotkey(
            mask: .function,
            activationDelay: 0.08,
            watchdogInterval: 0.05,
            currentModifierFlags: { currentFlags },
            onPress: { pressed = true },
            onRelease: { released = true }
        )
        hotkey.register()
        defer { hotkey.unregister() }

        hotkey.handleFlagsChanged(.function)
        // Key pressed before activation delay
        hotkey.handleKeyDownOrSystemDefined()

        try? await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertFalse(pressed, "Pending activation should have been cancelled by keyDown event")
        XCTAssertFalse(released)
        XCTAssertFalse(hotkey.isActive)
    }

    func testKeyDownReleasesActivePTT() async {
        var pressed = false
        var released = false
        let currentFlags: NSEvent.ModifierFlags = [.function]

        let hotkey = ModifierHotkey(
            mask: .function,
            activationDelay: 0.03,
            watchdogInterval: 0.05,
            currentModifierFlags: { currentFlags },
            onPress: { pressed = true },
            onRelease: { released = true }
        )
        hotkey.register()
        defer { hotkey.unregister() }

        hotkey.handleFlagsChanged(.function)
        await waitUntil(timeout: 1.0) { pressed }
        XCTAssertTrue(pressed)
        XCTAssertFalse(released)
        XCTAssertTrue(hotkey.isActive)

        // While PTT is actively down, pressing any key should release it
        hotkey.handleKeyDownOrSystemDefined()
        await waitUntil(timeout: 1.0) { released }

        XCTAssertTrue(released, "Active PTT should be released when keyDown event fires")
        XCTAssertFalse(hotkey.isActive)
    }

    func testWatchdogReleasesWhenModifierFlagDropped() async {
        var pressed = false
        var released = false
        var currentFlags: NSEvent.ModifierFlags = [.function]

        let hotkey = ModifierHotkey(
            mask: .function,
            activationDelay: 0.03,
            watchdogInterval: 0.02,
            currentModifierFlags: { currentFlags },
            onPress: { pressed = true },
            onRelease: { released = true }
        )
        hotkey.register()
        defer { hotkey.unregister() }

        hotkey.handleFlagsChanged(.function)
        await waitUntil(timeout: 1.0) { pressed }
        XCTAssertTrue(pressed)

        // Drop modifier flag without explicit event - watchdog must release
        currentFlags = []
        await waitUntil(timeout: 1.0) { released }
        XCTAssertTrue(released)
        XCTAssertFalse(hotkey.isActive)
    }
}
