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

@MainActor
public final class ModelDownloadService: NSObject, ObservableObject {
    /// Determinate download progress (0...1) for WhisperKit models.
    @Published public var downloadProgress: [String: Double] = [:]
    /// Parakeet models currently downloading. FluidAudio exposes no progress, so
    /// these are shown as indeterminate.
    @Published public var indeterminateDownloads: Set<String> = []
    /// Downloads paused by the user. The underlying SDK task is cancelled while
    /// its on-disk cache is retained so a later resume can continue the same
    /// operation.
    @Published public private(set) var pausedDownloads: Set<String> = []
    @Published public var downloadedModels: Set<String> = []
    /// Last user-facing error from a download/unzip failure, or nil.
    @Published public var lastError: String?

    @Published public private(set) var isRefreshingModels = false

    public var catalog: [AppModel] = []
    /// In-flight download tasks, keyed by model id (both engines).
    private final class DownloadAttempt {
        let token: UUID
        var task: Task<Void, Never>?
#if canImport(WhisperKit)
        var whisperTokenizer: (any WhisperTokenizer)?
#endif

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
    /// A resume is serialized behind the cancelled provider task. Keeping this
    /// set separate from `pausedDownloads` prevents repeated taps from queuing
    /// multiple operations against the same on-disk cache.
    private var pendingResumes: Set<String> = []
    private let whisperDownloadOperation: WhisperDownloadOperation?
    private let parakeetDownloadOperation: ParakeetDownloadOperation?
    private let modelDownloadBaseOverride: URL?
    private var endingDownloads: Set<String> = []
    private var queuedStarts: Set<String> = []
    private var deletionTasks: [String: Task<Void, Never>] = [:]
    private var readCopyTasks: [String: (token: UUID, task: Task<ModelReadSnapshot, Error>)] = [:]
    private final class WeakSnapshot {
        weak var value: ModelReadSnapshot?
        init(_ value: ModelReadSnapshot) { self.value = value }
    }
    private var readSnapshots: [String: WeakSnapshot] = [:]
    private var modelRevisions: [String: Int] = [:]
    /// Retained because SDK cancellation does not expose joinable child I/O.
    /// These roots are never re-used, published, scanned, or auto-deleted.
    private(set) var retainedSDKRoots: [URL] = []
#if canImport(WhisperKit)
    private var whisperTokenizers: [String: any WhisperTokenizer] = [:]
    internal var whisperAssetAcquisitionOverride: StagedDownloadOperation?
    internal var whisperTokenizerPreparationOverride: ((ModelVariant, URL, [URL]) async throws -> any WhisperTokenizer)?
#endif
    private var inventoryGeneration = 0
    private var inventoryTask: Task<Void, Never>?
    private let parakeetModelBaseOverride: URL?
    internal typealias StagedDownloadOperation = (AppModel, URL, (Double) -> Void) async throws -> URL
    private let snapshotCopyOperation: (@Sendable (URL, URL) throws -> Void)?
    private let stagedDownloadOperation: StagedDownloadOperation?
    private let deletionOperation: ((String) async throws -> Void)?
    private let inventoryOperation: (@Sendable () -> Set<String>)?

    public static let shared = ModelDownloadService()

    private override init() {
        whisperDownloadOperation = nil
        parakeetDownloadOperation = nil
        modelDownloadBaseOverride = nil
        inventoryOperation = nil
        parakeetModelBaseOverride = nil
        deletionOperation = nil
        stagedDownloadOperation = nil
        snapshotCopyOperation = nil
        super.init()
        loadCatalog()
        refreshDownloadedModels()
    }

