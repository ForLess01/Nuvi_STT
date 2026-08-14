import AppKit

struct StatusMenuCopy: Equatable {
    let language: AppLanguage

    private func text(_ en: String, _ es: String) -> String {
        language == .spanish ? es : en
    }

    var toggle: String { text("Start / Stop Dictation", "Iniciar / detener dictado") }
    var dictation: String { text("Dictation", "Dictado") }
    var mode: String { text("Mode", "Modo") }
    var recentTranscriptions: String { text("Recent Transcriptions", "Transcripciones recientes") }
    var translation: String { text("Translation (Beta)", "Traducción (Beta)") }
    var translationDetail: String {
        text(
            "Automatic source detection; settled results only",
            "Detección automática del origen; solo resultados definitivos"
        )
    }
    var settings: String { text("Settings…", "Configuración…") }
    var quit: String { text("Quit Nuvi", "Salir de Nuvi") }
    var historyDisabled: String { text("History is disabled", "El historial está desactivado") }
    var noRecentTranscriptions: String { text("No recent transcriptions", "No hay transcripciones recientes") }
    var enableLiveTitle: String { text("Enable Live Dictation (Beta)?", "¿Activar dictado en vivo (Beta)?") }
    var enableLiveButton: String { text("Enable Live Beta", "Activar Beta en vivo") }
    var cancel: String { text("Cancel", "Cancelar") }

    func deliveryLabel(_ mode: DictationDeliveryMode) -> String {
        switch mode {
        case .standard: return text("Standard", "Estándar")
        case .live: return text("Live (Beta)", "En vivo (Beta)")
        }
    }

    func translationLabel(_ target: TranslationTarget) -> String {
        switch target {
        case .original: return text("Original", "Original")
        case .englishUS: return text("English (US)", "Inglés (EE. UU.)")
        case .englishUK: return text("English (UK)", "Inglés (RU)")
        case .portugueseBrazil: return text("Portuguese (Brazil)", "Portugués (Brasil)")
        }
    }

    func cycleHint(_ shortcut: String) -> String {
        text("Cycle: \(shortcut)", "Cambiar: \(shortcut)")
    }

    func liveDetail(for engine: EnginePreference, modelID: String = "") -> String {
        switch engine {
        case .parakeet:
            if modelID.contains("v2") {
                return text(
                    "Live is supported; Parakeet v2 is optimized for English only",
                    "En vivo es compatible; Parakeet v2 está optimizado solo para inglés"
                )
            }
            return text(
                "Live uses incremental Parakeet recognition (higher CPU and energy use)",
                "En vivo usa reconocimiento incremental de Parakeet (más CPU y energía)"
            )
        case .whisperKit:
            if modelID.contains("large") || modelID.contains("medium") {
                return text(
                    "Live is supported, but this Whisper model updates more slowly and uses substantial resources",
                    "En vivo es compatible, pero este modelo Whisper actualiza más lento y usa bastantes recursos"
                )
            }
            return text(
                "Live uses rolling Whisper recognition (higher CPU and energy use)",
                "En vivo usa reconocimiento progresivo de Whisper (más CPU y energía)"
            )
        case .auto:
            return text(
                "Live uses SpeechAnalyzer first and keeps streaming if it falls back to Whisper",
                "En vivo usa primero SpeechAnalyzer y mantiene el flujo si cambia a Whisper"
            )
        case .speechAnalyzer:
            return text(
                "Live revises provisional text as you speak",
                "En vivo revisa el texto provisional mientras hablás"
            )
        }
    }

