import XCTest
@testable import Nuvi

@MainActor
final class AppUpdateServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        suite = "AppUpdateServiceTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func response(_ tag: String = "v2.2.1", status: Int = 200,
                          url: String? = nil, draft: Bool = false, prerelease: Bool = false,
                          retryAfter: String? = nil) throws -> AppUpdateResponse {
        let data = try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "html_url": url ?? "https://github.com/ForLess01/Nuvi_STT/releases/tag/\(tag)",
            "draft": draft, "prerelease": prerelease
        ])
        return AppUpdateResponse(data: data, status: status, retryAfter: retryAfter)
    }

    private func service(fetch: @escaping AppUpdateService.Fetch,
                         notify: @escaping AppUpdateService.Notify = { _ in .delivered },
                         installed: String = "2.2.0") -> AppUpdateService {
        AppUpdateService(installedVersion: installed, defaults: defaults,
                         now: { self.now }, fetch: fetch, notify: notify)
    }

    func testNumericStableVersions() {
        XCTAssertTrue(StableAppVersion("2.10.0")! > StableAppVersion("v2.9.9")!)
        XCTAssertEqual(StableAppVersion("v2.2.1"), StableAppVersion("2.2.1"))
        for invalid in ["2.2", "2.2.1-rc.1", "2.2.1+build", "-1.2.3", "2.2.1/evil", "2.2.9999999999999999999999"] {
            XCTAssertNil(StableAppVersion(invalid))
        }
    }

    func testFindsUpdateAndDeduplicatesAfterRestart() async throws {
        var notices = 0
        let reply = try response()
        let app = service(fetch: { reply }, notify: { _ in notices += 1; return .delivered })
        await app.check()
        XCTAssertEqual(app.availableRelease?.version, "2.2.1")
        XCTAssertEqual(notices, 1)
        let restarted = service(fetch: { reply }, notify: { _ in notices += 1; return .delivered })
        XCTAssertEqual(restarted.availableRelease?.version, "2.2.1")
        await restarted.check(force: true)
        XCTAssertEqual(notices, 1)
    }

    func testEqualOlderAndInvalidInstalledDoNotNotify() async throws {
        var notices = 0
        for installed in ["2.2.1", "2.10.0", "unknown"] {
            let app = service(fetch: { try self.response() }, notify: { _ in notices += 1; return .delivered }, installed: installed)
            await app.check(force: true)
            XCTAssertNil(app.availableRelease)
        }
        XCTAssertEqual(notices, 0)
    }

    func testRejectsUntrustedURLsAndUnstableReleases() async throws {
        let unsafe = ["http://github.com/ForLess01/Nuvi_STT/releases/tag/v2.2.1",
                      "https://github.com.evil.test/ForLess01/Nuvi_STT/releases/tag/v2.2.1",
                      "https://user@github.com/ForLess01/Nuvi_STT/releases/tag/v2.2.1",
                      "https://github.com/other/repo/releases/tag/v2.2.1",
                      "https://github.com/ForLess01/Nuvi_STT/releases/tag/v2.2.1#evil",
                      "https://github.com/ForLess01/Nuvi_STT/releases/tag/v2.2.1?evil=1",
                      "https://github.com:443/ForLess01/Nuvi_STT/releases/tag/v2.2.1",
                      "https://github.com/ForLess01/Nuvi_STT/releases/tag/v9.0.0"]
        for url in unsafe {
            let app = service(fetch: { try self.response(url: url) })
            await app.check(force: true)
            XCTAssertNil(app.availableRelease, url)
            XCTAssertEqual(app.status, .failed)
        }
        for reply in [try response(draft: true), try response(prerelease: true), try response("v2.3.0-beta")] {
            let app = service(fetch: { reply })
            await app.check(force: true)
            XCTAssertNil(app.availableRelease)
        }
    }

    func testAutomaticThrottleSurvivesRestartAndManualCheckRefreshes() async throws {
        var requests = 0
        let reply = try response()
        let fetch: AppUpdateService.Fetch = { requests += 1; return reply }
        await service(fetch: fetch).check()
        let restarted = service(fetch: fetch)
        await restarted.check()
        XCTAssertEqual(requests, 1)
        await restarted.check(force: true)
        XCTAssertEqual(requests, 2)
        now += 12 * 60 * 60
        await restarted.check()
        XCTAssertEqual(requests, 3)
    }

    func testOfflineKeepsAvailableReleaseAndNotificationFailureRetries() async throws {
        var attempts = 0
        let reply = try response()
        let app = service(fetch: { reply }, notify: { _ in attempts += 1; return .failed })
        await app.check()
        XCTAssertEqual(app.notificationStatus, .failed)
        await app.check(force: true)
        XCTAssertEqual(attempts, 2)
        let offline = service(fetch: { throw URLError(.notConnectedToInternet) })
        await offline.check(force: true)
        XCTAssertEqual(offline.status, .failed)
        XCTAssertEqual(offline.availableRelease?.version, "2.2.1")
    }

    func testPermissionDenialNeverHidesUpdateOrMarksDelivered() async throws {
        let reply = try response()
        let denied = service(fetch: { reply }, notify: { _ in .denied })
        await denied.check()
        XCTAssertEqual(denied.availableRelease?.version, "2.2.1")
        XCTAssertEqual(denied.notificationStatus, .denied)
        var delivered = 0
        let granted = service(fetch: { reply }, notify: { _ in delivered += 1; return .delivered })
        await granted.check(force: true)
        XCTAssertEqual(delivered, 1)
    }

    func testRateLimitBackoffAppliesEvenToManualChecksAndPersists() async throws {
        var requests = 0
        let reply = try response(status: 429, retryAfter: "7200")
        let fetch: AppUpdateService.Fetch = { requests += 1; return reply }
        await service(fetch: fetch).check()
        let restarted = service(fetch: fetch)
        await restarted.check(force: true)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(restarted.status, .rateLimited)
        now += 7201
        await restarted.check(force: true)
        XCTAssertEqual(requests, 2)
    }

    func testOverlapIsSingleFlightAndStopIgnoresLateResponse() async throws {
        var requests = 0
        var continuation: CheckedContinuation<AppUpdateResponse, Error>?
        let app = service(fetch: {
            requests += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        })
        let first = Task { await app.check() }
        while continuation == nil { await Task.yield() }
        let overlap = Task { await app.check(force: true) }
        await Task.yield()
        XCTAssertEqual(requests, 1)
        app.stop()
        continuation?.resume(returning: try response())
        await first.value
        await overlap.value
        XCTAssertNil(app.availableRelease)
        XCTAssertFalse(app.isChecking)
    }

    func testNewerReleaseNotifiesAgainAndOlderResponseKeepsKnownUpdate() async throws {
        var reply = try response()
        var versions: [String] = []
        let app = service(fetch: { reply }, notify: { versions.append($0.version); return .delivered })
        await app.check()
        reply = try response("v2.3.0")
        await app.check(force: true)
        XCTAssertEqual(versions, ["2.2.1", "2.3.0"])
        reply = try response()
        await app.check(force: true)
        XCTAssertEqual(app.availableRelease?.version, "2.3.0")
        XCTAssertEqual(versions.count, 2)
    }

    func testMalformedPayloadAndHTTPFailuresRetainKnownUpdate() async throws {
        var reply = try response()
        let app = service(fetch: { reply })
        await app.check()
        for failed in [AppUpdateResponse(data: Data("not json".utf8), status: 200),
                       try response(status: 500), try response(status: 302)] {
            reply = failed
            await app.check(force: true)
            XCTAssertEqual(app.status, .failed)
            XCTAssertEqual(app.availableRelease?.version, "2.2.1")
        }
    }

    func testRateLimitHTTPDateAndInvalidHeaderUseBoundedBackoff() async throws {
        for header in ["NaN", "-1", "999999999", "Thu, 01 Jan 2099 00:00:00 GMT"] {
            defaults.removePersistentDomain(forName: suite)
            var requests = 0
            let app = service(fetch: { requests += 1; return try self.response(status: 403, retryAfter: header) })
            await app.check()
            await app.check(force: true)
            XCTAssertEqual(requests, 1)
            now += AppUpdateService.checkInterval + 1
            await app.check(force: true)
            XCTAssertEqual(requests, 2)
        }
    }

    func testCancelledFlightCanBeCheckedAgainWithoutOverlap() async throws {
        var continuation: CheckedContinuation<AppUpdateResponse, Error>?
        var requests = 0
        let app = service(fetch: {
            requests += 1
            if requests == 1 {
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            return try self.response()
        })
        let first = Task { await app.check() }
        while continuation == nil { await Task.yield() }
        app.stop()
        continuation?.resume(returning: try response())
        await first.value
        await app.check(force: true)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(app.availableRelease?.version, "2.2.1")
    }

    func testMalformedPersistedReleaseIsDiscardedAndNewInstallClearsUpdate() async throws {
        let app = service(fetch: { try self.response() })
        await app.check()
        XCTAssertNil(service(fetch: { try self.response() }, installed: "2.2.1").availableRelease)
        defaults.set(Data("{broken}".utf8), forKey: "updates.availableRelease")
        XCTAssertNil(service(fetch: { try self.response() }).availableRelease)
    }
}
