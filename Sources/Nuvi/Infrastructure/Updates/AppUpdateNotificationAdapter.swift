import AppKit
import UserNotifications

/// Constructed only by the running bundled app, never by service tests.
@MainActor
final class AppUpdateNotificationAdapter: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter?

    override init() {
        if Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil {
            center = UNUserNotificationCenter.current()
        } else {
            center = nil
        }
        super.init()
        center?.delegate = self
    }

    func notify(_ release: AppRelease) async -> AppUpdateNotificationStatus {
        guard let center else { return .unavailable }
        let settings = await center.notificationSettings()
        var authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        if settings.authorizationStatus == .notDetermined {
            do { authorized = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch { return .failed }
        }
        guard authorized else { return .denied }
        guard !Task.isCancelled else { return .failed }
        let content = UNMutableNotificationContent()
        content.title = tr("Nuvi update available", "Actualización de Nuvi disponible")
        content.body = tr("Nuvi \(release.version) is available. Open the release page to update.",
                          "Nuvi \(release.version) está disponible. Abra la página de la versión para actualizar.")
        content.sound = .default
        content.userInfo = ["tag": release.tag, "url": release.url.absoluteString]
        do {
            try await center.add(UNNotificationRequest(identifier: "nuvi.update.\(release.version)",
                                                       content: content, trigger: nil))
            return .delivered
        } catch { return .failed }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let tag = info["tag"] as? String, let rawURL = info["url"] as? String,
           let url = URL(string: rawURL), AppRelease.validatedURL(tag: tag, url: url) != nil {
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
