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
    private let translation: TranslationCoordinator
    private let pill: PillWindowController
    private let statusItem: StatusItemController
    let updates: AppUpdateService
    private let updateNotifications: AppUpdateNotificationAdapter
    private let settingsWindow: SettingsWindowController
    private var hotkeyManager: HotkeyManager?
    private var escHotkey: GlobalHotkey?
    private var cancellables = Set<AnyCancellable>()
    private let noticeLifetime = TransientNoticeLifetime()

    init() {
        let notifications = AppUpdateNotificationAdapter()
        let http = AppUpdateHTTPClient()
        let updates = AppUpdateService(
            installedVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            defaults: .standard,
            fetch: { try await http.fetch() },
            notify: { await notifications.notify($0) }
        )
        self.updates = updates
        updateNotifications = notifications
        settingsWindow = SettingsWindowController(updates: updates)
        let audio = AudioCaptureService()
        let translation = TranslationCoordinator()
        let configuration = SettingsStore.shared.transcriptionConfiguration
        let engine = TranscriptionEngineFactory.make(configuration: configuration)

        controller = DictationController(audio: audio,
                                         engine: engine,
                                         history: .shared,
                                         vocabulary: .shared,
                                         modes: .shared,
                                         textTranslator: translation,
                                         engineConfigurationID: configuration.identity)
        self.translation = translation
        pill = PillWindowController(controller: controller, translation: translation)
        statusItem = StatusItemController()
    }

    /// Pure presentation policy so state observers never make a pre-admission
    /// pill visible merely because the controller has begun preparing.
    static func shouldShowPill(for state: DictationState) -> Bool {
        switch state {
        case .listening, .transcribing, .inserted, .copied, .notice, .error:
            return true
        case .preparing, .idle:
            return false
        }
    }

    static func shouldEnableCancelHotkey(for state: DictationState) -> Bool {
        switch state {
        case .preparing, .listening, .transcribing:
            return true
        case .inserted, .copied, .idle, .notice, .error:
            return false
        }
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
        observeTranscriptionConfiguration()
        observePresentationPreferences()
        updates.start()
        observeUpdateLifecycle()
    }

    private func observeUpdateLifecycle() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.updates.check() }
            }
            .store(in: &cancellables)
    }

    private func observeTranscriptionConfiguration() {
        NotificationCenter.default.publisher(for: .nuviTranscriptionConfigurationDidChange)
            .sink { [weak self] _ in
                let configuration = SettingsStore.shared.transcriptionConfiguration
                self?.controller.reconfigure(
                    engine: TranscriptionEngineFactory.make(configuration: configuration),
                    configurationID: configuration.identity
                )
            }
            .store(in: &cancellables)
    }

    // Esc-to-cancel is only live while recording, so it never swallows Escape
    // for the rest of the system.
    private func enableCancelHotkey() {
        guard escHotkey == nil else { return }
        let esc = GlobalHotkey(id: HotkeyID.cancel,
                               onPress: { [weak self] in self?.controller.cancel() })
        let status = esc.register(keyCode: 53, modifiers: 0) // 53 = Escape
        guard status == noErr else {
            ShortcutsStore.shared.reportRegistrationIssue(.registrationFailed)
            return
        }
        escHotkey = esc
    }

    private func disableCancelHotkey() {
        escHotkey?.unregister()
        escHotkey = nil
    }

    private func showTransient(_ state: DictationState, duration: TimeInterval) {
        if SettingsStore.shared.showPill {
            pill.show()
        } else {
            pill.hide()
        }
        disableCancelHotkey()
        let expected = state
        DispatchQueue.main.async { [weak self] in
            self?.pill.resizeToContent()
        }
        noticeLifetime.schedule(after: duration, isCurrent: { [weak self] in
            self?.controller.state == expected
        }, hide: { [weak self] in self?.pill.hide() })
    }

    private func updatePillPresentation(for state: DictationState) {
        guard SettingsStore.shared.showPill, Self.shouldShowPill(for: state) else {
            pill.hide()
            return
        }
        pill.show()
    }

    private func observeState() {
        controller.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                self.noticeLifetime.invalidate()
                self.statusItem.update(state: state, isLiveSession: self.controller.isLiveSession)
                switch state {
                case .preparing, .listening, .transcribing:
                    self.updatePillPresentation(for: state)
                    self.enableCancelHotkey()
                case .inserted, .copied:
                    self.updatePillPresentation(for: state)
                    self.disableCancelHotkey()
                    if SettingsStore.shared.showPill, Self.shouldShowPill(for: state) {
                        self.pill.resizeToContent()
                    }
                case .idle:
                    self.updatePillPresentation(for: state)
                    self.disableCancelHotkey()
                case .notice:
                    self.showTransient(state, duration: PillTiming.noticeDuration)
                case .error:
                    self.showTransient(state, duration: PillTiming.errorDuration)
                }
            }
            .store(in: &cancellables)

        controller.$isLiveSession
            .removeDuplicates()
            .sink { [weak self] isLiveSession in
                guard let self else { return }
                self.statusItem.update(state: self.controller.state, isLiveSession: isLiveSession)
            }
            .store(in: &cancellables)

        // Grow the pill as the transcript streams in.
        controller.$transcript
            .removeDuplicates()
            .sink { [weak self] _ in
                guard SettingsStore.shared.showPill else { return }
                self?.pill.resizeToContent()
            }
            .store(in: &cancellables)
    }

    private func observePresentationPreferences() {
        NotificationCenter.default.publisher(for: .nuviPresentationPreferencesDidChange)
            .sink { [weak self] _ in
                guard let self else { return }
                self.statusItem.refreshPresentation()
                guard SettingsStore.shared.showPill else {
                    self.pill.hide()
                    return
                }
                if Self.shouldShowPill(for: self.controller.state) {
                    self.pill.show()
                    self.pill.resizeToContent()
                } else {
                    self.pill.hide()
                }
            }
            .store(in: &cancellables)
    }
}

/// Owns notice expiry without requiring the application composition root in tests.
@MainActor
final class TransientNoticeLifetime {
    typealias Scheduler = (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    private let scheduler: Scheduler
    private var generation = UUID()

    init(scheduler: @escaping Scheduler = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }) {
        self.scheduler = scheduler
    }

    func invalidate() { generation = UUID() }

    func schedule(after duration: TimeInterval,
                  isCurrent: @escaping () -> Bool,
                  hide: @escaping () -> Void) {
        invalidate()
        let token = generation
        scheduler(duration) { [weak self] in
            guard self?.generation == token, isCurrent() else { return }
            self?.invalidate()
            hide()
        }
    }
}
