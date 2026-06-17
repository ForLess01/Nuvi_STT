import Foundation
import Combine

/// Owns the live hotkey registrations and rebuilds them whenever the user edits
/// shortcuts. Picks the right mechanism per shortcut: Carbon for key combos,
/// a flagsChanged monitor for modifier-only combos. Toggle/cycle fire on press;
/// push-to-talk records while held.
@MainActor
public final class HotkeyManager {
    private let controller: DictationController
    private var carbonHotkeys: [GlobalHotkey] = []
    private var modifierHotkeys: [ModifierHotkey] = []
    private var cancellable: AnyCancellable?

    public init(controller: DictationController) {
        self.controller = controller
    }

    public func start() {
        rebuild()
        cancellable = ShortcutsStore.shared.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
    }

    private func rebuild() {
        carbonHotkeys.forEach { $0.unregister() }
        carbonHotkeys.removeAll()
        modifierHotkeys.forEach { $0.unregister() }
        modifierHotkeys.removeAll()

        let store = ShortcutsStore.shared

        register(id: HotkeyID.toggleDictation, combo: store.toggle,
                 onPress: { [weak controller] in controller?.toggle() })

        register(id: HotkeyID.cycleMode, combo: store.cycleMode,
                 onPress: { ModesStore.shared.cycle() })

        if let ptt = store.pushToTalk {
            register(id: HotkeyID.pushToTalk, combo: ptt,
                     onPress: { [weak controller] in controller?.start() },
                     onRelease: { [weak controller] in controller?.stop() })
        }
    }

    private func register(id: UInt32, combo: KeyCombo,
                          onPress: @escaping () -> Void,
                          onRelease: (() -> Void)? = nil) {
        if combo.isModifierOnly {
            let hotkey = ModifierHotkey(mask: combo.cocoaModifiers, onPress: onPress, onRelease: onRelease)
            hotkey.register()
            modifierHotkeys.append(hotkey)
        } else {
            let hotkey = GlobalHotkey(id: id, onPress: onPress, onRelease: onRelease)
            let status = hotkey.register(keyCode: combo.keyCode, modifiers: combo.carbonModifiers)
            if status != noErr {
                NSLog("Nuvi: failed to register hotkey \(combo.displayString), status=\(status)")
            }
            carbonHotkeys.append(hotkey)
        }
    }
}
