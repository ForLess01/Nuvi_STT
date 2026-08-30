import Foundation
import Combine
#if canImport(WhisperKit)
import WhisperKit
#endif
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Which transcription backend a catalog model belongs to. The two families
/// download in incompatible ways: WhisperKit pulls a `.zip` from a direct URL,
/// while Parakeet models are fetched and managed internally by FluidAudio.
public enum ModelEngine: String, Codable, Equatable {
    case whisperKit
    case parakeet
}

public struct AppModel: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    /// English description.
    public var desc: String
    /// Spanish description; falls back to `desc` when absent.
    public var descEs: String?
    public var engine: ModelEngine
    public var accuracy: Double
    public var speed: Double
    public var sizeBytes: Int64
    public var ramBytes: Int64
    public var icon: String
    /// Direct download URL. Present for WhisperKit models; `nil` for Parakeet,
    /// where FluidAudio owns the download.
    public var downloadUrl: String?
    /// FluidAudio model version ("v2" | "v3"). Only set for Parakeet models.
    public var parakeetVersion: String?

    /// Description in the requested language; English when no Spanish is set.
    public func localizedDesc(spanish: Bool) -> String {
        spanish ? (descEs ?? desc) : desc
    }

    // Backwards-compatible default so older JSON without an `engine` key still
    // decodes as a WhisperKit model.
    enum CodingKeys: String, CodingKey {
        case id, name, desc, descEs, engine, accuracy, speed, sizeBytes, ramBytes, icon, downloadUrl, parakeetVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        desc = try c.decode(String.self, forKey: .desc)
        descEs = try c.decodeIfPresent(String.self, forKey: .descEs)
        engine = try c.decodeIfPresent(ModelEngine.self, forKey: .engine) ?? .whisperKit
        accuracy = try c.decode(Double.self, forKey: .accuracy)
        speed = try c.decode(Double.self, forKey: .speed)
        sizeBytes = try c.decode(Int64.self, forKey: .sizeBytes)
        ramBytes = try c.decode(Int64.self, forKey: .ramBytes)
        icon = try c.decode(String.self, forKey: .icon)
        downloadUrl = try c.decodeIfPresent(String.self, forKey: .downloadUrl)
        parakeetVersion = try c.decodeIfPresent(String.self, forKey: .parakeetVersion)
    }

    public init(id: String, name: String, desc: String, descEs: String? = nil, engine: ModelEngine,
                accuracy: Double, speed: Double, sizeBytes: Int64, ramBytes: Int64,
                icon: String, downloadUrl: String? = nil, parakeetVersion: String? = nil) {
        self.id = id
        self.name = name
        self.desc = desc
        self.descEs = descEs
        self.engine = engine
        self.accuracy = accuracy
        self.speed = speed
        self.sizeBytes = sizeBytes
        self.ramBytes = ramBytes
        self.icon = icon
        self.downloadUrl = downloadUrl
        self.parakeetVersion = parakeetVersion
    }
}

public final class ModelDownloadService: NSObject, ObservableObject {
    /// Determinate download progress (0...1) for WhisperKit models.
    @Published public var downloadProgress: [String: Double] = [:]
    /// Parakeet models currently downloading. FluidAudio exposes no progress, so
    /// these are shown as indeterminate.
    @Published public var indeterminateDownloads: Set<String> = []
    @Published public var downloadedModels: Set<String> = []
    /// Last user-facing error from a download/unzip failure, or nil.
    @Published public var lastError: String?

    public var catalog: [AppModel] = []
    /// In-flight download tasks, keyed by model id (both engines).
    private final class DownloadAttempt {
        let token: UUID
        var task: Task<Void, Never>?

        init(token: UUID) {
            self.token = token
        }
    }

    /// Sendable bridge for provider progress callbacks. The callback itself
    /// may run off-main, while all ObservableObject state is updated on main.
    private final class DownloadProgressReporter: @unchecked Sendable {
        weak var service: ModelDownloadService?
        let modelId: String
        let token: UUID

