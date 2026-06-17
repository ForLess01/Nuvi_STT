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
    case notice(String)
    case error(String)
}
