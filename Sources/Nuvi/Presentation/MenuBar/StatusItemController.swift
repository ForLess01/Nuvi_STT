import AppKit

/// The menu-bar presence: toggle, modes submenu, settings, quit. The modes
/// submenu is rebuilt each time it opens so it always reflects ModesStore.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let modesMenu = NSMenu()

    var onToggle: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        configureMenu()
    }

    private func configureButton() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle.fill",
                                   accessibilityDescription: "Nuvi")
            button.image?.isTemplate = true
        }
    }

    private func configureMenu() {
        let toggle = NSMenuItem(title: "Start / Stop Dictation",
                                action: #selector(toggleAction), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        let modesItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modesMenu.delegate = self
        modesItem.submenu = modesMenu
        menu.addItem(modesItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(settingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Nuvi",
                              action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // Rebuild the modes submenu on open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === modesMenu else { return }
        menu.removeAllItems()
        let store = ModesStore.shared
        for mode in store.modes {
            let item = NSMenuItem(title: mode.name,
                                  action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.id.uuidString
            item.state = (mode.id == store.activeModeID) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "Cycle: \(ShortcutsStore.shared.cycleMode.displayString)",
                              action: nil,
                              keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw) else { return }
        ModesStore.shared.activeModeID = id
    }

    @objc private func toggleAction() { onToggle?() }
    @objc private func settingsAction() { onOpenSettings?() }
    @objc private func quitAction() { onQuit?() }
}
