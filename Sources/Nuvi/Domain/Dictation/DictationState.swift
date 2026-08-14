import Foundation

/// High-level state of a dictation session.
///
/// This is the single source of truth that drives the pill window's visibility,
/// the status-bar icon, and the ferrofluid visualizer. It lives in the domain
/// on purpose: no UI, no framework imports.
public enum DictationState: Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case inserted
    case copied
    case notice(String)
    case error(String)
}

/// Controls when recognized text is delivered to the focused application.
public enum DictationDeliveryMode: String, CaseIterable, Equatable, Sendable {
    case standard
    case live

    public var label: String {
        switch self {
        case .standard: return "Standard"
        case .live: return "Live (Beta)"
        }
    }
}
