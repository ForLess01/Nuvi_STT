import AppKit

/// Entry point. Nuvi runs as a menu-bar agent (no Dock icon), so we drive
/// NSApplication directly with an `.accessory` activation policy instead of a
/// SwiftUI `App` scene.
@main
enum NuviApp {
    enum LaunchMode: Equatable {
        case application
        case probe(path: String, localeID: String)
    }

    static func launchMode(arguments: [String]) -> LaunchMode {
        guard let index = arguments.firstIndex(of: "--probe"), index + 1 < arguments.count else {
            return .application
        }
        let path = arguments[index + 1]
        let localeID = (index + 2 < arguments.count) ? arguments[index + 2] : "es-ES"
        return .probe(path: path, localeID: localeID)
    }

    /// Pure launch router used by `main` and tests. Probe mode is decided before
    /// the lock closure is touched; duplicate and infrastructure failures never
    /// reach application construction.
    static func routeLaunch(
        arguments: [String],
        runProbe: (String, String) -> Void,
        acquire: () -> SingleInstanceGuard.Acquisition,
        activateExisting: () -> Void,
        startApplication: (SingleInstanceGuard) -> Void,
        reportInfrastructureFailure: (Int32) -> Void
    ) {
        switch launchMode(arguments: arguments) {
        case .probe(let path, let localeID):
            runProbe(path, localeID)
        case .application:
            switch acquire() {
            case .acquired(let guardValue):
                startApplication(guardValue)
            case .alreadyRunning:
                activateExisting()
            case .infrastructureFailure(let failure):
                reportInfrastructureFailure(failure)
            }
        }
    }

    static func main() {
        let identity = Bundle.main.bundleIdentifier ?? "com.nuvi.Nuvi"
        let lockURL = SingleInstanceGuard.defaultLockURL(identity: identity)
        routeLaunch(
            arguments: CommandLine.arguments,
            runProbe: { path, localeID in
                Task {
                    await Probe.run(path: path, localeID: localeID)
                    exit(0)
                }
                RunLoop.main.run()
            },
            acquire: { SingleInstanceGuard.acquire(lockURL: lockURL) },
            activateExisting: {
                _ = SingleInstanceGuard.activateExistingApplication(bundleIdentifier: identity)
            },
            startApplication: { instanceGuard in
                let app = NSApplication.shared
                let delegate = AppDelegate(instanceGuard: instanceGuard)
                app.delegate = delegate
                app.setActivationPolicy(.accessory)
                app.run()
            },
            reportInfrastructureFailure: { failure in
                // Fail closed: starting without a reliable lock could duplicate
                // hotkeys and status items. This is not treated as contention.
                NSLog("Nuvi: single-instance lock failed (errno=\(failure))")
            }
        )
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let instanceGuard: SingleInstanceGuard
    private var environment: AppEnvironment?

    init(instanceGuard: SingleInstanceGuard) {
        self.instanceGuard = instanceGuard
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment()
        environment.start()
        self.environment = environment
    }
}
