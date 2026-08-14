import Foundation

/// The language Nuvi delivers after transcription. `original` preserves the
/// recognized text; every other case asks Apple's Translation framework to
/// detect the source language and produce the selected regional output.
public enum TranslationTarget: String, CaseIterable, Sendable {
    case original
    case englishUS
    case englishUK
    case portugueseBrazil

    public var label: String {
        switch self {
        case .original: return "Original"
        case .englishUS: return "English (US)"
        case .englishUK: return "English (UK)"
        case .portugueseBrazil: return "Português (Brasil)"
        }
    }

    /// Apple's supported-language catalog represents US English and Brazilian
    /// Portuguese as the unqualified defaults, while UK English is regional.
    public var language: Locale.Language? {
        switch self {
        case .original: return nil
        case .englishUS: return Locale.Language(identifier: "en")
        case .englishUK: return Locale.Language(identifier: "en-GB")
        case .portugueseBrazil: return Locale.Language(identifier: "pt")
        }
    }
}
