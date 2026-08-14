import Combine
import Foundation
import NaturalLanguage
import Translation

/// Bridges the application use case to Apple's view-scoped TranslationSession.
/// A session with a nil source language performs source-language detection and
/// macOS handles any required on-device language download consent.
@MainActor
final class TranslationCoordinator: ObservableObject, TextTranslating {
    @Published private(set) var configuration: TranslationSession.Configuration?

    private struct PendingRequest {
        let id: UUID
        let text: String
        let sourceLanguage: Locale.Language?
        let continuation: CheckedContinuation<String, Error>
    }

    private var pending: PendingRequest?

    func translate(_ text: String, to target: TranslationTarget) async throws -> String {
        guard let targetLanguage = target.language else { return text }
        guard Self.requiresTranslation(text, target: target) else { return text }

        NSLog(
            "Nuvi/translation: requested target=\(targetLanguage.minimalIdentifier), characters=\(text.count)"
        )

        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                begin(
                    PendingRequest(
                        id: id,
                        text: text,
                        sourceLanguage: nil,
                        continuation: continuation
                    ),
                    targetLanguage: targetLanguage
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    /// Translation rejects same-language pairs. Detecting that case locally
    /// also keeps an already-English or already-Portuguese dictation instant.
    nonisolated static func requiresTranslation(
        _ text: String,
        target: TranslationTarget
    ) -> Bool {
        guard let targetCode = target.language?.languageCode?.identifier else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let sourceCode = recognizer.dominantLanguage?.rawValue else { return true }
        return sourceCode != targetCode
    }

    func perform(using session: TranslationSession) async {
        guard let request = pending else { return }
        do {
            // With automatic source detection, prepareTranslation() has no
            // source strings to inspect. Translation.framework then preflights
            // an empty batch and fails with TranslationErrorDomain Code 21.
            // Calling translate(_:) directly gives language identification the
            // actual text and still lets the framework request missing assets.
            if Self.shouldPrepareTranslation(sourceLanguage: request.sourceLanguage) {
                try await session.prepareTranslation()
            }
            let response = try await session.translate(request.text)
            NSLog("Nuvi/translation: completed characters=\(response.targetText.count)")
            finish(id: request.id, result: .success(response.targetText))
        } catch is CancellationError {
            finish(id: request.id, result: .failure(CancellationError()))
        } catch {
            NSLog("Nuvi/translation: failed error=\(error.localizedDescription)")
            finish(
                id: request.id,
                result: .failure(NuviError.translationFailed(error.localizedDescription))
            )
        }
    }

    nonisolated static func shouldPrepareTranslation(
        sourceLanguage: Locale.Language?
    ) -> Bool {
        sourceLanguage != nil
    }

    private func begin(_ request: PendingRequest, targetLanguage: Locale.Language) {
        if let pending {
            pending.continuation.resume(throwing: CancellationError())
        }
        pending = request

        if var current = configuration,
           current.source == nil,
           current.target == targetLanguage {
            current.invalidate()
            configuration = current
        } else {
            configuration = TranslationSession.Configuration(source: nil, target: targetLanguage)
        }
    }

    private func cancel(id: UUID) {
        guard pending?.id == id else { return }
        finish(id: id, result: .failure(CancellationError()))
    }

    private func finish(id: UUID, result: Result<String, Error>) {
        guard let request = pending, request.id == id else { return }
        pending = nil
        configuration = nil
        request.continuation.resume(with: result)
    }
}