    /// Test-only initializer. Production uses the shared instance above so
    /// the real WhisperKit and FluidAudio operations remain the default.
    internal init(
        testingCatalog: [AppModel],
        whisperDownloadOperation: WhisperDownloadOperation? = nil,
        parakeetDownloadOperation: ParakeetDownloadOperation? = nil,
        modelDownloadBase: URL? = nil,
        inventoryOperation: (@Sendable () -> Set<String>)? = nil,
        parakeetModelBase: URL? = nil,
        deletionOperation: ((String) async throws -> Void)? = nil,
        stagedDownloadOperation: StagedDownloadOperation? = nil,
        snapshotCopyOperation: (@Sendable (URL, URL) throws -> Void)? = nil
    ) {
        self.whisperDownloadOperation = whisperDownloadOperation
        self.parakeetDownloadOperation = parakeetDownloadOperation
        self.modelDownloadBaseOverride = modelDownloadBase ?? FileManager.default.temporaryDirectory.appendingPathComponent("nuvi-test-models-\(UUID().uuidString)")
        self.parakeetModelBaseOverride = parakeetModelBase ?? self.modelDownloadBaseOverride
        self.deletionOperation = deletionOperation
        self.stagedDownloadOperation = stagedDownloadOperation
        self.snapshotCopyOperation = snapshotCopyOperation
        self.inventoryOperation = inventoryOperation
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
        inventoryGeneration += 1
        let generation = inventoryGeneration
        inventoryTask?.cancel()
        isRefreshingModels = true
        let catalog = catalog
        let base = modelDownloadBaseOverride
        let parakeetBase = parakeetModelBaseOverride
        let operation = inventoryOperation
        inventoryTask = Task.detached(priority: .utility) { [weak self] in
            let downloaded: Set<String>
            if let operation { downloaded = operation() }
            else {
                let whisperBase = base ?? (try? ModelStorage.whisperKitBase(create: false))
                var available = Self.downloadedWhisperVariants(
                    base: whisperBase,
                    knownVariants: Set(catalog.filter { $0.engine == .whisperKit }.map(\.id)))
                for model in catalog where model.engine == .parakeet && !Task.isCancelled {
                    if Self.isCompleteParakeetModel(version: model.parakeetVersion ?? "v3", root: parakeetBase) {
                        available.insert(model.id)
                    }
                }
                downloaded = available
            }
            guard !Task.isCancelled else { return }
            await self?.publishInventory(downloaded, generation: generation)
        }
    }

    private func publishInventory(_ downloaded: Set<String>, generation: Int) {
        guard generation == inventoryGeneration else { return }
        // An active writer may have produced a temporarily complete-looking
        // directory. Only publish cache state once ownership is released.
        downloadedModels = downloaded.subtracting(downloadTasks.keys).subtracting(deletionTasks.keys)
        isRefreshingModels = false
        inventoryTask = nil
    }

    private func invalidateInventory() {
        inventoryGeneration += 1
        inventoryTask?.cancel()
        inventoryTask = nil
        isRefreshingModels = false
    }

    private nonisolated static func isCompleteParakeetModel(version: String, root: URL?) -> Bool {
        guard let directory = ModelStorage.parakeetDirectory(version: version, root: root),
              let required = ModelStorage.parakeetRequiredFiles(version: version),
              required.bundles.allSatisfy({ containsNonEmptyRegularFile(in: directory.appendingPathComponent($0)) }),
              let data = try? Data(contentsOf: directory.appendingPathComponent(required.vocabulary)),
              let vocabulary = try? JSONSerialization.jsonObject(with: data) else { return false }
        return (vocabulary as? [String: Any])?.isEmpty == false || (vocabulary as? [Any])?.isEmpty == false
    }

    private nonisolated static func downloadedWhisperVariants(base: URL?, knownVariants: Set<String>) -> Set<String> {
        var variants = Set<String>()
        guard let base, let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: nil) else { return variants }
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "config.json" {
            if Task.isCancelled { break }
            let modelDirectory = fileURL.deletingLastPathComponent()
            let variant = modelDirectory.lastPathComponent
            guard knownVariants.contains(variant), isCompleteWhisperModel(at: modelDirectory) else {
                continue
            }
            variants.insert(variant)
        }
        return variants
    }

