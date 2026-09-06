import SwiftUI
import ServiceManagement
import AppKit

/// Sidebar sections, mirroring SuperWhisper's layout. Functional panels are
/// built; the rest are honest "coming soon" placeholders so navigation matches.
enum SettingsSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case configuration = "Configuration"
    case appearance = "Appearance"
    case vocabulary = "Vocabulary"
    case history = "History"
    case modes = "Modes"
    case sound = "Sound"
    case models = "Models library"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .configuration: return "gearshape.fill"
        case .appearance: return "circle.hexagongrid.fill"
        case .vocabulary: return "book.fill"
        case .history: return "clock.fill"
        case .modes: return "plus.square.fill"
        case .sound: return "speaker.wave.2.fill"
        case .models: return "square.stack.3d.up.fill"
        }
    }

    var tint: Color {
        NuviPalette.lavender
    }
}

struct SettingsView: View {
    @State private var selection: SettingsSection = .configuration
    @ObservedObject private var loc = LocalizationStore.shared

    private func sectionName(_ s: SettingsSection) -> String {
        switch s {
        case .home: return tr("Home", "Inicio")
        case .configuration: return tr("Configuration", "Configuración")
        case .appearance: return tr("Appearance", "Apariencia")
        case .vocabulary: return tr("Vocabulary", "Vocabulario")
        case .history: return tr("History", "Historial")
        case .modes: return tr("Modes", "Modos")
        case .sound: return tr("Sound", "Sonido")
        case .models: return tr("Models library", "Biblioteca de modelos")
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                HStack(spacing: 10) {
                    IconTile(symbol: section.icon, color: section.tint)
                    Text(sectionName(section)).font(.system(size: 13))
                }
                .tag(section)
                .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            if selection == .models {
                ModelsLibraryView()
                    .background(NuviTheme.background)
            } else {
                ScrollView { detail.padding(24) }
                    .background(NuviTheme.background)
            }
        }
        .frame(width: 780, height: 580)
        .preferredColorScheme(.dark)
        .fontDesign(.rounded)
        .tint(NuviPalette.lavender)
        .foregroundStyle(NuviPalette.softWhite)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .home: HomePanel()
        case .configuration: ConfigurationPanel()
        case .appearance: AppearancePanel()
        case .vocabulary: VocabularyPanel()
        case .history: HistoryPanel()
        case .modes: ModesPanel()
        case .sound: SoundPanel()
        case .models: EmptyView()
        }
    }
}

// MARK: - Shared scaffold

