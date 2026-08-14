import XCTest
@testable import Nuvi

final class SingleInstanceGuardTests: XCTestCase {
    func testSecondAcquireIsRejectedWhileFirstGuardLives() {
        let url = isolatedLockURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = SingleInstanceGuard.acquire(lockURL: url)
        let second = SingleInstanceGuard.acquire(lockURL: url)

        guard case .acquired(let guardValue) = first else {
            return XCTFail("Expected first lock acquisition")
        }
        guard case .alreadyRunning = second else {
            return XCTFail("Expected lock contention")
        }
        withExtendedLifetime(guardValue) {}
    }

    func testLockCanBeAcquiredAfterExplicitRelease() {
        let url = isolatedLockURL()
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .acquired(let first) = SingleInstanceGuard.acquire(lockURL: url) else {
            return XCTFail("Expected first lock acquisition")
        }

        first.release()

        guard case .acquired = SingleInstanceGuard.acquire(lockURL: url) else {
            return XCTFail("Expected reacquisition after release")
        }
    }

    func testLockCanBeAcquiredAfterGuardDeinitializes() {
        let url = isolatedLockURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var first: SingleInstanceGuard?
        if case .acquired(let guardValue) = SingleInstanceGuard.acquire(lockURL: url) {
            first = guardValue
        }
        XCTAssertNotNil(first)

        first = nil

        guard case .acquired = SingleInstanceGuard.acquire(lockURL: url) else {
            return XCTFail("Expected reacquisition after deinit")
        }
    }

    func testDirectoryFailureIsReportedAsInfrastructureFailure() throws {
        let parentFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("NuviTests-SingleInstance-parent-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: parentFile)
        defer { try? FileManager.default.removeItem(at: parentFile) }

        let result = SingleInstanceGuard.acquire(
            lockURL: parentFile.appendingPathComponent("nuvi.lock")
        )

        guard case .infrastructureFailure = result else {
            return XCTFail("Expected infrastructure failure, not duplicate-instance classification")
        }
    }

    func testOpenFailureIsReportedAsInfrastructureFailure() throws {
        let directoryAtLockPath = isolatedLockURL()
        try FileManager.default.createDirectory(at: directoryAtLockPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryAtLockPath) }

        let result = SingleInstanceGuard.acquire(lockURL: directoryAtLockPath)

        guard case .infrastructureFailure(let failure) = result else {
            return XCTFail("Expected open failure, not duplicate-instance classification")
        }
        XCTAssertNotEqual(failure, EWOULDBLOCK)
    }

    func testProbeLaunchModeIsResolvedBeforeNormalApplicationMode() {
        XCTAssertEqual(
            NuviApp.launchMode(arguments: ["Nuvi", "--probe", "/tmp/input.wav", "es-PE"]),
            .probe(path: "/tmp/input.wav", localeID: "es-PE")
        )
        XCTAssertEqual(NuviApp.launchMode(arguments: ["Nuvi"]), .application)
    }

    func testProbeBypassesGuardAndApplicationCreation() {
        var probes: [(String, String)] = []
        var acquireCount = 0
        var applicationCount = 0

        NuviApp.routeLaunch(
            arguments: ["Nuvi", "--probe", "/tmp/input.wav", "es-PE"],
            runProbe: { probes.append(($0, $1)) },
            acquire: {
                acquireCount += 1
                return .alreadyRunning
            },
            activateExisting: { XCTFail("Probe must not activate an app") },
            startApplication: { _ in applicationCount += 1 },
            reportInfrastructureFailure: { _ in XCTFail("Probe must not acquire a lock") }
        )

        XCTAssertEqual(probes.map { "\($0.0)|\($0.1)" }, ["/tmp/input.wav|es-PE"])
        XCTAssertEqual(acquireCount, 0)
        XCTAssertEqual(applicationCount, 0)
    }

    func testDuplicateActivatesExistingAndStopsBeforeApplicationCreation() {
        var activationCount = 0
        var applicationCount = 0

        NuviApp.routeLaunch(
            arguments: ["Nuvi"],
            runProbe: { _, _ in XCTFail("Normal launch must not probe") },
            acquire: { .alreadyRunning },
            activateExisting: { activationCount += 1 },
            startApplication: { _ in applicationCount += 1 },
            reportInfrastructureFailure: { _ in XCTFail("Contention is not infrastructure failure") }
        )

        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(applicationCount, 0)
    }

    func testInfrastructureFailureDoesNotMasqueradeAsDuplicate() {
        var activationCount = 0
        var reportedErrno: Int32?

        NuviApp.routeLaunch(
            arguments: ["Nuvi"],
            runProbe: { _, _ in XCTFail("Normal launch must not probe") },
            acquire: { .infrastructureFailure(errno: EACCES) },
            activateExisting: { activationCount += 1 },
            startApplication: { _ in XCTFail("Fail-closed infrastructure error must not start UI") },
            reportInfrastructureFailure: { reportedErrno = $0 }
        )

        XCTAssertEqual(activationCount, 0)
        XCTAssertEqual(reportedErrno, EACCES)
    }

    private func isolatedLockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NuviTests-SingleInstance-\(UUID().uuidString).lock")
    }
}