    /// WhisperKit considers a model usable only when its metadata and all of
    /// its CoreML bundles are present. A config file can be written before the
    /// model bundles finish downloading, so it is not a completion marker by
    /// itself. Bundle names are intentionally not hardcoded here: the current
    /// WhisperKit layout contains three `.mlmodelc` bundles, while future
    /// releases may use `.mlpackage` bundles instead.
    private nonisolated static func isCompleteWhisperModel(at directory: URL) -> Bool {
        let configURL = directory.appendingPathComponent("config.json")
        guard hasNonEmptyRegularFile(at: configURL),
              let configData = try? Data(contentsOf: configURL),
              (try? JSONSerialization.jsonObject(with: configData)) != nil else {
            return false
        }

        let coreMLBundles = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.filter { url in
            let extensionName = url.pathExtension.lowercased()
            return extensionName == "mlmodelc" || extensionName == "mlpackage"
        } ?? []

        // WhisperKit's standard pipeline requires feature extraction, audio
        // encoding, and text decoding bundles. Requiring three non-empty
        // bundles rejects config-only and partially downloaded cache folders
        // without depending on brittle model filenames.
        guard coreMLBundles.count >= 3 else { return false }
        return coreMLBundles.allSatisfy { containsNonEmptyRegularFile(in: $0) }
    }

