import AppKit
import Combine

/// Composition root: builds the object graph and connects state to UI.
///
/// This is the ONLY place where concrete adapters meet. Everything below depends
/// on abstractions; everything above is wiring. Swap an engine, a hotkey, or the
/// output strategy here without touching the rest of the app.
@MainActor
final class AppEnvironment {
    private enum PillTiming {
        static let noticeDuration: TimeInterval = 2.0
        static let errorDuration: TimeInterval = 4.0
    }

    let controller: DictationController
    private let pill: PillWindowController
    private let statusItem: StatusItemController
    private let settingsWindow = SettingsWindowController()
    private var hotkeyManager: HotkeyManager?
    private var escHotkey: GlobalHotkey?
    private var cancellables = Set<AnyCancellable>()

    init() {
        let audio = AudioCaptureService()
        let engine = TranscriptionEngineFactory.makeDefault()

        controller = DictationController(audio: audio,
                                         engine: engine,
                                         history: .shared,
                                         vocabulary: .shared,
                                         modes: .shared)
        pill = PillWindowController(controller: controller)
        statusItem = StatusItemController()
    }

    func start() {
        // Ask for Accessibility up front (needed to paste into the focused app).
        TextInjector.ensureAccessibilityPermission()

        statusItem.onToggle = { [weak self] in self?.controller.toggle() }
        statusItem.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        statusItem.onQuit = { NSApp.terminate(nil) }

        let manager = HotkeyManager(controller: controller)
        manager.start()
        hotkeyManager = manager

        observeState()
    }

    // Esc-to-cancel is only live while recording, so it never swallows Escape
    // for the rest of the system.
    private func enableCancelHotkey() {
        guard escHotkey == nil else { return }
        let esc = GlobalHotkey(id: HotkeyID.cancel,
                               onPress: { [weak self] in self?.controller.cancel() })
        esc.register(keyCode: 53, modifiers: 0) // 53 = Escape
        escHotkey = esc
    }

    private func disableCancelHotkey() {
        escHotkey?.unregister()
        escHotkey = nil
    }

    private func showTransient(_ state: DictationState, duration: TimeInterval) {
        pill.show()
        disableCancelHotkey()
        let expected = state
        DispatchQueue.main.async { [weak self] in
            self?.pill.resizeToContent()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            if self.controller.state == expected {
                self.pill.hide()
            }
        }
    }

    private func observeState() {
        controller.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .listening, .transcribing:
                    self.pill.show()
                    self.enableCancelHotkey()
                case .idle:
                    self.pill.hide()
                    self.disableCancelHotkey()
                case .notice:
                    self.showTransient(state, duration: PillTiming.noticeDuration)
                case .error:
                    self.showTransient(state, duration: PillTiming.errorDuration)
                }
            }
            .store(in: &cancellables)

        // Grow the pill as the transcript streams in.
        controller.$transcript
            .removeDuplicates()
            .sink { [weak self] _ in self?.pill.resizeToContent() }
            .store(in: &cancellables)
    }
}