    func liveWarning(for engine: EnginePreference, modelID: String = "") -> String {
        switch engine {
        case .parakeet:
            if modelID.contains("v2") {
                return text(
                    "Live inserts and revises provisional text while you speak. Parakeet v2 works in Live mode but is optimized for English; use Parakeet v3 for supported multilingual dictation. Incremental recognition uses more CPU and energy than Standard mode.",
                    "En vivo inserta y revisa texto provisional mientras hablás. Parakeet v2 funciona en modo En vivo, pero está optimizado para inglés; usá Parakeet v3 para dictado multilingüe compatible. El reconocimiento incremental usa más CPU y energía que el modo Estándar."
                )
            }
            return text(
                "Live inserts and revises provisional text while you speak. Parakeet recognizes overlapping audio windows locally, which uses more CPU and energy than Standard mode.",
                "En vivo inserta y revisa texto provisional mientras hablás. Parakeet reconoce localmente ventanas de audio superpuestas, por lo que usa más CPU y energía que el modo Estándar."
            )
        case .auto:
            return text(
                "Live inserts and revises provisional text while you speak. SpeechAnalyzer adds little recognition overhead. If Auto falls back to WhisperKit, rolling local decoding keeps Live working but uses more CPU and may update more slowly with larger models.",
                "En vivo inserta y revisa texto provisional mientras hablás. SpeechAnalyzer añade poca carga de reconocimiento. Si Auto cambia a WhisperKit, la decodificación local progresiva mantiene En vivo funcionando, pero usa más CPU y puede actualizar más lento con modelos grandes."
            )
        case .speechAnalyzer:
            return text(
                "Live inserts and revises provisional text while you speak. SpeechAnalyzer already recognizes continuously, so the additional resource use is small and mainly comes from frequent text-field updates.",
                "En vivo inserta y revisa texto provisional mientras hablás. SpeechAnalyzer ya reconoce de forma continua, así que el uso adicional de recursos es pequeño y proviene principalmente de las actualizaciones frecuentes del campo de texto."
            )
        case .whisperKit:
            if modelID.contains("large") || modelID.contains("medium") {
                return text(
                    "Live is supported with this Whisper model, but each provisional revision reprocesses the accumulated audio locally. Expect higher CPU, Neural Engine and memory use, plus slower updates than Tiny, Base, Small or Parakeet.",
                    "En vivo es compatible con este modelo Whisper, pero cada revisión provisional vuelve a procesar localmente el audio acumulado. Esperá mayor uso de CPU, Neural Engine y memoria, además de actualizaciones más lentas que con Tiny, Base, Small o Parakeet."
                )
            }
            return text(
                "Live inserts and revises provisional text using rolling local Whisper recognition. It works with this model, but uses more CPU and energy than Standard mode.",
                "En vivo inserta y revisa texto provisional mediante reconocimiento local progresivo de Whisper. Funciona con este modelo, pero usa más CPU y energía que el modo Estándar."
            )
        }
    }
}

enum MenuBarStatusPresentation {
    static func label(
        for state: DictationState,
        language: AppLanguage,
        showsStatus: Bool,
        isLiveSession: Bool
    ) -> String? {
        guard showsStatus else { return nil }
        let spanish = language == .spanish
        switch state {
        case .listening:
            return isLiveSession ? "LIVE" : (spanish ? "Escuchando…" : "Listening…")
        case .transcribing:
            return isLiveSession ? "LIVE" : (spanish ? "Transcribiendo…" : "Transcribing…")
        case .inserted:
            return spanish ? "Insertado" : "Inserted"
        case .copied:
            return spanish ? "Copiado" : "Copied"
        case .idle, .notice, .error:
            return nil
        }
    }
}

@MainActor
enum LiveModeConfirmation {
    static func requestIfNeeded() -> Bool {
        let settings = SettingsStore.shared
        guard !settings.hasAcknowledgedLiveMode else { return true }

        let copy = StatusMenuCopy(language: LocalizationStore.shared.language)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = copy.enableLiveTitle
        alert.informativeText = copy.liveWarning(
            for: settings.enginePreference,
            modelID: settings.selectedModelID
        )
        alert.addButton(withTitle: copy.enableLiveButton)
        alert.addButton(withTitle: copy.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        settings.hasAcknowledgedLiveMode = true
        return true
    }
}

enum RecentTranscriptionsMenuModel: Equatable {
    struct Item: Equatable {
        let title: String
        let fullText: String
    }

    case disabled
    case empty
    case entries([Item])