private struct PanelScaffold<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.system(size: 26, weight: .bold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Home

private struct HomePanel: View {
    @ObservedObject private var shortcuts = ShortcutsStore.shared
    @ObservedObject private var loc = LocalizationStore.shared

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        return "v\(v)"
    }

    /// The same official isologo-only icon the app ships with, used as a faint
    /// background watermark.
    private var appLogo: Image {
        if let icon = NSImage(named: NSImage.applicationIconName) {
            return Image(nsImage: icon)
        }
        return Image(nsImage: NuviBrand.menuBarImage(pointSize: 256))
    }

    var body: some View {
        PanelScaffold(title: tr("Home", "Inicio")) {
            // Landing hero
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let wordmark = NuviBrand.wordmarkImage() {
                        Image(nsImage: wordmark)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 162, height: 50)
                            .accessibilityLabel("Nuvi")
                    }
                    Text(appVersion)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(NuviPalette.softWhite.opacity(0.08))
                        .cornerRadius(6)
                        .foregroundStyle(.secondary)
                }
                Text(tr("On-device dictation, anywhere on your Mac.",
                        "Dictado en el dispositivo, en cualquier parte de tu Mac."))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                Text(tr("Hold your shortcut to talk, release to drop the text into whatever app is focused. Everything is transcribed locally — Whisper or Parakeet — so your voice never leaves the device. The ferrofluid pill reacts to your voice while you speak.",
                        "Mantené tu atajo para hablar y soltalo para insertar el texto en la app que tengas enfocada. Todo se transcribe localmente — Whisper o Parakeet — así tu voz nunca sale del dispositivo. La pill de ferrofluido reacciona a tu voz mientras hablás."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)

            SectionHeader(text: tr("Shortcuts", "Atajos"))
            Card {
                // Live: reflects whatever is configured in Configuration.
                SettingRow(title: tr("Toggle dictation", "Activar/desactivar dictado")) { Shortcut(keys: shortcuts.toggle.keyCaps) }
                if let ptt = shortcuts.pushToTalk {
                    RowDivider()
                    SettingRow(title: tr("Push to talk", "Mantener para hablar")) { Shortcut(keys: ptt.keyCaps) }
                }
                RowDivider()
                SettingRow(title: tr("Cancel", "Cancelar")) { Shortcut(keys: ["esc"]) }
            }

            SectionHeader(text: tr("Connect", "Conectar"))
            Card {
                Link(destination: URL(string: "https://github.com/forless01")!) {
                    SettingRow(title: "GitHub", subtitle: "@forless01") {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 500, alignment: .topLeading)
        // Large, faint app-icon watermark spanning the window height.
        .background(alignment: .trailing) {
            appLogo
                .resizable()
                .scaledToFit()
                .frame(maxHeight: .infinity)
                .opacity(0.5)
                .offset(x: 90)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Configuration

private struct ConfigurationPanel: View {
    @State private var locale = SettingsStore.shared.localeIdentifier
    @State private var restoreClipboard = SettingsStore.shared.restoreClipboard
    @State private var saveHistory = SettingsStore.shared.saveHistory
    @State private var inputDeviceUID = SettingsStore.shared.inputDeviceUID
    @State private var inputDevices = AudioInputDevice.inputDevices()
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var launchAtLoginError: String?
    @State private var engine = SettingsStore.shared.enginePreference
    @State private var deliveryMode = SettingsStore.shared.dictationDeliveryMode
    @State private var translationTarget = SettingsStore.shared.translationTarget
    @State private var silenceDetection = SettingsStore.shared.silenceDetectionEnabled
    @State private var silenceDuration = SettingsStore.shared.silenceDurationThreshold
    @ObservedObject private var shortcuts = ShortcutsStore.shared
    @ObservedObject private var loc = LocalizationStore.shared

    private let localeCodes = ["es-ES", "es-419", "en-US", "en-GB", "pt-BR", "fr-FR", "de-DE", "it-IT"]

    private func localeName(_ code: String) -> String {
        switch code {
        case "es-ES": return tr("Spanish (Spain)", "Español (España)")
        case "es-419": return tr("Spanish (Latin America)", "Español (Latinoamérica)")
        case "en-US": return tr("English (US)", "Inglés (EE. UU.)")
        case "en-GB": return tr("English (UK)", "Inglés (RU)")
        case "pt-BR": return tr("Portuguese (Brazil)", "Portugués (Brasil)")
        case "fr-FR": return tr("French", "Francés")
        case "de-DE": return tr("German", "Alemán")
        case "it-IT": return tr("Italian", "Italiano")
        default: return code
        }
    }

    var body: some View {
        PanelScaffold(title: tr("Configuration", "Configuración")) {
            SectionHeader(text: tr("Interface", "Interfaz"))
            Card {
                SettingRow(title: tr("App language", "Idioma de la app"),
                           subtitle: tr("Language of the Settings window", "Idioma de la ventana de Configuración")) {
                    Picker("", selection: $loc.language) {
                        ForEach(AppLanguage.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }

            SectionHeader(text: tr("Transcription", "Transcripción"))
            Card {
                SettingRow(title: tr("Language", "Idioma")) {
                    Picker("", selection: $locale) {
                        ForEach(localeCodes, id: \.self) { Text(localeName($0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .onChange(of: locale) { _, new in SettingsStore.shared.localeIdentifier = new }
                }
                RowDivider()
                SettingRow(title: tr("Engine", "Motor"),
                           subtitle: tr("Engine change applies to the next dictation", "El cambio de motor se aplica al próximo dictado")) {
                    Picker("", selection: $engine) {
                        ForEach(EnginePreference.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .onChange(of: engine) { _, new in SettingsStore.shared.enginePreference = new }
                }
                RowDivider()
                SettingRow(
                    title: tr("Dictation mode", "Modo de dictado"),
                    subtitle: liveModeSubtitle
                ) {
                    Picker("", selection: $deliveryMode) {
                        Text(tr("Standard", "Estándar")).tag(DictationDeliveryMode.standard)
                        Text(tr("Live (Beta)", "En vivo (Beta)")).tag(DictationDeliveryMode.live)
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .onChange(of: deliveryMode) { _, new in setDeliveryMode(new) }
                }
                RowDivider()
                SettingRow(
                    title: tr("Translation (Beta)", "Traducción (Beta)"),
                    subtitle: tr(
                        "Detects the spoken language and translates the settled result before delivery",
                        "Detecta el idioma hablado y traduce el resultado definitivo antes de entregarlo"
                    )
                ) {
                    Picker("", selection: $translationTarget) {
                        ForEach(TranslationTarget.allCases, id: \.self) { target in
                            Text(translationTargetName(target)).tag(target)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .onChange(of: translationTarget) { _, new in
                        SettingsStore.shared.translationTarget = new
                    }
                }
                RowDivider()
                SettingRow(
                    title: tr("Auto-stop on silence", "Auto-detener por silencio"),
                    subtitle: tr(
                        "Automatically finish dictation after a brief pause in speech",
                        "Finaliza automáticamente el dictado tras una breve pausa al hablar"
                    )
                ) {
                    Toggle("", isOn: $silenceDetection)
                        .labelsHidden()
                        .onChange(of: silenceDetection) { _, value in
                            SettingsStore.shared.silenceDetectionEnabled = value
                        }
                }
                if silenceDetection {
                    RowDivider()
                    SettingRow(
                        title: tr("Silence duration", "Duración de silencio"),
                        subtitle: tr("How long to wait after you stop speaking", "Tiempo de espera tras dejar de hablar")
                    ) {
                        Picker("", selection: $silenceDuration) {
                            Text("1.0s").tag(1.0)
                            Text("1.5s").tag(1.5)
                            Text("2.0s").tag(2.0)
                            Text("3.0s").tag(3.0)
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        .onChange(of: silenceDuration) { _, value in
                            SettingsStore.shared.silenceDurationThreshold = value
                        }
                    }
                }
                RowDivider()
                SettingRow(title: tr("Microphone", "Micrófono"),
                           subtitle: tr("Automatic preserves Bluetooth playback; explicit selection uses that device", "Automático preserva el audio Bluetooth; una selección explícita usa ese dispositivo")) {
                    Picker("", selection: $inputDeviceUID) {
                        Text(tr("Automatic (built-in)", "Automático (integrado)")).tag("")
                        Text(tr("System default", "Predeterminado del sistema")).tag("default")
                        if !inputDevices.isEmpty {
                            Divider()
                            ForEach(inputDevices) { Text($0.settingsLabel).tag($0.uid) }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .onChange(of: inputDeviceUID) { _, new in SettingsStore.shared.inputDeviceUID = new }
                }
            }

            SectionHeader(text: tr("Behavior", "Comportamiento"))
            Card {
                SettingRow(title: tr("Restore clipboard after pasting", "Restaurar portapapeles tras pegar")) {
                    Toggle("", isOn: $restoreClipboard).labelsHidden()
                        .onChange(of: restoreClipboard) { _, new in SettingsStore.shared.restoreClipboard = new }
                }
                RowDivider()
                SettingRow(title: tr("Save dictation history", "Guardar historial de dictado"),
                           subtitle: tr("Off keeps transcribed text off disk and clears existing history", "Apagado mantiene el texto fuera del disco y borra el historial existente")) {
                    Toggle("", isOn: $saveHistory).labelsHidden()
                        .onChange(of: saveHistory) { _, new in
                            SettingsStore.shared.saveHistory = new
                            if !new { HistoryStore.shared.clear() }
                        }
                }
                RowDivider()
                SettingRow(title: tr("Launch at login", "Abrir al iniciar sesión"),
                           subtitle: launchAtLoginSubtitle) {
                    Toggle("", isOn: $launchAtLogin).labelsHidden()
                        .onChange(of: launchAtLogin) { _, new in setLaunchAtLogin(new) }
                }
            }

            SectionHeader(text: tr("Permissions", "Permisos"))
            Card {
                SettingRow(title: tr("Accessibility", "Accesibilidad"),
                           subtitle: tr("Required to paste into apps and for modifier-only Push to Talk", "Necesario para pegar en apps y para Mantener para hablar solo con modificadores")) {
                    AccessibilityStatus()
                }
            }

            SectionHeader(text: tr("Keyboard Shortcuts", "Atajos de teclado"))
            Card {
                SettingRow(title: tr("Toggle Recording", "Activar/desactivar grabación"), subtitle: tr("Starts and stops recordings", "Inicia y detiene la grabación")) {
                    ShortcutRecorder(combo: shortcuts.toggle) { combo in
                        if let combo { shortcuts.toggle = combo }
                    }
                }
                RowDivider()
                SettingRow(title: tr("Push to Talk", "Mantener para hablar"), subtitle: tr("Hold to record, release when done", "Mantené para grabar, soltá al terminar")) {
                    ShortcutRecorder(combo: shortcuts.pushToTalk,
                                     placeholder: tr("Off", "Apagado"),
                                     allowsClear: true) { combo in
                        shortcuts.pushToTalk = combo
                    }
                }
                RowDivider()
                SettingRow(title: tr("Change Mode", "Cambiar modo"), subtitle: tr("Cycles to the next mode", "Pasa al siguiente modo")) {
                    ShortcutRecorder(combo: shortcuts.cycleMode) { combo in
                        if let combo { shortcuts.cycleMode = combo }
                    }
                }
                RowDivider()
                SettingRow(title: tr("Cancel Recording", "Cancelar grabación"), subtitle: tr("Discards the active recording", "Descarta la grabación activa")) {
                    Shortcut(keys: ["esc"])
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nuviOutputPreferencesDidChange)) { _ in
            deliveryMode = SettingsStore.shared.dictationDeliveryMode
            translationTarget = SettingsStore.shared.translationTarget
        }
    }

    private var liveModeSubtitle: String {
        StatusMenuCopy(language: loc.language).liveDetail(
            for: engine,
            modelID: SettingsStore.shared.selectedModelID
        )
    }

    private func translationTargetName(_ target: TranslationTarget) -> String {
        StatusMenuCopy(language: loc.language).translationLabel(target)
    }

    private func setDeliveryMode(_ mode: DictationDeliveryMode) {
        if mode == .live, !LiveModeConfirmation.requestIfNeeded() {
            deliveryMode = SettingsStore.shared.dictationDeliveryMode
            return
        }
        SettingsStore.shared.dictationDeliveryMode = mode
    }

    private var launchAtLoginSubtitle: String {
        if let launchAtLoginError { return launchAtLoginError }

        switch SMAppService.mainApp.status {
        case .enabled:
            return tr("Enabled for the installed app", "Activado para la app instalada")
        case .requiresApproval:
            return tr("Needs approval in System Settings > Login Items", "Requiere aprobación en Ajustes del Sistema > Ítems de inicio")
        case .notRegistered:
            return tr("Disabled", "Desactivado")
        case .notFound:
            return tr("Install Nuvi.app in /Applications to enable", "Instalá Nuvi.app en /Aplicaciones para activarlo")
        @unknown default:
            return tr("Unknown login item status", "Estado de ítem de inicio desconocido")
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Nuvi: launch-at-login toggle failed: \(error)")
            launchAtLoginError = tr("Could not update login item", "No se pudo actualizar el ítem de inicio")
        }

        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
}

// MARK: - Appearance (ferrofluid live tuning)

private struct AppearancePanel: View {
    @ObservedObject private var store = FerrofluidSettingsStore.shared
    @ObservedObject private var loc = LocalizationStore.shared
    @StateObject private var mic = FerrofluidMicProbe()
    @State private var showPill = SettingsStore.shared.showPill
    @State private var showMenuBarStatus = SettingsStore.shared.showMenuBarStatus

    var body: some View {
        PanelScaffold(title: tr("Appearance", "Apariencia")) {
            SectionHeader(text: tr("Visibility", "Visibilidad"))
            Card {
                SettingRow(
                    title: tr("Show transcription pill", "Mostrar pill de transcripción"),
                    subtitle: tr(
                        "Display the floating listening and completion indicator",
                        "Muestra el indicador flotante de escucha y finalización"
                    )
                ) {
                    Toggle("", isOn: $showPill)
                        .labelsHidden()
                        .onChange(of: showPill) { _, value in
                            SettingsStore.shared.showPill = value
                        }
                }
                RowDivider()
                SettingRow(
                    title: tr("Show status in menu bar", "Mostrar estado en la barra de menú"),
                    subtitle: tr(
                        "Expand the isologo with Listening, LIVE, and completion states",
                        "Expande el isologo con estados de Escuchando, LIVE y finalización"
                    )
                ) {
                    Toggle("", isOn: $showMenuBarStatus)
                        .labelsHidden()
                        .onChange(of: showMenuBarStatus) { _, value in
                            SettingsStore.shared.showMenuBarStatus = value
                        }
                }
            }

            SectionHeader(text: tr("Ferrofluid Visualizer", "Visualizador de ferrofluido"))
            Card {
                HStack(alignment: .top, spacing: 28) {
                    preview
                    VStack(alignment: .leading, spacing: 14) {
                        presetRow
                        RowDivider()
                        brandPaletteRow
                        RowDivider()
                        slider(tr("Core size", "Tamaño del núcleo"), value: $store.settings.coreSize, range: 0.05...0.4)
                        slider(tr("Reach", "Alcance"), value: $store.settings.reach, range: 0.1...1.2)
                        slider(tr("Spikiness", "Puntas"), value: $store.settings.spikiness, range: 1...8)
                        slider(tr("Viscosity", "Viscosidad"), value: $store.settings.viscosity, range: 0.005...0.12)
                        slider(tr("Speed", "Velocidad"), value: $store.settings.speed, range: 0.1...3)
                        slider(tr("Fingers", "Dedos"), value: $store.settings.spikeCount, range: 3...14, step: 1)
                        Button(tr("Reset to default", "Restablecer valores")) { store.reset() }
                            .padding(.top, 2)
                    }
                }
                .padding(16)
            }
        }
    }

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Presets", "Presets"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(FerrofluidSettings.presets) { preset in
                    Button(preset.name) { store.settings = preset.settings }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private var brandPaletteRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(tr("Brand palette", "Paleta de marca"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                paletteSwatch(NuviPalette.softWhite, label: "#F4F5F7")
                paletteSwatch(NuviPalette.charcoal, label: "#0F1116")
                paletteSwatch(NuviPalette.lavender, label: "#B89BFF")
            }
        }
    }

    private func paletteSwatch(_ color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 13, height: 13)
                .overlay(Circle().strokeBorder(NuviPalette.softWhite.opacity(0.18), lineWidth: 0.5))
            Text(label).font(.system(size: 10, design: .monospaced))
        }
    }

    private var preview: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(NuviPalette.softWhite)
                FerrofluidView(level: mic.active ? mic.level : 0,
                               settings: store.settings,
                               simulate: !mic.active)
                    .clipShape(Circle())
            }
            .frame(width: 150, height: 150)
            .overlay(Circle().strokeBorder(NuviPalette.softWhite.opacity(0.12), lineWidth: 1))
            .shadow(color: NuviPalette.charcoal.opacity(0.4), radius: 8, y: 2)

            Button { mic.toggle() } label: {
                Label(mic.active ? tr("Stop mic", "Detener mic") : tr("Test with mic", "Probar con mic"),
                      systemImage: mic.active ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(NuviPalette.lavender)

            if mic.denied {
                Text(tr("Microphone access denied.\nEnable it in System Settings.",
                        "Acceso al micrófono denegado.\nActivalo en Ajustes del Sistema."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .onDisappear { mic.stop() }
    }

    private func slider(_ title: String, value: Binding<Float>,
                        range: ClosedRange<Float>, step: Float? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
        }
    }
}

// MARK: - Vocabulary

private struct VocabularyPanel: View {
    @ObservedObject private var store = VocabularyStore.shared
    @ObservedObject private var loc = LocalizationStore.shared

    var body: some View {
        PanelScaffold(title: tr("Vocabulary", "Vocabulario")) {
            Text(tr("Replace recognized words with the correct spelling — useful for names and jargon SpeechAnalyzer doesn't know.",
                    "Reemplazá palabras reconocidas por su escritura correcta — útil para nombres y jerga que el motor no conoce."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            SectionHeader(text: tr("Replacements", "Reemplazos"))
            Card {
                if store.rules.isEmpty {
                    Text(tr("No terms yet", "Aún no hay términos"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    ForEach(Array($store.rules.enumerated()), id: \.element.id) { index, $rule in
                        if index > 0 { RowDivider() }
                        HStack(spacing: 8) {
                            TextField(tr("Heard", "Escuchado"), text: $rule.from).textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField(tr("Replace with", "Reemplazar por"), text: $rule.to).textFieldStyle(.roundedBorder)
                            Button(role: .destructive) { store.delete(rule) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    }
                }
            }

            Button { store.add() } label: { Label(tr("Add term", "Agregar término"), systemImage: "plus") }
        }
    }
}

private struct AccessibilityStatus: View {
    @State private var trusted = TextInjector.isTrusted
    @ObservedObject private var loc = LocalizationStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(NuviPalette.lavender)
            Text(trusted ? tr("Granted", "Concedido") : tr("Not granted", "No concedido"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if !trusted {
                Button(tr("Grant…", "Conceder…")) {
                    TextInjector.ensureAccessibilityPermission()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                .controlSize(.small)
            }
        }
        .onAppear { trusted = TextInjector.isTrusted }
    }
}

// MARK: - Sound

private struct SoundPanel: View {
    @State private var enabled = SettingsStore.shared.soundEffects
    @State private var duckAudio = SettingsStore.shared.duckAudioDuringDictation
    @ObservedObject private var loc = LocalizationStore.shared

    var body: some View {
        PanelScaffold(title: tr("Sound", "Sonido")) {
            SectionHeader(text: tr("Sound Effects", "Efectos de sonido"))
            Card {
                SettingRow(title: tr("Play sounds", "Reproducir sonidos"),
                           subtitle: tr("Subtle cues when recording starts, stops, and text is inserted", "Señales sutiles al iniciar, detener e insertar texto")) {
                    Toggle("", isOn: $enabled).labelsHidden()
                        .onChange(of: enabled) { _, new in SettingsStore.shared.soundEffects = new }
                }
            }

            SectionHeader(text: tr("Audio Ducking", "Atenuación de audio"))
            Card {
                SettingRow(title: tr("Duck system audio", "Atenuar audio del sistema"),
                           subtitle: tr("Smoothly lowers system volume while dictating and restores it when finished", "Baja suavemente el volumen del sistema al dictar y lo restablece al terminar")) {
                    Toggle("", isOn: $duckAudio).labelsHidden()
                        .onChange(of: duckAudio) { _, new in SettingsStore.shared.duckAudioDuringDictation = new }
                }
            }

            SectionHeader(text: tr("Sound Mapping", "Asignación de sonidos"))
            Card {
                ForEach(Array(SoundEvent.allCases.enumerated()), id: \.element) { index, event in
                    if index > 0 { RowDivider() }
                    SoundPresetRow(event: event)
                }
            }
        }
    }
}

private struct SoundPresetRow: View {
    let event: SoundEvent
    @State private var preset: SoundPreset

    init(event: SoundEvent) {
        self.event = event
        _preset = State(initialValue: SettingsStore.shared.soundPreset(for: event))
    }

    var body: some View {
        SettingRow(title: event.title, subtitle: event.subtitle) {
            HStack(spacing: 8) {
                Picker("", selection: $preset) {
                    ForEach(SoundPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
                .onChange(of: preset) { _, new in
                    SettingsStore.shared.setSoundPreset(new, for: event)
                }

                Button {
                    NuviSound.preview(preset)
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                }
                .buttonStyle(.borderless)
                .help(tr("Preview sound", "Escuchar sonido"))
            }
        }
    }
}

// MARK: - Modes

private struct ModesPanel: View {
    @ObservedObject private var store = ModesStore.shared
    @ObservedObject private var loc = LocalizationStore.shared
    @StateObject private var appStore = RunningAppsStore()

    var body: some View {
        PanelScaffold(title: tr("Modes", "Modos")) {
            Text(tr("Context profiles applied after transcription. Cycle the active mode anywhere with ⌥⇧K, or bind a mode to an app so it activates automatically.",
                    "Perfiles de contexto aplicados después de transcribir. Cambiá el modo activo desde cualquier lado con ⌥⇧K, o asociá un modo a una app para que se active solo."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            SectionHeader(text: tr("Active mode", "Modo activo"))
            Card {
                SettingRow(title: tr("Active", "Activo")) {
                    Picker("", selection: $store.activeModeID) {
                        ForEach(store.modes) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }

            SectionHeader(text: tr("All modes", "Todos los modos"))
            ForEach($store.modes) { $mode in
                ModeEditor(mode: $mode,
                           apps: appStore.apps,
                           canDelete: store.modes.count > 1,
                           onDelete: { store.delete(mode) })
            }

            Button { store.add() } label: { Label(tr("Add mode", "Agregar modo"), systemImage: "plus") }
        }
        .onAppear { appStore.refresh() }
    }
}

private struct ModeEditor: View {
    @Binding var mode: Mode
    let apps: [AppInfo]
    let canDelete: Bool
    let onDelete: () -> Void
    @ObservedObject private var loc = LocalizationStore.shared

    var body: some View {
        Card {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField(tr("Mode name", "Nombre del modo"), text: $mode.name).textFieldStyle(.roundedBorder)
                    if canDelete {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)

                RowDivider()
                SettingRow(title: tr("Formatting", "Formato")) {
                    Picker("", selection: $mode.formatting) {
                        ForEach(TextFormatting.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 160)
                }

                RowDivider()
                SettingRow(title: tr("Use vocabulary", "Usar vocabulario")) {
                    Toggle("", isOn: $mode.useVocabulary).labelsHidden()
                }

                RowDivider()
                HStack(spacing: 8) {
                    TextField(tr("Prefix", "Prefijo"), text: $mode.prefix).textFieldStyle(.roundedBorder)
                    TextField(tr("Suffix", "Sufijo"), text: $mode.suffix).textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)

                RowDivider()
                SettingRow(title: tr("Auto-activate for app", "Auto-activar por app"),
                           subtitle: tr("Selected automatically when this app is frontmost", "Se selecciona automáticamente cuando esta app está al frente")) {
                    Picker("", selection: Binding(
                        get: { mode.autoActivateBundleID ?? "" },
                        set: { mode.autoActivateBundleID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text(tr("None", "Ninguna")).tag("")
                        ForEach(apps, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                    }
                    .labelsHidden().frame(width: 200)
                }
            }
        }
    }
}

private struct AppInfo: Hashable { let name: String; let bundleID: String }

@MainActor
private final class RunningAppsStore: ObservableObject {
    @Published private(set) var apps: [AppInfo] = []

    func refresh() {
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .map { AppInfo(name: $0.localizedName ?? $0.bundleIdentifier!, bundleID: $0.bundleIdentifier!) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - History

private struct HistoryPanel: View {
    @ObservedObject private var store = HistoryStore.shared
    @ObservedObject private var loc = LocalizationStore.shared
    @State private var query = ""

    private var filtered: [HistoryEntry] {
        guard !query.isEmpty else { return store.entries }
        return store.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        PanelScaffold(title: tr("History", "Historial")) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(tr("Search history", "Buscar en el historial"), text: $query).textFieldStyle(.plain)
                Spacer()
                Button(tr("Clear all", "Borrar todo"), role: .destructive) { store.clear() }
                    .disabled(store.entries.isEmpty)
            }
            .padding(10)
            .background(NuviTheme.card, in: RoundedRectangle(cornerRadius: 10))

            if filtered.isEmpty {
                ContentUnavailableView(tr("No transcriptions yet", "Aún no hay transcripciones"), systemImage: "clock")
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                VStack(spacing: 8) {
                    ForEach(filtered) { entry in entryRow(entry) }
                }
            }
        }
    }

    private func entryRow(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.text).font(.system(size: 13)).lineLimit(3)
            HStack {
                Text(entry.date, format: .relative(presentation: .named))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { copy(entry.text) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                Button(role: .destructive) { store.delete(entry) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(NuviTheme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(NuviTheme.cardStroke, lineWidth: 1))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Placeholder

private struct ComingSoonPanel: View {
    let title: String
    var body: some View {
        PanelScaffold(title: title) {
            ContentUnavailableView(tr("Coming soon", "Próximamente"),
                                   systemImage: "hammer",
                                   description: Text(tr("\(title) isn't built yet — it's on the roadmap.",
                                                        "\(title) todavía no está listo — está en la hoja de ruta.")))
                .frame(maxWidth: .infinity, minHeight: 300)
        }
    }
}
