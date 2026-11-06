import Combine
import Foundation
import NaturalLanguage
import Translation

/// Bridges the application use case to Apple's view-scoped TranslationSession.
@MainActor
final class TranslationCoordinator: ObservableObject, TextTranslating {
    typealias TimeoutScheduler = (UInt64, @escaping @MainActor @Sendable () -> Void) -> () -> Void
    @Published private(set) var configuration: TranslationSession.Configuration?

    private struct PendingRequest {
        let id: UUID
        let text: String
        let sourceLanguage: Locale.Language?
        let targetLanguage: Locale.Language
        let continuation: CheckedContinuation<String, Error>
    }

    private var pending: PendingRequest?
    private var lastConfiguration: TranslationSession.Configuration?
    private var performingID: UUID?
    private var deadlineGeneration = UUID()
    private var cancelDeadline: (() -> Void)?
    private var cancelOperation: (() -> Void)?
    private let translationTimeout: UInt64
    private let preparationTimeout: UInt64
    private let scheduleTimeout: TimeoutScheduler

    init(translationTimeout: UInt64 = 5_000_000_000,
         preparationTimeout: UInt64 = 60_000_000_000,
         scheduleTimeout: @escaping TimeoutScheduler = { duration, action in
             let timer = Task { @MainActor in
                 do { try await Task.sleep(nanoseconds: duration) }
                 catch { return }
                 guard !Task.isCancelled else { return }
                 action()
             }
             return { timer.cancel() }
         }) {
        self.translationTimeout = translationTimeout
        self.preparationTimeout = preparationTimeout
        self.scheduleTimeout = scheduleTimeout
    }

    func translate(_ text: String, to target: TranslationTarget) async throws -> String {
        guard let targetLanguage = target.language else { return text }
        guard Self.requiresTranslation(text, target: target) else { return text }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                begin(PendingRequest(id: id, text: text,
                                     sourceLanguage: Self.detectedSourceLanguage(text),
                                     targetLanguage: targetLanguage, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    nonisolated static func detectedSourceLanguage(_ text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) }
    }

    /// Translation rejects same-language pairs.
    nonisolated static func requiresTranslation(_ text: String, target: TranslationTarget) -> Bool {
        guard let targetCode = target.language?.languageCode?.identifier else { return false }
        guard let sourceCode = detectedSourceLanguage(text)?.languageCode?.identifier else { return true }
        return sourceCode != targetCode
    }

    func perform(using session: TranslationSession) async {
        guard !Task.isCancelled, let request = pending,
              session.sourceLanguage == request.sourceLanguage,
              session.targetLanguage == request.targetLanguage else { return }
        await perform(prepare: { try await session.prepareTranslation() },
                      translate: { try await session.translate($0).targetText },
                      cancel: { session.cancel() })
    }

    /// Injectable operations exercise deadlines and cancellation without language downloads.
    func perform(prepare: @escaping () async throws -> Void,
                 translate: @escaping (String) async throws -> String,
                 cancel: @escaping () -> Void) async {
        guard !Task.isCancelled, let request = pending, performingID != request.id else { return }
        performingID = request.id
        cancelOperation = cancel
        await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                if Self.shouldPrepareTranslation(sourceLanguage: request.sourceLanguage) {
                    try await prepare()
                    guard pending?.id == request.id else { return }
                    armDeadline(id: request.id, duration: translationTimeout)
                }
                let translated = try await translate(request.text)
                finish(id: request.id, result: .success(translated))
            } catch is CancellationError {
                finish(id: request.id, result: .failure(CancellationError()))
            } catch {
                finish(id: request.id, result: .failure(NuviError.translationFailed(error.localizedDescription)))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: request.id) }
        }
    }

    nonisolated static func shouldPrepareTranslation(sourceLanguage: Locale.Language?) -> Bool {
        sourceLanguage != nil
    }

    private func begin(_ request: PendingRequest) {
        if let pending { finish(id: pending.id, result: .failure(CancellationError())) }
        pending = request
        if var previous = lastConfiguration,
           previous.source == request.sourceLanguage, previous.target == request.targetLanguage {
            previous.invalidate()
            lastConfiguration = previous
        } else {
            lastConfiguration = TranslationSession.Configuration(source: request.sourceLanguage,
                                                                target: request.targetLanguage)
        }
        configuration = lastConfiguration
        // Budget user interaction and asset preparation separately. With an
        // unidentified source, the SDK cannot preflight an empty batch; retain
        // automatic translation under this longer combined-operation deadline.
        armDeadline(id: request.id, duration: preparationTimeout)
    }

    private func armDeadline(id: UUID, duration: UInt64) {
        cancelDeadline?()
        deadlineGeneration = UUID()
        let token = deadlineGeneration
        cancelDeadline = scheduleTimeout(duration) { [weak self] in
            guard self?.deadlineGeneration == token else { return }
            self?.finish(id: id, result: .failure(NuviError.translationFailed("Translation request timed out")))
        }
    }

    private func cancel(id: UUID) {
        finish(id: id, result: .failure(CancellationError()))
    }

    private func finish(id: UUID, result: Result<String, Error>) {
        guard let request = pending, request.id == id else { return }
        pending = nil
        performingID = nil
        let cancel = cancelOperation
        cancelOperation = nil
        deadlineGeneration = UUID()
        cancelDeadline?()
        cancelDeadline = nil
        configuration = nil
        if case .failure = result { cancel?() }
        request.continuation.resume(with: result)
    }
}
