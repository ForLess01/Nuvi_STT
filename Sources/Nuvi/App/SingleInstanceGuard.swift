import AppKit
import Darwin
import Foundation

/// Holds a non-blocking advisory file lock for the lifetime of the process.
/// The lock URL is injectable so tests never touch Nuvi's real runtime identity.
final class SingleInstanceGuard {
    enum Acquisition {
        case acquired(SingleInstanceGuard)
        case alreadyRunning
        case infrastructureFailure(errno: Int32)
    }

    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(lockURL: URL) -> Acquisition {
        let directory = lockURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .infrastructureFailure(errno: posixCode(from: error))
        }

        errno = 0
        let descriptor = lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            // O_EXLOCK is BSD's advisory flock acquired atomically by open;
            // O_NONBLOCK makes a competing instance fail immediately.
            return Darwin.open(
                path,
                O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            let failure = errno
            if failure == EWOULDBLOCK || failure == EAGAIN {
                return .alreadyRunning
            }
            return .infrastructureFailure(errno: failure)
        }
        return .acquired(SingleInstanceGuard(descriptor: descriptor))
    }

    private static func posixCode(from error: Error) -> Int32 {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(nsError.code)
        }
        return EIO
    }

    static func defaultLockURL(identity: String) -> URL {
        let safeIdentity = identity.map { character in
            character.isLetter || character.isNumber || character == "." || character == "-"
                ? character
                : "-"
        }
        let fileName = "\(String(safeIdentity)).\(Darwin.getuid()).lock"
        return FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    }

    @discardableResult
    static func activateExistingApplication(bundleIdentifier: String) -> Bool {
        guard let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) else {
            return false
        }
        return existing.activate(options: [.activateAllWindows])
    }

    func release() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}
