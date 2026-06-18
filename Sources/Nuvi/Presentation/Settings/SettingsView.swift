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
        switch self {
        case .home: return .orange
        case .configuration: return .gray
        case .appearance: return .pink
        case .vocabulary: return .blue
        case .history: return .indigo
        case .modes: return .cyan
        case .sound: return .green
        case .models: return .teal
        }
    }
}

struct SettingsView: View {
    @State private var selection: SettingsSection = .configuration

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                HStack(spacing: 10) {
                    IconTile(symbol: section.icon, color: section.tint)
                    Text(section.rawValue).font(.system(size: 13))
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
    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        return "v\(v)"
    }

    var body: some View {
        PanelScaffold(title: "Home") {
            // Landing hero
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Nuvi")
                        .font(.system(size: 34, weight: .bold))
                    Text(appVersion)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(6)
                        .foregroundStyle(.secondary)
                }
                Text("Hands-free dictation, anywhere. Press ⌥ Space to start — the pill appears top-left and the ferrofluid reacts to your voice.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)

            SectionHeader(text: "Shortcuts")
            Card {
                SettingRow(title: "Toggle dictation") { Shortcut(keys: ["⌥", "Space"]) }
                RowDivider()
                SettingRow(title: "Cancel") { Shortcut(keys: ["esc"]) }
            }

            SectionHeader(text: "Connect")
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
    @ObservedObject private var shortcuts = ShortcutsStore.shared

    private let locales: [(String, String)] = [
        ("es-ES", "Spanish (Spain)"),
        ("es-419", "Spanish (Latin America)"),
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("pt-BR", "Portuguese (Brazil)"),
        ("fr-FR", "French"),
        ("de-DE", "German"),
        ("it-IT", "Italian")
    ]

    var body: some View {
        PanelScaffold(title: "Configuration") {
            SectionHeader(text: "Transcription")
            Card {
                SettingRow(title: "Language") {
                    Picker("", selection: $locale) {
                        ForEach(locales, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .onChange(of: locale) { _, new in SettingsStore.shared.localeIdentifier = new }
                }
                RowDivider()
                SettingRow(title: "Engine",
                           subtitle: "Engine change applies on next launch") {
                    Picker("", selection: $engine) {
                        ForEach(EnginePreference.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .onChange(of: engine) { _, new in SettingsStore.shared.enginePreference = new }
                }
                RowDivider()
                SettingRow(title: "Microphone",
                           subtitle: "Automatic preserves Bluetooth playback; explicit selection uses that device") {
                    Picker("", selection: $inputDeviceUID) {
                        Text("Automatic (built-in)").tag("")
                        Text("System default").tag("default")
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

            SectionHeader(text: "Behavior")
            Card {
                SettingRow(title: "Restore clipboard after pasting") {
                    Toggle("", isOn: $restoreClipboard).labelsHidden()
                        .onChange(of: restoreClipboard) { _, new in SettingsStore.shared.restoreClipboard = new }
                }
                RowDivider()
                SettingRow(title: "Save dictation history",
                           subtitle: "Off keeps transcribed text off disk and clears existing history") {
                    Toggle("", isOn: $saveHistory).labelsHidden()
                        .onChange(of: saveHistory) { _, new in
                            SettingsStore.shared.saveHistory = new
                            if !new { HistoryStore.shared.clear() }
                        }
                }
                RowDivider()
                SettingRow(title: "Launch at login",
                           subtitle: launchAtLoginSubtitle) {
                    Toggle("", isOn: $launchAtLogin).labelsHidden()
                        .onChange(of: launchAtLogin) { _, new in setLaunchAtLogin(new) }
                }
            }

            SectionHeader(text: "Permissions")
            Card {
                SettingRow(title: "Accessibility",
                           subtitle: "Required to paste into apps and for modifier-only Push to Talk") {
                    AccessibilityStatus()
                }
            }

            SectionHeader(text: "Keyboard Shortcuts")
            Card {
                SettingRow(title: "Toggle Recording", subtitle: "Starts and stops recordings") {
                    ShortcutRecorder(combo: shortcuts.toggle) { combo in
                        if let combo { shortcuts.toggle = combo }
                    }
                }
                RowDivider()
                SettingRow(title: "Push to Talk", subtitle: "Hold to record, release when done") {
                    ShortcutRecorder(combo: shortcuts.pushToTalk,
                                     placeholder: "Off",
                                     allowsClear: true) { combo in
                        shortcuts.pushToTalk = combo
                    }
                }
                RowDivider()
                SettingRow(title: "Change Mode", subtitle: "Cycles to the next mode") {
                    ShortcutRecorder(combo: shortcuts.cycleMode) { combo in
                        if let combo { shortcuts.cycleMode = combo }
                    }
                }
                RowDivider()
                SettingRow(title: "Cancel Recording", subtitle: "Discards the active recording") {
                    Shortcut(keys: ["esc"])
                }
            }
        }
    }

    private var launchAtLoginSubtitle: String {
        if let launchAtLoginError { return launchAtLoginError }

        switch SMAppService.mainApp.status {
        case .enabled:
            return "Enabled for the installed app"
        case .requiresApproval:
            return "Needs approval in System Settings > Login Items"
        case .notRegistered:
            return "Disabled"
        case .notFound:
            return "Install Nuvi.app in /Applications to enable"
        @unknown default:
            return "Unknown login item status"
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Nuvi: launch-at-login toggle failed: \(error)")
            launchAtLoginError = "Could not update login item"
        }

        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
}

// MARK: - Appearance (ferrofluid live tuning)

private struct AppearancePanel: View {
    @ObservedObject private var store = FerrofluidSettingsStore.shared
    @StateObject private var mic = FerrofluidMicProbe()

    var body: some View {
        PanelScaffold(title: "Appearance") {
            SectionHeader(text: "Ferrofluid Visualizer")
            Card {
                HStack(alignment: .top, spacing: 28) {
                    preview
                    VStack(alignment: .leading, spacing: 14) {
                        presetRow
                        RowDivider()
                        ColorPicker("Fluid color", selection: colorBinding(\.fluidColor), supportsOpacity: false)
                            .font(.system(size: 12))
                        ColorPicker("Background", selection: colorBinding(\.backgroundColor), supportsOpacity: false)
                            .font(.system(size: 12))
                        RowDivider()
                        slider("Core size", value: $store.settings.coreSize, range: 0.05...0.4)
                        slider("Reach", value: $store.settings.reach, range: 0.1...1.2)
                        slider("Spikiness", value: $store.settings.spikiness, range: 1...8)
                        slider("Viscosity", value: $store.settings.viscosity, range: 0.005...0.12)
                        slider("Speed", value: $store.settings.speed, range: 0.1...3)
                        slider("Fingers", value: $store.settings.spikeCount, range: 3...14, step: 1)
                        Button("Reset to default") { store.reset() }
                            .padding(.top, 2)
                    }
                }
                .padding(16)
            }
        }
    }

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets")
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

    /// Bridges a stored `RGBColor` to SwiftUI's `Color` for the ColorPicker,
    /// resolving the picked color in sRGB so it matches the shader uniforms.
    private func colorBinding(_ keyPath: WritableKeyPath<FerrofluidSettings, RGBColor>) -> Binding<Color> {
        Binding(
            get: {
                let c = store.settings[keyPath: keyPath]
                return Color(.sRGB, red: Double(c.r), green: Double(c.g), blue: Double(c.b))
            },
            set: { newValue in
                let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? .black
                store.settings[keyPath: keyPath] = RGBColor(
                    Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent))
            }
        )
    }

    private var preview: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.white)
                FerrofluidView(level: mic.active ? mic.level : 0,
                               settings: store.settings,
                               simulate: !mic.active)
                    .clipShape(Circle())
            }
            .frame(width: 150, height: 150)
            .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)

            Button { mic.toggle() } label: {
                Label(mic.active ? "Stop mic" : "Test with mic",
                      systemImage: mic.active ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(mic.active ? .red : .accentColor)

            if mic.denied {
                Text("Microphone access denied.\nEnable it in System Settings.")
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

    var body: some View {
        PanelScaffold(title: "Vocabulary") {
            Text("Replace recognized words with the correct spelling — useful for names and jargon SpeechAnalyzer doesn't know.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            SectionHeader(text: "Replacements")
            Card {
                if store.rules.isEmpty {
                    Text("No terms yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    ForEach(Array($store.rules.enumerated()), id: \.element.id) { index, $rule in
                        if index > 0 { RowDivider() }
                        HStack(spacing: 8) {
                            TextField("Heard", text: $rule.from).textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("Replace with", text: $rule.to).textFieldStyle(.roundedBorder)
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

            Button { store.add() } label: { Label("Add term", systemImage: "plus") }
        }
    }
}

private struct AccessibilityStatus: View {
    @State private var trusted = TextInjector.isTrusted

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(trusted ? .green : .orange)
            Text(trusted ? "Granted" : "Not granted")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if !trusted {
                Button("Grant…") {
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

    var body: some View {
        PanelScaffold(title: "Sound") {
            SectionHeader(text: "Sound Effects")
            Card {
                SettingRow(title: "Play sounds",
                           subtitle: "Subtle cues when recording starts, stops, and text is inserted") {
                    Toggle("", isOn: $enabled).labelsHidden()
                        .onChange(of: enabled) { _, new in SettingsStore.shared.soundEffects = new }
                }
            }

            SectionHeader(text: "Sound Mapping")
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
                .help("Preview sound")
            }
        }
    }
}

// MARK: - Modes

private struct ModesPanel: View {
    @ObservedObject private var store = ModesStore.shared
    @StateObject private var appStore = RunningAppsStore()

    var body: some View {
        PanelScaffold(title: "Modes") {
            Text("Context profiles applied after transcription. Cycle the active mode anywhere with ⌥⇧K, or bind a mode to an app so it activates automatically.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            SectionHeader(text: "Active mode")
            Card {
                SettingRow(title: "Active") {
                    Picker("", selection: $store.activeModeID) {
                        ForEach(store.modes) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }

            SectionHeader(text: "All modes")
            ForEach($store.modes) { $mode in
                ModeEditor(mode: $mode,
                           apps: appStore.apps,
                           canDelete: store.modes.count > 1,
                           onDelete: { store.delete(mode) })
            }

            Button { store.add() } label: { Label("Add mode", systemImage: "plus") }
        }
        .onAppear { appStore.refresh() }
    }
}

private struct ModeEditor: View {
    @Binding var mode: Mode
    let apps: [AppInfo]
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        Card {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("Mode name", text: $mode.name).textFieldStyle(.roundedBorder)
                    if canDelete {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)

                RowDivider()
                SettingRow(title: "Formatting") {
                    Picker("", selection: $mode.formatting) {
                        ForEach(TextFormatting.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 160)
                }

                RowDivider()
                SettingRow(title: "Use vocabulary") {
                    Toggle("", isOn: $mode.useVocabulary).labelsHidden()
                }

                RowDivider()
                HStack(spacing: 8) {
                    TextField("Prefix", text: $mode.prefix).textFieldStyle(.roundedBorder)
                    TextField("Suffix", text: $mode.suffix).textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)

                RowDivider()
                SettingRow(title: "Auto-activate for app",
                           subtitle: "Selected automatically when this app is frontmost") {
                    Picker("", selection: Binding(
                        get: { mode.autoActivateBundleID ?? "" },
                        set: { mode.autoActivateBundleID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("None").tag("")
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
    @State private var query = ""

    private var filtered: [HistoryEntry] {
        guard !query.isEmpty else { return store.entries }
        return store.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        PanelScaffold(title: "History") {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history", text: $query).textFieldStyle(.plain)
                Spacer()
                Button("Clear all", role: .destructive) { store.clear() }
                    .disabled(store.entries.isEmpty)
            }
            .padding(10)
            .background(NuviTheme.card, in: RoundedRectangle(cornerRadius: 10))

            if filtered.isEmpty {
                ContentUnavailableView("No transcriptions yet", systemImage: "clock")
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
            ContentUnavailableView("Coming soon",
                                   systemImage: "hammer",
                                   description: Text("\(title) isn't built yet — it's on the roadmap."))
                .frame(maxWidth: .infinity, minHeight: 300)
        }
    }
}
