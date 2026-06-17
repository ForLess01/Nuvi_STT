import AppKit

/// Entry point. Nuvi runs as a menu-bar agent (no Dock icon), so we drive
/// NSApplication directly with an `.accessory` activation policy instead of a
/// SwiftUI `App` scene.
@main
enum NuviApp {
    static func main() {
        // Headless probe mode: Nuvi --probe <audiofile> [localeID]
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--probe"), idx + 1 < args.count {
            let path = args[idx + 1]
            let localeID = (idx + 2 < args.count) ? args[idx + 2] : "es-ES"
            Task {
                await Probe.run(path: path, localeID: localeID)
                exit(0)
            }
            RunLoop.main.run()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment()
        environment.start()
        self.environment = environment
    }
}
