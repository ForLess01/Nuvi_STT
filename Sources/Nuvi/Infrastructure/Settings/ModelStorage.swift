import Foundation

/// Single source of truth for where downloaded models live on disk.
///
/// Both `WhisperKitEngine` (which loads models) and `ModelDownloadService`
/// (which downloads them) need the same path. Keeping it here prevents the two
/// from drifting and silently looking in different directories.
public enum ModelStorage {
    /// Base directory WhisperKit downloads into and loads from:
    /// `~/Library/Application Support/<bundle-id>/WhisperKit/`.
    public static func whisperKitBase() throws -> URL {
        let manager = FileManager.default
        let applicationSupport = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appFolderName = Bundle.main.bundleIdentifier ?? "com.nuvi.app"
        let base = applicationSupport
            .appendingPathComponent(appFolderName, isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)

        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