        init(service: ModelDownloadService, modelId: String, token: UUID) {
            self.service = service
            self.modelId = modelId
            self.token = token
        }

        func report(_ fraction: Double) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let service = self.service else { return }
                service.updateProgress(modelId: self.modelId, token: self.token, fraction: fraction)
            }
        }
    }

    /// A download operation receives only the model identity and a progress
    /// callback. Keeping the seam at this boundary lets tests suspend and
    /// release a download without touching WhisperKit's network stack.
    internal typealias WhisperDownloadOperation = (
        _ modelId: String,
        _ progress: (Double) -> Void
    ) async throws -> Void
    internal typealias ParakeetDownloadOperation = (_ version: String) async throws -> Void

    private var downloadTasks: [String: DownloadAttempt] = [:]
    private let whisperDownloadOperation: WhisperDownloadOperation?
    private let parakeetDownloadOperation: ParakeetDownloadOperation?

    public static let shared = ModelDownloadService()

    private override init() {
        whisperDownloadOperation = nil
        parakeetDownloadOperation = nil
        super.init()
        loadCatalog()
        refreshDownloadedModels()
    }

    /// Test-only initializer. Production uses the shared instance above so
    /// the real WhisperKit and FluidAudio operations remain the default.
    internal init(
        testingCatalog: [AppModel],
        whisperDownloadOperation: WhisperDownloadOperation? = nil,
        parakeetDownloadOperation: ParakeetDownloadOperation? = nil
    ) {
        self.whisperDownloadOperation = whisperDownloadOperation
        self.parakeetDownloadOperation = parakeetDownloadOperation
        super.init()
        catalog = testingCatalog
    }
    
    public func loadCatalog() {
        guard let url = Self.catalogURL() else {
            NSLog("Nuvi: ModelsCatalog.json not found in any known location")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            self.catalog = try JSONDecoder().decode([AppModel].self, from: data)
        } catch {
            NSLog("Nuvi: Failed to load models catalog: \(error.localizedDescription)")
        }
    }

    /// Resolves the bundled catalog robustly.
    ///
    /// SPM's generated `Bundle.module` accessor only looks at
    /// `Bundle.main.bundleURL/Nuvi_Nuvi.bundle` and a hardcoded `.build/...`
    /// path — neither matches where the packaged `.app` actually stores the
    /// resource bundle (`Contents/Resources/Nuvi_Nuvi.bundle`). So we search the
    /// real locations first and only fall back to `Bundle.module` (which can
    /// `fatalError`) when nothing else worked — e.g. under `swift test`.
    private static func catalogURL() -> URL? {
        let name = "ModelsCatalog"
        let ext = "json"

        // 1. Loose copy directly in the app's Resources (most robust).
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        // 2. Inside the SPM resource bundle copied into Contents/Resources.
        if let resources = Bundle.main.resourceURL {
            let nested = resources.appendingPathComponent("Nuvi_Nuvi.bundle")
            if let bundle = Bundle(url: nested),
               let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        // 3. SPM module bundle — works under `swift test` / `swift run`.
        if let url = Bundle.module.url(forResource: name, withExtension: ext) {
            return url
        }
        return nil
    }
    
    public func refreshDownloadedModels() {
        // WhisperKit stores models nested, e.g.
        // .../WhisperKit/models/argmaxinc/whisperkit-coreml/openai_whisper-tiny/config.json
        // so we recurse and treat the parent folder of any config.json as a
        // downloaded variant (its folder name is the model id).
        var downloaded = downloadedWhisperVariants()

        // Parakeet models: FluidAudio owns its cache, so we trust our persisted flag.
        downloaded.formUnion(SettingsStore.shared.downloadedParakeetModels)

        DispatchQueue.main.async {
            self.downloadedModels = downloaded
        }
    }

    private func downloadedWhisperVariants() -> Set<String> {
        var variants = Set<String>()
        guard let baseDir = try? modelDownloadBase(),
              let enumerator = FileManager.default.enumerator(
                at: baseDir, includingPropertiesForKeys: nil) else {
            return variants
        }
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "config.json" {
            variants.insert(fileURL.deletingLastPathComponent().lastPathComponent)
        }
        return variants
    }

    public func startDownload(modelId: String) {
        guard let model = catalog.first(where: { $0.id == modelId }) else { return }
        switch model.engine {
        case .whisperKit:
            startWhisperDownload(model)
        case .parakeet:
            startParakeetDownload(model)
        }
    }

    private func startWhisperDownload(_ model: AppModel) {
        let modelId = model.id
        guard downloadTasks[modelId] == nil else { return }
        let token = UUID()
        let attempt = DownloadAttempt(token: token)
        downloadTasks[modelId] = attempt

        DispatchQueue.main.async {
            guard self.isCurrentAttempt(modelId: modelId, token: token) else { return }
            self.downloadProgress[modelId] = 0.01 // Mark start
        }

        // Strong capture is fine: this is the shared singleton, which lives for
        // the whole app, so there is no meaningful retain cycle to break.
        let progressReporter = DownloadProgressReporter(service: self, modelId: modelId, token: token)
        let task = Task {
            do {
                try Task.checkCancellation()
                try await self.runWhisperDownload(modelId: modelId, progress: progressReporter.report)
                // A provider may ignore cancellation and return normally. The
                // token guard below prevents that stale attempt from completing
                // a restarted download.
                await MainActor.run {
                    self.completeDownload(modelId: modelId, token: token)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.cancelledDownload(modelId: modelId, token: token)
                }
            } catch {
                let wasCancelled = Task.isCancelled
                await MainActor.run {
                    if wasCancelled {
                        self.cancelledDownload(modelId: modelId, token: token)
                    } else {
                        self.failDownload(
                            modelId: modelId,
                            token: token,
                            message: "No se pudo descargar \(model.name): \(error.localizedDescription)"
                        )
                    }
                }
            }
        }
        attempt.task = task
    }

    private func startParakeetDownload(_ model: AppModel) {
        let modelId = model.id
        guard downloadTasks[modelId] == nil else { return }
        let token = UUID()
        let attempt = DownloadAttempt(token: token)
        downloadTasks[modelId] = attempt

        DispatchQueue.main.async {
            guard self.isCurrentAttempt(modelId: modelId, token: token) else { return }
            self.indeterminateDownloads.insert(modelId)
        }

        let task = Task {
            do {
                try Task.checkCancellation()
                try await self.runParakeetDownload(version: model.parakeetVersion == "v2" ? "v2" : "v3")
                await MainActor.run {
                    self.completeParakeetDownload(modelId: modelId, token: token)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.cancelledDownload(modelId: modelId, token: token)
                }
            } catch {
                let wasCancelled = Task.isCancelled
                await MainActor.run {
                    if wasCancelled {
                        self.cancelledDownload(modelId: modelId, token: token)
                    } else {
                        self.failDownload(
                            modelId: modelId,
                            token: token,
                            message: "No se pudo descargar \(model.name): \(error.localizedDescription)"
                        )
                    }
                }
            }
        }
        attempt.task = task
    }

    private func runWhisperDownload(
        modelId: String,
        progress reportProgress: @escaping (Double) -> Void
    ) async throws {
        if let operation = whisperDownloadOperation {
            try await operation(modelId, reportProgress)
            return
        }
#if canImport(WhisperKit)
        let base = try ModelStorage.whisperKitBase()
        // WhisperKit resolves the variant against argmaxinc/whisperkit-coreml
        // and downloads the CoreML model folder (with real progress) — no
        // direct .zip URL involved.
        _ = try await WhisperKit.download(
            variant: modelId,
            downloadBase: base,
            progressCallback: { progress in reportProgress(progress.fractionCompleted) }
        )
#else
        throw DownloadServiceError.whisperKitUnavailable
#endif
    }

    private func runParakeetDownload(version: String) async throws {
        if let operation = parakeetDownloadOperation {
            try await operation(version)
            return
        }
#if canImport(FluidAudio)
        let version: AsrModelVersion = version == "v2" ? .v2 : .v3
        _ = try await AsrModels.downloadAndLoad(version: version)
#else
        throw DownloadServiceError.fluidAudioUnavailable
#endif
    }

    private enum DownloadServiceError: LocalizedError {
        case whisperKitUnavailable
        case fluidAudioUnavailable

        var errorDescription: String? {
            switch self {
            case .whisperKitUnavailable:
                return "WhisperKit no está disponible en este build."
            case .fluidAudioUnavailable:
                return "FluidAudio no está disponible en este build."
            }
        }
    }

    private func isCurrentAttempt(modelId: String, token: UUID) -> Bool {
        downloadTasks[modelId]?.token == token
    }

    /// Exposes only the current-attempt bit to deterministic unit tests; the
    /// UI continues to derive its state from the published collections.
    internal func isDownloadActive(modelId: String) -> Bool {
        downloadTasks[modelId] != nil
    }

    private func updateProgress(modelId: String, token: UUID, fraction: Double) {
        guard isCurrentAttempt(modelId: modelId, token: token) else { return }
        downloadProgress[modelId] = fraction
    }

    private func completeDownload(modelId: String, token: UUID) {
        guard finishDownload(modelId: modelId, token: token) else { return }
        refreshDownloadedModels()
    }

    private func completeParakeetDownload(modelId: String, token: UUID) {
        guard isCurrentAttempt(modelId: modelId, token: token) else { return }
        var set = SettingsStore.shared.downloadedParakeetModels
        set.insert(modelId)
        SettingsStore.shared.downloadedParakeetModels = set
        guard finishDownload(modelId: modelId, token: token) else { return }
        refreshDownloadedModels()
    }

    private func failDownload(modelId: String, token: UUID, message: String) {
        guard isCurrentAttempt(modelId: modelId, token: token) else { return }
        lastError = message
        finishDownload(modelId: modelId, token: token)
    }

    private func cancelledDownload(modelId: String, token: UUID) {
        // Cancellation is an expected user action, not a user-facing error.
        _ = finishDownload(modelId: modelId, token: token)
    }

    @discardableResult
    private func finishDownload(modelId: String, token: UUID) -> Bool {
        guard isCurrentAttempt(modelId: modelId, token: token) else { return false }
        downloadProgress.removeValue(forKey: modelId)
        indeterminateDownloads.remove(modelId)
        downloadTasks.removeValue(forKey: modelId)
        return true
    }

    public func cancelDownload(modelId: String) {
        guard let attempt = downloadTasks[modelId] else { return }
        attempt.task?.cancel()
        _ = finishDownload(modelId: modelId, token: attempt.token)
    }
    
    public func deleteModel(modelId: String) {
        guard let model = catalog.first(where: { $0.id == modelId }) else { return }
        switch model.engine {
        case .whisperKit:
            // The model folder is nested under the HF repo path, so locate it by
            // finding the config.json whose parent folder name is the model id.
            guard let baseDir = try? modelDownloadBase(),
                  let enumerator = FileManager.default.enumerator(
                    at: baseDir, includingPropertiesForKeys: nil) else { break }
            var toRemove: [URL] = []
            for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "config.json" {
                let dir = fileURL.deletingLastPathComponent()
                if dir.lastPathComponent == modelId {
                    toRemove.append(dir)
                }
            }
            for dir in toRemove {
                try? FileManager.default.removeItem(at: dir)
            }
        case .parakeet:
            // FluidAudio owns the on-disk cache (path undocumented), so we only
            // clear our "downloaded" flag. The model re-loads instantly from
            // FluidAudio's cache if it's still present.
            var set = SettingsStore.shared.downloadedParakeetModels
            set.remove(modelId)
            SettingsStore.shared.downloadedParakeetModels = set
        }
        refreshDownloadedModels()
    }

    /// WhisperKit download/load directory. Delegates to the shared `ModelStorage`
    /// so the engine and this service never look in different places.
    public func modelDownloadBase() throws -> URL {
        try ModelStorage.whisperKitBase()
    }
}
