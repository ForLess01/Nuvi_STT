import Foundation

/// What a transcription adapter emits while a session runs.
public enum TranscriptionEvent: Sendable {
    /// Live, in-progress text. Replaces the previous partial.
    case partial(String)
    /// Settled text for a segment. Append-worthy.
    case final(String)
}

/// Failures any adapter may surface through the port.
public enum TranscriptionError: Error, Sendable {
    case unsupportedLocale(String)
    case assetUnavailable
    case engineUnavailable(String)
    case underlying(String)
}