    private nonisolated static func hasNonEmptyRegularFile(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            return false
        }
        return (values.fileSize ?? 0) > 0
    }

    private nonisolated static func containsNonEmptyRegularFile(in directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            if hasNonEmptyRegularFile(at: fileURL) {
                return true
            }
        }
        return false
    }

    public func startDownload(modelId: String) {
        guard let model = catalog.first(where: { $0.id == modelId }) else { return }
        if endingDownloads.contains(modelId) || deletionTasks[modelId] != nil {
            queuedStarts.insert(modelId)
            downloadProgress[modelId] = 0.01
            return
        }
        invalidateInventory()
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
            guard self.isCurrentAttempt(modelId: modelId, token: token),
                  !self.pausedDownloads.contains(modelId),
                  !self.endingDownloads.contains(modelId) else { return }
            if self.downloadProgress[modelId] == nil {
                self.downloadProgress[modelId] = 0.01 // Mark start
            }
        }

        // Strong capture is fine: this is the shared singleton, which lives for
        // the whole app, so there is no meaningful retain cycle to break.
        let progressReporter = DownloadProgressReporter(service: self, modelId: modelId, token: token)
        let task = Task {
            do {
                try Task.checkCancellation()
                if let operation = self.whisperDownloadOperation {
                    try await operation(modelId, progressReporter.report)
                } else {
                    try await self.downloadAndPublish(model: model, token: token, progress: progressReporter.report)
                }
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
            guard self.isCurrentAttempt(modelId: modelId, token: token),
                  !self.pausedDownloads.contains(modelId),
                  !self.endingDownloads.contains(modelId) else { return }
            self.indeterminateDownloads.insert(modelId)
        }

        let task = Task {
            do {
                try Task.checkCancellation()
                if let operation = self.parakeetDownloadOperation {
                    try await operation(model.parakeetVersion == "v2" ? "v2" : "v3")
                } else {
                    try await self.downloadAndPublish(model: model, token: token, progress: { _ in })
                }
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

    private func canonicalDirectory(for model: AppModel) throws -> URL {
        switch model.engine {
        case .whisperKit:
            return ModelStorage.whisperModelDirectory(modelID: model.id, base: try modelDownloadBase())
        case .parakeet:
            guard let directory = ModelStorage.parakeetDirectory(version: model.parakeetVersion ?? "v3", root: parakeetModelBaseOverride) else {
                throw DownloadServiceError.fluidAudioUnavailable
            }
            return directory
        }
    }

    private nonisolated static func isComplete(_ model: AppModel, directory: URL) -> Bool {
        switch model.engine {
        case .whisperKit: return isCompleteWhisperModel(at: directory)
        case .parakeet:
            return isCompleteParakeetModel(version: model.parakeetVersion ?? "v3", root: directory.deletingLastPathComponent())
        }
    }

    private func downloadAndPublish(model: AppModel, token: UUID, progress: @escaping (Double) -> Void) async throws {
        let workspace = try ModelStorage.downloadWorkspace(whisperBase: modelDownloadBaseOverride)
        let providerRoot = workspace.appendingPathComponent("SDKAttempts/\(token.uuidString)")
        let publicationRoot = workspace.appendingPathComponent("Publications/\(token.uuidString)")
        let canonical = try canonicalDirectory(for: model)
        let tokenizerCache = workspace.appendingPathComponent("Tokenizers/\(model.id)")
        let tokenizerPublication = publicationRoot.appendingPathComponent("tokenizer-cache")
        let whisperBase = modelDownloadBaseOverride
        retainedSDKRoots.append(providerRoot)
        // Seed only a COPY. Reusing a cancelled generation's root or moving its
        // files would allow late file handles to mutate a new published model.
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: providerRoot, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: providerRoot.path)
            if Self.isComplete(model, directory: canonical) {
                let seed = model.engine == .whisperKit
                    ? ModelStorage.whisperModelDirectory(modelID: model.id, base: providerRoot)
                    : ModelStorage.parakeetDirectory(version: model.parakeetVersion ?? "v3", root: providerRoot)!
                try FileManager.default.createDirectory(at: seed.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: canonical, to: seed)
            }
#if canImport(WhisperKit)
            if model.engine == .whisperKit, let variant = Self.whisperVariant(for: model.id) {
                let relative = "models/" + ("openai/whisper-" + variant.description)
                let legacy = (try whisperBase ?? ModelStorage.whisperKitBase(create: false)).appendingPathComponent(relative)
                let source = FileManager.default.fileExists(atPath: tokenizerCache.appendingPathComponent("tokenizer.json").path) ? tokenizerCache : legacy
                if FileManager.default.fileExists(atPath: source.path) {
                    let target = providerRoot.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: source, to: target)
                }
            }
#endif
        }.value
        try Task.checkCancellation()
        let downloaded: URL
        if let stagedDownloadOperation {
            downloaded = try await stagedDownloadOperation(model, providerRoot, progress)
        } else {
            switch model.engine {
            case .whisperKit:
#if canImport(WhisperKit)
                let seed = ModelStorage.whisperModelDirectory(modelID: model.id, base: providerRoot)
                let hasSeed = await Task.detached(priority: .utility) { Self.isCompleteWhisperModel(at: seed) }.value
                if hasSeed { downloaded = seed }
                else if let operation = whisperAssetAcquisitionOverride { downloaded = try await operation(model, providerRoot, progress) }
                else {
                    downloaded = try await WhisperKit.download(variant: model.id, downloadBase: providerRoot,
                        progressCallback: { progress($0.fractionCompleted) })
                }
                // download:false does not disable tokenizer fallback. Acquire
                // here, using copied local assets first; any SDK writes remain
                // in this generation's root, never canonical/read snapshots.
                guard let variant = Self.whisperVariant(for: model.id) else { throw DownloadServiceError.invalidModel }
                let tokenizer: any WhisperTokenizer
                if let operation = whisperTokenizerPreparationOverride {
                    tokenizer = try await operation(variant, providerRoot, [downloaded])
                } else {
                    tokenizer = try await ModelUtilities.loadTokenizer(for: variant, tokenizerFolder: providerRoot,
                        additionalSearchPaths: [downloaded])
                }
                downloadTasks[model.id]?.whisperTokenizer = tokenizer
#else
                throw DownloadServiceError.whisperKitUnavailable
#endif
            case .parakeet:
#if canImport(FluidAudio)
                downloaded = ModelStorage.parakeetDirectory(version: model.parakeetVersion ?? "v3", root: providerRoot)!
                _ = try await AsrModels.downloadAndLoad(to: downloaded, version: model.parakeetVersion == "v2" ? .v2 : .v3)
#else
                throw DownloadServiceError.fluidAudioUnavailable
#endif
            }
        }
        try Task.checkCancellation()
        guard isCurrentAttempt(modelId: model.id, token: token), !pausedDownloads.contains(model.id), !endingDownloads.contains(model.id) else {
            throw CancellationError()
        }
        let snapshot = publicationRoot.appendingPathComponent(canonical.lastPathComponent)
        defer {
            // This is our private copy, not the SDK's unjoinable writable root.
            Task.detached(priority: .utility) {
                if FileManager.default.fileExists(atPath: publicationRoot.path) {
                    try? FileManager.default.removeItem(at: publicationRoot)
                }
            }
        }
        let keepExisting = try await Task.detached(priority: .utility) {
            let prefix = providerRoot.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard downloaded.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(prefix) else {
                throw DownloadServiceError.invalidModel
            }
            try FileManager.default.createDirectory(at: publicationRoot, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: downloaded, to: snapshot)
#if canImport(WhisperKit)
            if model.engine == .whisperKit, let variant = Self.whisperVariant(for: model.id) {
                let hub = providerRoot.appendingPathComponent("models/" + ("openai/whisper-" + variant.description))
                let source = FileManager.default.fileExists(atPath: hub.appendingPathComponent("tokenizer.json").path) ? hub : downloaded
                if FileManager.default.fileExists(atPath: source.appendingPathComponent("tokenizer.json").path) {
                    try FileManager.default.createDirectory(at: tokenizerPublication, withIntermediateDirectories: true)
                    for name in ["tokenizer.json", "tokenizer_config.json", "config.json", "special_tokens_map.json", "added_tokens.json"] {
                        let file = source.appendingPathComponent(name)
                        if FileManager.default.fileExists(atPath: file.path) {
                            try FileManager.default.copyItem(at: file, to: tokenizerPublication.appendingPathComponent(name))
                        }
                    }
                }
            }
#endif
            guard Self.isComplete(model, directory: snapshot) else { throw DownloadServiceError.invalidModel }
            return Self.isComplete(model, directory: canonical)
        }.value
        try Task.checkCancellation()
        guard isCurrentAttempt(modelId: model.id, token: token), !pausedDownloads.contains(model.id), !endingDownloads.contains(model.id) else {
            throw CancellationError()
        }
        // No await between the generation check and commit. Keep an existing
        // complete cache rather than overwriting it during a redundant download.
        if !keepExisting { try ModelStorage.publishSnapshot(snapshot, to: canonical) }
        if FileManager.default.fileExists(atPath: tokenizerPublication.path) {
            try ModelStorage.publishSnapshot(tokenizerPublication, to: tokenizerCache)
        }
#if canImport(WhisperKit)
        if let tokenizer = downloadTasks[model.id]?.whisperTokenizer { whisperTokenizers[model.id] = tokenizer }
#endif
    }

