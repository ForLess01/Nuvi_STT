import AppKit

/// A modifier-only global hotkey (e.g. hold ⌘ to talk), detected via
/// flagsChanged. Carbon's RegisterEventHotKey can't express modifier-only
/// combos, so we watch the modifier flags directly. Requires Accessibility.
///
/// Crucially, it does NOT fire on ⌘C / ⌘V / ⌘Tab etc.: the modifier must be
/// held ALONE (no other key) for a short delay before push-to-talk activates.
/// Pressing any other key while the modifier is down cancels activation.
public final class ModifierHotkey {
    private let mask: NSEvent.ModifierFlags
    private let onPress: () -> Void
    private let onRelease: (() -> Void)?

    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    private var isDown = false

    /// How long the modifier must be held alone before PTT starts. Long enough
    /// to let real shortcuts (⌘ + key) cancel it, short enough to feel instant.
    private let activationDelay: TimeInterval = 0.28

    public init(mask: NSEvent.ModifierFlags,
                onPress: @escaping () -> Void,
                onRelease: (() -> Void)? = nil) {
        self.mask = mask.intersection(KeyCombo.relevantMask)
        self.onPress = onPress
        self.onRelease = onRelease
    }

    public func register() {
        guard !mask.isEmpty else { return }
        add(.flagsChanged) { [weak self] in self?.handleFlags($0) }
        add(.keyDown) { [weak self] _ in self?.cancelPending() }
    }

    public func unregister() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        cancelPending()
        if isDown { isDown = false; onRelease?() }
    }

    private func add(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { handler($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { handler($0); return $0 }) {
            monitors.append(local)
        }
    }

    private func handleFlags(_ event: NSEvent) {
        let current = event.modifierFlags.intersection(KeyCombo.relevantMask)
        if current == mask {
            // Modifier(s) held exactly. Arm activation, but only commit if it
            // stays held alone past the delay (a real shortcut presses a key,
            // which cancels via the keyDown monitor).
            guard !isDown, pending == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.isDown = true
                self.onPress()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay, execute: work)
        } else {
            // Combo broken (released or changed).
            cancelPending()
            if isDown {
                isDown = false
                onRelease?()
            }
        }
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }
}
