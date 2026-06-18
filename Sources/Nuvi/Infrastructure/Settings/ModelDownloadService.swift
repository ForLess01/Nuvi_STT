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
    public var desc: String
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

    // Backwards-compatible default so older JSON without an `engine` key still
    // decodes as a WhisperKit model.
    enum CodingKeys: String, CodingKey {
        case id, name, desc, engine, accuracy, speed, sizeBytes, ramBytes, icon, downloadUrl, parakeetVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        desc = try c.decode(String.self, forKey: .desc)
        engine = try c.decodeIfPresent(ModelEngine.self, forKey: .engine) ?? .whisperKit
        accuracy = try c.decode(Double.self, forKey: .accuracy)
        speed = try c.decode(Double.self, forKey: .speed)
        sizeBytes = try c.decode(Int64.self, forKey: .sizeBytes)
        ramBytes = try c.decode(Int64.self, forKey: .ramBytes)
        icon = try c.decode(String.self, forKey: .icon)
        downloadUrl = try c.decodeIfPresent(String.self, forKey: .downloadUrl)
        parakeetVersion = try c.decodeIfPresent(String.self, forKey: .parakeetVersion)
    }

    public init(id: String, name: String, desc: String, engine: ModelEngine,
                accuracy: Double, speed: Double, sizeBytes: Int64, ramBytes: Int64,
                icon: String, downloadUrl: String? = nil, parakeetVersion: String? = nil) {
        self.id = id
        self.name = name
        self.desc = desc
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
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    public static let shared = ModelDownloadService()

    private override init() {
        super.init()
        loadCatalog()
        refreshDownloadedModels()
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

        DispatchQueue.main.async {
            self.downloadProgress[modelId] = 0.01 // Marcar inicio
        }

        // Strong capture is fine: this is the shared singleton, which lives for
        // the whole app, so there is no meaningful retain cycle to break.
        let task = Task {
#if canImport(WhisperKit)
            do {
                let base = try ModelStorage.whisperKitBase()
                // WhisperKit resolves the variant against argmaxinc/whisperkit-coreml
                // and downloads the CoreML model folder (with real progress) — no
                // direct .zip URL involved.
                _ = try await WhisperKit.download(
                    variant: modelId,
                    downloadBase: base,
                    progressCallback: { progress in
                        // Reference the singleton (not `self`) to keep this
                        // @Sendable callback free of a non-Sendable capture.
                        DispatchQueue.main.async {
                            ModelDownloadService.shared.downloadProgress[modelId] = progress.fractionCompleted
                        }
                    }
                )
                await MainActor.run {
                    self.finishDownload(modelId)
                    self.refreshDownloadedModels()
                }
            } catch {
                await MainActor.run {
                    self.lastError = "No se pudo descargar \(model.name): \(error.localizedDescription)"
                    self.finishDownload(modelId)
                }
            }
#else
            await MainActor.run {
                self.lastError = "WhisperKit no está disponible en este build."
                self.finishDownload(modelId)
            }
#endif
        }
        downloadTasks[modelId] = task
    }

    private func startParakeetDownload(_ model: AppModel) {
        let modelId = model.id
        guard downloadTasks[modelId] == nil else { return }

        DispatchQueue.main.async {
            self.indeterminateDownloads.insert(modelId)
        }

        let task = Task {
#if canImport(FluidAudio)
            do {
                let version: AsrModelVersion = (model.parakeetVersion == "v2") ? .v2 : .v3
                _ = try await AsrModels.downloadAndLoad(version: version)
                await MainActor.run {
                    var set = SettingsStore.shared.downloadedParakeetModels
                    set.insert(modelId)
                    SettingsStore.shared.downloadedParakeetModels = set
                    self.finishDownload(modelId)
                    self.refreshDownloadedModels()
                }
            } catch {
                await MainActor.run {
                    self.lastError = "No se pudo descargar \(model.name): \(error.localizedDescription)"
                    self.finishDownload(modelId)
                }
            }
#else
            await MainActor.run {
                self.lastError = "FluidAudio no está disponible en este build."
                self.finishDownload(modelId)
            }
#endif
        }
        downloadTasks[modelId] = task
    }

    private func finishDownload(_ modelId: String) {
        downloadProgress.removeValue(forKey: modelId)
        indeterminateDownloads.remove(modelId)
        downloadTasks.removeValue(forKey: modelId)
    }

    public func cancelDownload(modelId: String) {
        guard let task = downloadTasks[modelId] else { return }
        task.cancel()
        DispatchQueue.main.async {
            self.finishDownload(modelId)
        }
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