#if canImport(WhisperKit)
    private nonisolated static func whisperVariant(for modelID: String) -> ModelVariant? {
        let name = modelID.replacingOccurrences(of: "openai_whisper-", with: "")
            .replacingOccurrences(of: "_turbo", with: "")
        return ModelVariant.allCases.first { $0.description == name }
    }
#endif

    /// Automatic engine acquisition uses exactly the UI download coordinator.
    /// Readers receive an owned copy, so deleting canonical files cannot break
    /// an already-loaded CoreML pipeline or race its lazy file reads.
    func prepareModelSnapshot(modelId: String) async throws -> ModelReadSnapshot {
        guard let model = catalog.first(where: { $0.id == modelId }) else { throw DownloadServiceError.invalidModel }
        let revision = modelRevisions[modelId, default: 0]
        guard deletionTasks[modelId] == nil else { throw CancellationError() }
        if let cached = readSnapshots[modelId]?.value { return cached }
        let canonical = try canonicalDirectory(for: model)
        var ready = await Task.detached(priority: .utility) { Self.isComplete(model, directory: canonical) }.value
#if canImport(WhisperKit)
        if model.engine == .whisperKit && stagedDownloadOperation == nil && whisperTokenizers[modelId] == nil { ready = false }
#endif
        try Task.checkCancellation()
        guard modelRevisions[modelId, default: 0] == revision else { throw CancellationError() }
        if !ready {
            guard !pausedDownloads.contains(modelId) else { throw DownloadServiceError.pausedModel }
            startDownload(modelId: modelId)
            // At most one queued restart exists per model; wait for whichever
            // generation currently owns acquisition rather than bypassing it.
            while let task = downloadTasks[modelId]?.task {
                await task.value
                try Task.checkCancellation()
                guard !pausedDownloads.contains(modelId) else { throw DownloadServiceError.pausedModel }
                guard modelRevisions[modelId, default: 0] == revision else { throw CancellationError() }
                if endingDownloads.contains(modelId) { await Task.yield() }
            }
        }
        guard modelRevisions[modelId, default: 0] == revision, deletionTasks[modelId] == nil else { throw CancellationError() }
        if let cached = readSnapshots[modelId]?.value { return cached }
        let read: (token: UUID, task: Task<ModelReadSnapshot, Error>)
        if let existing = readCopyTasks[modelId] { read = existing }
        else {
            let root = try ModelStorage.downloadWorkspace(whisperBase: modelDownloadBaseOverride)
                .appendingPathComponent("Readers/\(UUID().uuidString)")
            let copy = snapshotCopyOperation
            let task = Task.detached(priority: .utility) {
                let directory = root.appendingPathComponent(canonical.lastPathComponent)
                let snapshot = ModelReadSnapshot(directory: directory, ownedRoot: root)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                if let copy { try copy(canonical, directory) }
                else { try FileManager.default.copyItem(at: canonical, to: directory) }
                guard Self.isComplete(model, directory: directory) else { throw DownloadServiceError.invalidModel }
                return snapshot
            }
            read = (UUID(), task)
            readCopyTasks[modelId] = read
        }
        do {
            let snapshot = try await read.task.value
            if readCopyTasks[modelId]?.token == read.token { readCopyTasks.removeValue(forKey: modelId) }
            try Task.checkCancellation()
            guard modelRevisions[modelId, default: 0] == revision else { throw CancellationError() }
#if canImport(WhisperKit)
            snapshot.whisperTokenizer = whisperTokenizers[modelId]
#endif
            readSnapshots[modelId] = WeakSnapshot(snapshot)
            return snapshot
        } catch {
            if readCopyTasks[modelId]?.token == read.token { readCopyTasks.removeValue(forKey: modelId) }
            throw error
        }
    }

    private enum DownloadServiceError: LocalizedError {
        case whisperKitUnavailable
        case fluidAudioUnavailable
        case invalidModel
        case pausedModel

        var errorDescription: String? {
            switch self {
            case .invalidModel:
                return "Model files are missing or invalid. Delete and download this model again in Settings."
            case .pausedModel:
                return "Model download is paused. Resume it in Settings before dictating."
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
        queuedStarts.contains(modelId) || (downloadTasks[modelId] != nil && !pausedDownloads.contains(modelId) && !endingDownloads.contains(modelId))
    }

    /// Returns whether the model has a paused download that can be resumed.
    public func isDownloadPaused(modelId: String) -> Bool {
        pausedDownloads.contains(modelId) && downloadTasks[modelId] != nil
    }

    private func updateProgress(modelId: String, token: UUID, fraction: Double) {
        guard isCurrentAttempt(modelId: modelId, token: token),
              !pausedDownloads.contains(modelId), !endingDownloads.contains(modelId) else { return }
        downloadProgress[modelId] = fraction
    }

    private func completeDownload(modelId: String, token: UUID) {
        guard !pausedDownloads.contains(modelId), !endingDownloads.contains(modelId) else { return }
        guard finishDownload(modelId: modelId, token: token) else { return }
        refreshDownloadedModels()
    }

    private func completeParakeetDownload(modelId: String, token: UUID) {
        guard isCurrentAttempt(modelId: modelId, token: token),
              !pausedDownloads.contains(modelId), !endingDownloads.contains(modelId) else { return }
        guard finishDownload(modelId: modelId, token: token) else { return }
        refreshDownloadedModels()
    }

    private func failDownload(modelId: String, token: UUID, message: String) {
        guard isCurrentAttempt(modelId: modelId, token: token),
              !pausedDownloads.contains(modelId), !endingDownloads.contains(modelId) else { return }
        lastError = message
        finishDownload(modelId: modelId, token: token)
    }

    private func cancelledDownload(modelId: String, token: UUID) {
        // Cancellation is an expected user action, not a user-facing error.
        // A paused attempt remains owned by the service so a resume can create
        // a fresh generation without losing the provider's partial cache.
        guard !pausedDownloads.contains(modelId), !endingDownloads.contains(modelId) else { return }
        _ = finishDownload(modelId: modelId, token: token)
    }

    @discardableResult
    private func finishDownload(modelId: String, token: UUID) -> Bool {
        guard isCurrentAttempt(modelId: modelId, token: token) else { return false }
        downloadProgress.removeValue(forKey: modelId)
        indeterminateDownloads.remove(modelId)
        pendingResumes.remove(modelId)
        pausedDownloads.remove(modelId)
        downloadTasks.removeValue(forKey: modelId)
        return true
    }

    /// Pauses a download without deleting or resetting the provider's cache.
    /// The cancelled task is deliberately left behind until its callbacks have
    /// drained; resume replaces its UUID generation before starting again.
    public func pauseDownload(modelId: String) {
        guard let attempt = downloadTasks[modelId],
              !pausedDownloads.contains(modelId),
              !endingDownloads.contains(modelId),
              attempt.task != nil else { return }

        pausedDownloads.insert(modelId)
        indeterminateDownloads.remove(modelId)
        attempt.task?.cancel()
    }

    /// Resumes a paused download using the same catalog operation. A new UUID
    /// generation makes every callback from the cancelled task stale, while
    /// WhisperKit/FluidAudio reuse whatever partial files remain in their cache.
    public func resumeDownload(modelId: String) {
        guard pausedDownloads.contains(modelId),
              !pendingResumes.contains(modelId),
              let model = catalog.first(where: { $0.id == modelId }),
              let attempt = downloadTasks[modelId] else { return }

        pendingResumes.insert(modelId)
        let token = attempt.token
        let cancelledTask = attempt.task
        cancelledTask?.cancel()

        // Retain ownership until the provider call returns. Cancellation is a
        // request, not proof that its file-writing operation has completed.
        Task { @MainActor [weak self] in
            if let cancelledTask {
                await cancelledTask.value
            }
            self?.startResumedDownload(model: model, modelId: modelId, token: token)
        }
    }

    private func startResumedDownload(model: AppModel, modelId: String, token: UUID) {
        guard pendingResumes.remove(modelId) != nil,
              pausedDownloads.contains(modelId),
              isCurrentAttempt(modelId: modelId, token: token) else { return }

        downloadTasks.removeValue(forKey: modelId)
        pausedDownloads.remove(modelId)

        switch model.engine {
        case .whisperKit:
            startWhisperDownload(model)
        case .parakeet:
            startParakeetDownload(model)
        }
    }

    public func cancelDownload(modelId: String) {
        queuedStarts.remove(modelId)
        downloadProgress.removeValue(forKey: modelId)
        indeterminateDownloads.remove(modelId)
        pendingResumes.remove(modelId)
        pausedDownloads.remove(modelId)
        guard let attempt = downloadTasks[modelId], endingDownloads.insert(modelId).inserted else { return }
        invalidateInventory()
        attempt.task?.cancel()
        Task { [weak self] in
            await attempt.task?.value
            guard let self, self.isCurrentAttempt(modelId: modelId, token: attempt.token) else { return }
            self.endingDownloads.remove(modelId)
            self.downloadTasks.removeValue(forKey: modelId)
            self.restartIfQueued(modelId: modelId)
            self.refreshDownloadedModels()
        }
    }

    private func restartIfQueued(modelId: String) {
        guard deletionTasks[modelId] == nil, !endingDownloads.contains(modelId),
              queuedStarts.remove(modelId) != nil else { return }
        startDownload(modelId: modelId)
    }

    public func deleteModel(modelId: String) {
        guard let model = catalog.first(where: { $0.id == modelId }), deletionTasks[modelId] == nil else { return }
        modelRevisions[modelId, default: 0] += 1
        readSnapshots.removeValue(forKey: modelId)
#if canImport(WhisperKit)
        whisperTokenizers.removeValue(forKey: modelId)
#endif
        let readCopy = readCopyTasks[modelId]
        let provider = downloadTasks[modelId]?.task
        cancelDownload(modelId: modelId)
        invalidateInventory()
        downloadedModels.remove(modelId)
        let operation = deletionOperation
        let whisperBase = modelDownloadBaseOverride
        let parakeetBase = parakeetModelBaseOverride
        deletionTasks[modelId] = Task { [weak self] in
            await provider?.value
            _ = try? await readCopy?.task.value
            do {
                if let operation { try await operation(modelId) }
                else {
                    try await Task.detached(priority: .utility) {
                        switch model.engine {
                        case .whisperKit:
                            let base = try whisperBase ?? ModelStorage.whisperKitBase(create: false)
                            try Self.removeWhisperModelFiles(baseDir: base, modelId: modelId)
                            let tokens = try ModelStorage.downloadWorkspace(whisperBase: whisperBase)
                                .appendingPathComponent("Tokenizers/\(modelId)")
                            if FileManager.default.fileExists(atPath: tokens.path) { try FileManager.default.removeItem(at: tokens) }
                        case .parakeet:
                            if let directory = ModelStorage.parakeetDirectory(version: model.parakeetVersion ?? "v3", root: parakeetBase),
                               FileManager.default.fileExists(atPath: directory.path) {
                                try FileManager.default.removeItem(at: directory)
                            }
                        }
                    }.value
                }
            } catch { self?.lastError = "No se pudo borrar \(model.name): \(error.localizedDescription)" }
            guard let self else { return }
            self.deletionTasks.removeValue(forKey: modelId)
            self.restartIfQueued(modelId: modelId)
            self.refreshDownloadedModels()
        }
    }

    private nonisolated static func removeWhisperModelFiles(baseDir: URL, modelId: String) throws {
        guard FileManager.default.fileExists(atPath: baseDir.path) else { return }
        var traversalError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: baseDir, includingPropertiesForKeys: nil,
            errorHandler: { _, error in traversalError = error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var toRemove: [URL] = []
        for case let directory as URL in enumerator where directory.lastPathComponent == modelId {
            toRemove.append(directory)
            enumerator.skipDescendants()
        }
        if let traversalError { throw traversalError }
        for directory in toRemove { try FileManager.default.removeItem(at: directory) }
    }

    /// WhisperKit download/load directory. Delegates to the shared `ModelStorage`
    /// so the engine and this service never look in different places.
    public func modelDownloadBase() throws -> URL {
        if let modelDownloadBaseOverride {
            return modelDownloadBaseOverride
        }
        return try ModelStorage.whisperKitBase()
    }
}
