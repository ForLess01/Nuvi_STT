import Foundation
import Darwin
#if canImport(WhisperKit)
import WhisperKit
#endif
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Single source of truth for where downloaded models live on disk.
///
/// Both `WhisperKitEngine` (which loads models) and `ModelDownloadService`
/// (which downloads them) need the same path. Keeping it here prevents the two
/// from drifting and silently looking in different directories.
public enum ModelStorage {
    /// Base directory WhisperKit downloads into and loads from:
    /// `~/Library/Application Support/<bundle-id>/WhisperKit/`.
    public static func whisperKitBase(create: Bool = true) throws -> URL {
        let manager = FileManager.default
        let applicationSupport = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        let appFolderName = Bundle.main.bundleIdentifier ?? "com.nuvi.app"
        let base = applicationSupport
            .appendingPathComponent(appFolderName, isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)

        if create { try manager.createDirectory(at: base, withIntermediateDirectories: true) }
        return base
    }

    static func whisperModelDirectory(modelID: String, base: URL) -> URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(modelID, isDirectory: true)
    }

    static func downloadWorkspace(whisperBase: URL? = nil) throws -> URL {
        if let whisperBase { return whisperBase.appendingPathExtension("downloads") }
        return try whisperKitBase(create: false).deletingLastPathComponent()
            .appendingPathComponent("ModelDownloads", isDirectory: true)
    }

    /// The snapshot is our copy, never an inode still owned by an SDK writer.
    /// Rename is same-volume/atomic; EXDEV fails without a partial destination.
    static func publishSnapshot(_ snapshot: URL, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let status: Int32
        if manager.fileExists(atPath: destination.path) {
            status = renameatx_np(AT_FDCWD, snapshot.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP))
        } else {
            status = rename(snapshot.path, destination.path)
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Resolve FluidAudio's exact versioned repository, never a substring match.
    /// The optional root is used only by isolated storage tests.
    static func parakeetDirectory(version: String, root: URL? = nil) -> URL? {
#if canImport(FluidAudio)
        let directory = AsrModels.defaultCacheDirectory(for: version == "v2" ? .v2 : .v3)
        return root?.appendingPathComponent(directory.lastPathComponent, isDirectory: true) ?? directory
#else
        return nil
#endif
    }

    static func parakeetRequiredFiles(version: String) -> (bundles: Set<String>, vocabulary: String)? {
#if canImport(FluidAudio)
        let bundles = version == "v2" ? ModelNames.ASR.requiredModels : ModelNames.ASR.requiredModelsV3(precision: .int8)
        return (bundles, ModelNames.ASR.vocabularyFile)
#else
        return nil
#endif
    }

}

/// A private, independently copied read view. Native models and in-flight
/// transcription tasks retain this owner; cleanup never touches SDK staging.
final class ModelReadSnapshot: @unchecked Sendable {
    let directory: URL
    private let ownedRoot: URL
#if canImport(WhisperKit)
    var whisperTokenizer: (any WhisperTokenizer)?
#endif
    init(directory: URL, ownedRoot: URL) {
        self.directory = directory
        self.ownedRoot = ownedRoot
    }
    deinit {
        let root = ownedRoot
        DispatchQueue.global(qos: .utility).async {
            do { try FileManager.default.removeItem(at: root) }
            catch { NSLog("Nuvi: Could not remove model read snapshot: %@", error.localizedDescription) }
        }
    }
}
