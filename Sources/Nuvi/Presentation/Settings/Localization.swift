import Foundation
import Combine

/// UI language for the Settings window. Independent from the transcription
/// locale — this controls the chrome, not what gets transcribed.
public enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case spanish = "es"

    public var label: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Español"
        }
    }
}

/// Observable, persisted current UI language. Views observe this so a change
/// re-renders the whole Settings window live, with no relaunch.
public final class LocalizationStore: ObservableObject {
    public static let shared = LocalizationStore()

    @Published public var language: AppLanguage {
        didSet { SettingsStore.shared.interfaceLanguage = language.rawValue }
    }

    public init() {
        let stored = SettingsStore.shared.interfaceLanguage
        language = AppLanguage(rawValue: stored) ?? LocalizationStore.systemDefault()
    }

    private static func systemDefault() -> AppLanguage {
        let code = Locale.preferredLanguages.first?.prefix(2).lowercased() ?? "en"
        return code == "es" ? .spanish : .english
    }
}

/// Picks the string for the current UI language: English first, Spanish second.
/// Kept deliberately simple (no key tables) so each call site reads naturally
/// and stays self-documenting.
func tr(_ en: String, _ es: String) -> String {
    LocalizationStore.shared.language == .spanish ? es : en
}
