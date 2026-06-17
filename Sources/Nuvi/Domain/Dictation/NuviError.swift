import Foundation

/// Single catalog of user-facing failures, each with a stable code.
///
/// The point is to make every failure traceable: no more silent dead-ends. A code
/// shows in the pill ("…(NUVI-T04)") and is logged as `Nuvi/error [NUVI-T04]: …`,
/// so a user can report exactly what failed and we can grep for it.
///
/// Code ranges:
///   A = Audio capture     T = Transcription     O = Output / injection     X = Unexpected
public struct NuviError: Error, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    /// One-liner for the pill: human message with the code appended for support.
    public var display: String { "\(message) (\(code))" }
}

public extension NuviError {
    // MARK: Audio (A)
    static let micPermissionDenied = NuviError("NUVI-A01", "Microphone access denied")
    static let micInUse            = NuviError("NUVI-A02", "Microphone is being used by another app")
    static func micUnavailable(_ reason: String) -> NuviError { NuviError("NUVI-A03", reason) }
    static let captureFailed       = NuviError("NUVI-A04", "Could not start microphone capture")
    static let noAudioReceived     = NuviError("NUVI-A05", "No audio reached Nuvi from the microphone")

    // MARK: Transcription (T)
    static func unsupportedLocale(_ id: String) -> NuviError { NuviError("NUVI-T01", "Language not supported: \(id)") }
    static func engineUnavailable(_ reason: String) -> NuviError { NuviError("NUVI-T02", reason) }
    static let assetUnavailable    = NuviError("NUVI-T03", "Speech model is not installed yet")
    static let speechAuthDenied    = NuviError("NUVI-T04", "Speech recognition is not authorized")
    static let noSpeechDetected    = NuviError("NUVI-T05", "No speech detected")
    static func engineFailed(_ reason: String) -> NuviError { NuviError("NUVI-T06", reason) }

    // MARK: Output (O)
    static func clipboardFallback(_ reason: String) -> NuviError { NuviError("NUVI-O01", reason) }

    // MARK: Unexpected (X)
    static func unexpected(_ reason: String) -> NuviError { NuviError("NUVI-X01", reason) }
}