    static func make(
        entries: [HistoryEntry],
        isHistoryEnabled: Bool,
        limit: Int = 5
    ) -> RecentTranscriptionsMenuModel {
        guard isHistoryEnabled else { return .disabled }
        let items = entries.prefix(max(0, limit)).map { entry in
            Item(title: previewTitle(for: entry.text), fullText: entry.text)
        }
        return items.isEmpty ? .empty : .entries(items)
    }

    private static func previewTitle(for text: String, limit: Int = 64) -> String {
        let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit - 1)) + "…"
    }
}

/// Owns the actual AppKit submenu and its copy action. Keeping this separate
/// from the status item makes delegate rebuilding and represented-object
/// behavior testable without creating a system status item.
@MainActor
final class RecentTranscriptionsMenuController: NSObject, NSMenuDelegate {
    let menu: NSMenu
    private let historyStore: HistoryStore
    private let isHistoryEnabled: () -> Bool
    private let copyText: (String) -> Bool
    private let language: () -> AppLanguage

    init(
        menu: NSMenu = NSMenu(),
        historyStore: HistoryStore,
        isHistoryEnabled: @escaping () -> Bool,
        language: @escaping () -> AppLanguage = { LocalizationStore.shared.language },
        copyText: @escaping (String) -> Bool
    ) {
        self.menu = menu
        self.historyStore = historyStore
        self.isHistoryEnabled = isHistoryEnabled
        self.language = language
        self.copyText = copyText
        super.init()
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()
        let model = RecentTranscriptionsMenuModel.make(
            entries: historyStore.entries,
            isHistoryEnabled: isHistoryEnabled()
        )
        let copy = StatusMenuCopy(language: language())
        switch model {
        case .disabled:
            addDisabledItem(title: copy.historyDisabled)
        case .empty:
            addDisabledItem(title: copy.noRecentTranscriptions)
        case .entries(let entries):
            for entry in entries {
                let item = NSMenuItem(
                    title: entry.title,
                    action: #selector(copyRecentAction(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = entry.fullText
                menu.addItem(item)
            }
        }
    }

    private func addDisabledItem(title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc func copyRecentAction(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        _ = copyText(text)
    }
}

/// The menu-bar presence: toggle, modes submenu, settings, quit. The modes
/// submenu is rebuilt each time it opens so it always reflects ModesStore.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let deliveryMenu = NSMenu()
    private let modesMenu = NSMenu()
    private let translationMenu = NSMenu()
    private let recentController: RecentTranscriptionsMenuController
    private var dictationState: DictationState = .idle
    private var isLiveSession = false

    var onToggle: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    override convenience init() {
        self.init(
            historyStore: .shared,
            isHistoryEnabled: { SettingsStore.shared.saveHistory }
        )
    }

    init(historyStore: HistoryStore, isHistoryEnabled: @escaping () -> Bool) {
        recentController = RecentTranscriptionsMenuController(
            historyStore: historyStore,
            isHistoryEnabled: isHistoryEnabled,
            copyText: { text in
                StatusItemController.copyRecentTranscription(text, to: .general)
            }
        )
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureButton()
        configureMenu()
    }

    private func configureButton() {
        if let button = statusItem.button {
            button.image = NuviBrand.menuBarImage(pointSize: 20)
            let label = MenuBarStatusPresentation.label(
                for: dictationState,
                language: LocalizationStore.shared.language,
                showsStatus: SettingsStore.shared.showMenuBarStatus,
                isLiveSession: isLiveSession
            )
            button.title = label ?? ""
            button.imagePosition = label == nil ? .imageOnly : .imageLeft
            button.imageScaling = .scaleProportionallyUpOrDown
            button.font = roundedMenuBarFont
            button.toolTip = "Nuvi"
            statusItem.length = label == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength
        }
    }

    func update(state: DictationState, isLiveSession: Bool) {
        dictationState = state
        self.isLiveSession = isLiveSession
        configureButton()
    }

    func refreshPresentation() {
        configureButton()
    }

    private var roundedMenuBarFont: NSFont {
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    private func configureMenu() {
        menu.delegate = self
        rebuildRootMenu()
        statusItem.menu = menu
    }

    private func rebuildRootMenu() {
        menu.removeAllItems()
        let copy = StatusMenuCopy(language: LocalizationStore.shared.language)
        let toggle = NSMenuItem(title: copy.toggle,
                                action: #selector(toggleAction), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        let deliveryItem = NSMenuItem(title: copy.dictation, action: nil, keyEquivalent: "")
        deliveryMenu.delegate = self
        deliveryItem.submenu = deliveryMenu
        menu.addItem(deliveryItem)

        let modesItem = NSMenuItem(title: copy.mode, action: nil, keyEquivalent: "")
        modesMenu.delegate = self
        modesItem.submenu = modesMenu
        menu.addItem(modesItem)

        let recentItem = NSMenuItem(title: copy.recentTranscriptions, action: nil, keyEquivalent: "")
        recentItem.submenu = recentController.menu
        menu.addItem(recentItem)

        let translationItem = NSMenuItem(title: copy.translation, action: nil, keyEquivalent: "")
        translationMenu.delegate = self
        translationItem.submenu = translationMenu
        menu.addItem(translationItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: copy.settings,
                                  action: #selector(settingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: copy.quit,
                              action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

    }

    // Rebuild dynamic submenus on open so checkmarks always reflect persisted
    // settings, including changes made by another Nuvi surface.
    func menuNeedsUpdate(_ menu: NSMenu) {
        configureButton()
        if menu === self.menu {
            rebuildRootMenu()
            return
        }
        if menu === deliveryMenu {
            rebuildDeliveryMenu()
            return
        }
        if menu === translationMenu {
            rebuildTranslationMenu()
            return
        }
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
        let copy = StatusMenuCopy(language: LocalizationStore.shared.language)
        let hint = NSMenuItem(title: copy.cycleHint(ShortcutsStore.shared.cycleMode.displayString),
                              action: nil,
                              keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
    }

    private func rebuildDeliveryMenu() {
        deliveryMenu.removeAllItems()
        let selected = SettingsStore.shared.dictationDeliveryMode
        let engine = SettingsStore.shared.enginePreference
        let modelID = SettingsStore.shared.selectedModelID
        let copy = StatusMenuCopy(language: LocalizationStore.shared.language)
        for mode in DictationDeliveryMode.allCases {
            let item = NSMenuItem(
                title: copy.deliveryLabel(mode),
                action: #selector(selectDeliveryMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == selected ? .on : .off
            deliveryMenu.addItem(item)
        }

        let detail = NSMenuItem(
            title: copy.liveDetail(for: engine, modelID: modelID),
            action: nil,
            keyEquivalent: ""
        )
        detail.isEnabled = false
        deliveryMenu.addItem(.separator())
        deliveryMenu.addItem(detail)
    }

    private func rebuildTranslationMenu() {
        translationMenu.removeAllItems()
        let selected = SettingsStore.shared.translationTarget
        let copy = StatusMenuCopy(language: LocalizationStore.shared.language)
        for target in TranslationTarget.allCases {
            let item = NSMenuItem(
                title: copy.translationLabel(target),
                action: #selector(selectTranslationTarget(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = target.rawValue
            item.state = target == selected ? .on : .off
            translationMenu.addItem(item)
        }
        let detail = NSMenuItem(title: copy.translationDetail, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        translationMenu.addItem(.separator())
        translationMenu.addItem(detail)
    }

    @discardableResult
    static func copyRecentTranscription(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw) else { return }
        ModesStore.shared.activeModeID = id
    }

    @objc private func selectTranslationTarget(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let target = TranslationTarget(rawValue: raw) else { return }
        SettingsStore.shared.translationTarget = target
    }

    @objc private func selectDeliveryMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = DictationDeliveryMode(rawValue: raw) else { return }
        if mode == .live, !LiveModeConfirmation.requestIfNeeded() {
            return
        }
        SettingsStore.shared.dictationDeliveryMode = mode
    }

    @objc private func toggleAction() { onToggle?() }
    @objc private func settingsAction() { onOpenSettings?() }
    @objc private func quitAction() { onQuit?() }
}
