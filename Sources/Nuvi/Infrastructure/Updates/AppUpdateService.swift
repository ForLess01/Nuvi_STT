import Combine
import Foundation

/// Only stable three-component release versions are actionable.
struct StableAppVersion: Comparable, Equatable {
    let components: [Int]
    var description: String { components.map(String.init).joined(separator: ".") }

    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let numbers = pieces.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        components = numbers
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

struct AppRelease: Codable, Equatable {
    let tag: String
    let url: URL
    var version: String { StableAppVersion(tag)?.description ?? tag }

    static func validatedURL(tag: String, url: URL) -> URL? {
        guard StableAppVersion(tag) != nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "github.com", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath == "/ForLess01/Nuvi_STT/releases/tag/\(tag)" else { return nil }
        return url
    }

    static func decode(_ data: Data) throws -> AppRelease {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: URL
            let draft: Bool
            let prerelease: Bool
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.draft, !payload.prerelease,
              let url = validatedURL(tag: payload.tag_name, url: payload.html_url) else {
            throw URLError(.cannotParseResponse)
        }
        return AppRelease(tag: payload.tag_name, url: url)
    }
}

struct AppUpdateResponse {
    let data: Data
    let status: Int
    var retryAfter: String? = nil
}

enum AppUpdateNotificationStatus: String {
    case idle, delivered, denied, unavailable, failed
}

/// Advisory checks have no dependency on capture, engines, or model downloads.
@MainActor
final class AppUpdateService: ObservableObject {
    enum Status: String { case idle, current, failed, rateLimited }
    typealias Fetch = () async throws -> AppUpdateResponse
    typealias Notify = (AppRelease) async -> AppUpdateNotificationStatus
    static let checkInterval: TimeInterval = 12 * 60 * 60

    let installedVersion: String
    @Published private(set) var availableRelease: AppRelease?
    @Published private(set) var status: Status = .idle
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var notificationStatus: AppUpdateNotificationStatus = .idle

    private let defaults: UserDefaults
    private let now: () -> Date
    private let fetch: Fetch
    private let notify: Notify
    private var checking: Task<Void, Never>?
    private var lifecycle: Task<Void, Never>?

    init(installedVersion: String, defaults: UserDefaults, now: @escaping () -> Date = Date.init,
         fetch: @escaping Fetch, notify: @escaping Notify) {
        self.installedVersion = installedVersion
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
        self.notify = notify
        lastChecked = defaults.object(forKey: "updates.lastChecked") as? Date
        status = Status(rawValue: defaults.string(forKey: "updates.status") ?? "") ?? .idle
        notificationStatus = AppUpdateNotificationStatus(rawValue: defaults.string(forKey: "updates.notificationStatus") ?? "") ?? .idle
        if let data = defaults.data(forKey: "updates.availableRelease"),
           let release = try? JSONDecoder().decode(AppRelease.self, from: data),
           AppRelease.validatedURL(tag: release.tag, url: release.url) != nil,
           let installed = StableAppVersion(installedVersion),
           let latest = StableAppVersion(release.tag), latest > installed {
            availableRelease = release
        } else {
            defaults.removeObject(forKey: "updates.availableRelease")
        }
    }

    func start() {
        guard lifecycle == nil else { return }
        lifecycle = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                do { try await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000) }
                catch { break }
            }
        }
    }

    func stop() {
        lifecycle?.cancel()
        lifecycle = nil
        // Retain the cancelled flight until it completes: a restart cannot overlap it.
        checking?.cancel()
    }

    func check(force: Bool = false) async {
        if let checking {
            await checking.value
            return
        }
        let date = now()
        if let limit = defaults.object(forKey: "updates.rateLimitUntil") as? Date, date < limit {
            status = .rateLimited
            return
        }
        if !force, let next = defaults.object(forKey: "updates.nextCheck") as? Date, date < next { return }
        isChecking = true
        checking = Task { [weak self] in await self?.performCheck() }
        await checking?.value
        checking = nil
        isChecking = false
    }

    private func performCheck() async {
        let date = now()
        // Persist before I/O so relaunches do not repeatedly hit an offline endpoint.
        lastChecked = date
        defaults.set(date, forKey: "updates.lastChecked")
        defaults.set(date.addingTimeInterval(60 * 60), forKey: "updates.nextCheck")
        do {
            let response = try await fetch()
            try Task.checkCancellation()
            if response.status == 403 || response.status == 429 {
                let delay = Self.retryDelay(response.retryAfter, now: date)
                defaults.set(date.addingTimeInterval(delay), forKey: "updates.rateLimitUntil")
                setStatus(.rateLimited)
                return
            }
            guard response.status == 200 else { throw URLError(.badServerResponse) }
            let release = try AppRelease.decode(response.data)
            guard let installed = StableAppVersion(installedVersion),
                  let latest = StableAppVersion(release.tag) else { throw URLError(.cannotParseResponse) }
            defaults.removeObject(forKey: "updates.rateLimitUntil")
            defaults.set(date.addingTimeInterval(Self.checkInterval), forKey: "updates.nextCheck")
            setStatus(.current)
            if latest > installed {
                // Do not replace a known newer release with a stale intermediary response.
                if let known = availableRelease, let knownVersion = StableAppVersion(known.tag), knownVersion > latest {
                    return
                }
                availableRelease = release
                defaults.set(try JSONEncoder().encode(release), forKey: "updates.availableRelease")
                if defaults.string(forKey: "updates.notifiedVersion") != release.version {
                    notificationStatus = await notify(release)
                    try Task.checkCancellation()
                    defaults.set(notificationStatus.rawValue, forKey: "updates.notificationStatus")
                    if notificationStatus == .delivered {
                        defaults.set(release.version, forKey: "updates.notifiedVersion")
                    }
                }
            }
        } catch is CancellationError {
            // Late responses from a stopped lifecycle never publish state or notices.
        } catch {
            guard !Task.isCancelled else { return }
            setStatus(.failed)
        }
    }

    private func setStatus(_ value: Status) {
        status = value
        defaults.set(value.rawValue, forKey: "updates.status")
    }

    private static func retryDelay(_ header: String?, now: Date) -> TimeInterval {
        if let header, let seconds = TimeInterval(header), seconds.isFinite {
            return min(max(seconds, 60), checkInterval)
        }
        if let header {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: header) {
                return min(max(date.timeIntervalSince(now), 60), checkInterval)
            }
        }
        return 60 * 60
    }
}
