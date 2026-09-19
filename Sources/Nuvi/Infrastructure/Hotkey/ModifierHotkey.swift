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
    private let currentModifierFlags: () -> NSEvent.ModifierFlags
    private let watchdogInterval: TimeInterval

    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    private var isDown = false
    private var watchdogTimer: DispatchSourceTimer?

    /// How long the modifier must be held alone before PTT starts. Long enough
    /// to let real shortcuts (⌘ + key) cancel it, short enough to feel instant.
    private let activationDelay: TimeInterval

    public init(
        mask: NSEvent.ModifierFlags,
        activationDelay: TimeInterval = 0.28,
        watchdogInterval: TimeInterval = 0.04,
        currentModifierFlags: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags },
        onPress: @escaping () -> Void,
        onRelease: (() -> Void)? = nil
    ) {
        self.mask = mask.intersection(KeyCombo.relevantMask)
        self.activationDelay = activationDelay
        self.watchdogInterval = watchdogInterval
        self.currentModifierFlags = currentModifierFlags
        self.onPress = onPress
        self.onRelease = onRelease
    }

    deinit {
        unregister()
    }

    public func register() {
        guard !mask.isEmpty else { return }
        add(.flagsChanged) { [weak self] in self?.handleFlags($0) }
        add(.keyDown) { [weak self] _ in
            self?.cancelPending()
            if self?.isDown == true { self?.handleRelease() }
        }
        add(.systemDefined) { [weak self] _ in
            self?.cancelPending()
            if self?.isDown == true { self?.handleRelease() }
        }
    }

    public func unregister() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        handleRelease()
    }

    private func add(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { handler($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { handler($0); return $0 }) {
            monitors.append(local)
        }
    }

    internal var isActive: Bool { isDown }

    internal func handleKeyDownOrSystemDefined() {
        cancelPending()
        if isDown {
            handleRelease()
        }
    }

    private func handleFlags(_ event: NSEvent) {
        handleFlagsChanged(event.modifierFlags)
    }

    internal func handleFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        let current = flags.intersection(KeyCombo.relevantMask)
        if current == mask {
            // Modifier(s) held exactly. Arm activation, but only commit if it
            // stays held alone past the delay (a real shortcut presses a key,
            // which cancels via the keyDown monitor).
            guard !isDown, pending == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.isDown = true
                self.startWatchdog()
                self.onPress()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay, execute: work)
        } else {
            // Combo broken (released or changed).
            handleRelease()
        }
    }

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let intervalMs = max(10, Int(watchdogInterval * 1000))
        timer.schedule(
            deadline: .now() + watchdogInterval,
            repeating: .milliseconds(intervalMs),
            leeway: .milliseconds(5)
        )
        timer.setEventHandler { [weak self] in
            guard let self, self.isDown else { return }
            let current = self.currentModifierFlags().intersection(KeyCombo.relevantMask)
            if current != self.mask {
                self.handleRelease()
            }
        }
        watchdogTimer = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func handleRelease() {
        stopWatchdog()
        cancelPending()
        if isDown {
            isDown = false
            onRelease?()
        }
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }
}
