import Foundation
import Combine

@MainActor
public final class HotkeyManager {
    struct Registration {
        let register: () -> Bool
        let unregister: () -> Void
    }
    typealias Factory = (UInt32, KeyCombo, @escaping () -> Void, (() -> Void)?) -> Registration

    private let store: ShortcutsStore
    private let factory: Factory
    private let onToggle: () -> Void
    private let onCycle: () -> Void
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var registrations: [Registration] = []
    private var cancellable: AnyCancellable?
    var activeRegistrationCount: Int { registrations.count }

    public convenience init(controller: DictationController) {
        self.init(store: .shared, factory: Self.nativeRegistration,
                  onToggle: { [weak controller] in controller?.toggle() },
                  onCycle: { ModesStore.shared.cycle() },
                  onPress: { [weak controller] in controller?.start() },
                  onRelease: { [weak controller] in controller?.stop() })
    }

    init(store: ShortcutsStore, factory: @escaping Factory,
         onToggle: @escaping () -> Void = {}, onCycle: @escaping () -> Void = {},
         onPress: @escaping () -> Void = {}, onRelease: @escaping () -> Void = {}) {
        self.store = store
        self.factory = factory
        self.onToggle = onToggle
        self.onCycle = onCycle
        self.onPress = onPress
        self.onRelease = onRelease
    }

    public func start() {
        rebuild()
        cancellable = store.changes.sink { [weak self] in self?.rebuild() }
    }

    private func rebuild() {
        registrations.forEach { $0.unregister() }
        registrations.removeAll()
        var accepted: [KeyCombo] = []
        var issue: ShortcutsStore.Issue?
        let bindings: [(UInt32, KeyCombo?, () -> Void, (() -> Void)?)] = [
            (HotkeyID.toggleDictation, store.toggle, onToggle, nil),
            (HotkeyID.cycleMode, store.cycleMode, onCycle, nil),
            (HotkeyID.pushToTalk, store.pushToTalk, onPress, onRelease)
        ]
        for (id, combo, press, release) in bindings {
            guard let combo else { continue }
            // Also protect legacy preferences written before collision validation.
            guard !accepted.contains(where: { ShortcutsStore.conflicts($0, combo) }) else {
                issue = .conflict
                continue
            }
            accepted.append(combo)
            let registration = factory(id, combo, press, release)
            if registration.register() {
                registrations.append(registration)
            } else {
                registration.unregister()
                issue = .registrationFailed
            }
        }
        store.reportRegistrationIssue(issue)
    }

    private static func nativeRegistration(id: UInt32, combo: KeyCombo,
                                           press: @escaping () -> Void,
                                           release: (() -> Void)?) -> Registration {
        if combo.isModifierOnly {
            let hotkey = ModifierHotkey(mask: combo.cocoaModifiers, onPress: press, onRelease: release)
            return Registration(register: { hotkey.register() }, unregister: { hotkey.unregister() })
        }
        let hotkey = GlobalHotkey(id: id, onPress: press, onRelease: release)
        return Registration(register: {
            let status = hotkey.register(keyCode: combo.keyCode, modifiers: combo.carbonModifiers)
            if status != noErr {
                NSLog("Nuvi: failed to register hotkey \(combo.displayString), status=\(status)")
            }
            return status == noErr
        }, unregister: { hotkey.unregister() })
    }
}
