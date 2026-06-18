import SwiftUI
import AppKit

/// Drives shortcut capture: a normal key (with optional modifiers) commits on
/// key-down; a modifier-only combo (e.g. hold ⌘) commits when the modifiers are
/// released. Escape cancels.
@MainActor
final class ShortcutRecording: ObservableObject {
    @Published var active = false
    @Published var preview = ""   // live feedback of held modifiers
    private var monitor: Any?
    private var accumulated: NSEvent.ModifierFlags = []
    var onCommit: ((KeyCombo) -> Void)?

    func start() {
        active = true
        preview = ""
        accumulated = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event)
            return nil // swallow while recording
        }
    }

    func stop() {
        active = false
        preview = ""
        accumulated = []
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            // Merge any modifiers we've been tracking via flagsChanged so a held
            // ⌘/⌥/⇧/⌃ is always part of the captured combo, not dropped.
            let mods = event.modifierFlags.union(accumulated).intersection(KeyCombo.relevantMask)
            if event.keyCode == 53 && mods.isEmpty { stop(); return } // Esc cancels
            onCommit?(KeyCombo(event: event, extraModifiers: accumulated))
            stop()

        case .flagsChanged:
            let current = event.modifierFlags.intersection(KeyCombo.relevantMask)
            if current.isEmpty {
                // All modifiers released → commit the modifier-only combo.
                if !accumulated.isEmpty {
                    onCommit?(KeyCombo(modifierOnly: accumulated))
                    stop()
                }
            } else {
                accumulated.formUnion(current)
                // Live feedback so the user sees the modifier the instant it's held.
                preview = KeyCombo(modifierOnly: accumulated).displayString
            }

        default:
            break
        }
    }
}

/// A "Record shortcut" control.
struct ShortcutRecorder: View {
    let combo: KeyCombo?
    var placeholder: String = "Record shortcut"
    var allowsClear: Bool = false
    let onChange: (KeyCombo?) -> Void

    @StateObject private var recording = ShortcutRecording()

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Text(buttonText)
                    .font(.system(size: 12, weight: .medium))
                    .frame(minWidth: 120)
            }
            .buttonStyle(.bordered)
            .tint(recording.active ? .blue : nil)

            if allowsClear, combo != nil, !recording.active {
                Button(action: { onChange(nil) }) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear { recording.onCommit = { onChange($0) } }
        .onDisappear { recording.stop() }
    }

    private var buttonText: String {
        if recording.active {
            return recording.preview.isEmpty ? "Press keys…" : recording.preview
        }
        return combo?.displayString ?? placeholder
    }

    private func toggle() {
        recording.active ? recording.stop() : recording.start()
    }
}
