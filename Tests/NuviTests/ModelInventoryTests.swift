import XCTest
@testable import Nuvi

@MainActor
final class ModelInventoryTests: XCTestCase {
    func testInventoryWorkRunsOutsideMainActor() async {
        let scanned = expectation(description: "Background inventory")
        let service = ModelDownloadService(testingCatalog: [], inventoryOperation: {
            XCTAssertFalse(Thread.isMainThread, "Recursive file inventory must not block UI")
            scanned.fulfill()
            return ["available"]
        })
        service.refreshDownloadedModels()
        await fulfillment(of: [scanned], timeout: 2)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(service.downloadedModels, ["available"])
    }

    func testOlderInventoryCannotOverwriteNewerResult() async {
        let firstStarted = expectation(description: "First scan starts")
        let firstFinished = expectation(description: "First scan finishes")
        let gate = InventoryGate()
        let service = ModelDownloadService(testingCatalog: [], inventoryOperation: {
            if gate.next() == 1 {
                firstStarted.fulfill()
                gate.release.wait()
                firstFinished.fulfill()
                return ["stale"]
            }
            return ["fresh"]
        })
        service.refreshDownloadedModels()
        await fulfillment(of: [firstStarted], timeout: 2)
        // Reaching this line while the scan is blocked proves UI responsiveness.
        service.refreshDownloadedModels()
        let deadline = Date().addingTimeInterval(2)
        while service.isRefreshingModels && Date() < deadline { await Task.yield() }
        XCTAssertEqual(service.downloadedModels, ["fresh"])
        gate.release.signal()
        await fulfillment(of: [firstFinished], timeout: 2)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(service.downloadedModels, ["fresh"])
    }

    func testParakeetAvailabilityRequiresActualVersionedCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NuviTests-Inventory-\(UUID().uuidString)")
        let models = ["v2", "v3"].map { version in
            AppModel(id: "parakeet-\(version)", name: version, desc: "fixture", engine: .parakeet,
                     accuracy: 1, speed: 1, sizeBytes: 1, ramBytes: 1, icon: "waveform", parakeetVersion: version)
        }
        let service = ModelDownloadService(testingCatalog: models, modelDownloadBase: root, parakeetModelBase: root)
        service.downloadedModels = Set(models.map(\.id)) // A stale UI/preference snapshot is not proof.
        await refresh(service)
        XCTAssertTrue(service.downloadedModels.isEmpty)
        for model in models {
            let version = try XCTUnwrap(model.parakeetVersion)
            let directory = try XCTUnwrap(ModelStorage.parakeetDirectory(version: version, root: root))
            let files = try XCTUnwrap(ModelStorage.parakeetRequiredFiles(version: version))
            for name in files.bundles {
                let bundle = directory.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                try Data([1]).write(to: bundle.appendingPathComponent("weights.bin"))
            }
            await refresh(service)
            XCTAssertFalse(service.downloadedModels.contains(model.id), "Missing vocabulary is not ready")
            try Data("{\"0\":\"hello\"}".utf8).write(to: directory.appendingPathComponent(files.vocabulary))
            await refresh(service)
            XCTAssertTrue(service.downloadedModels.contains(model.id))
        }
    }

    private func refresh(_ service: ModelDownloadService) async {
        service.refreshDownloadedModels()
        let deadline = Date().addingTimeInterval(2)
        while service.isRefreshingModels && Date() < deadline { await Task.yield() }
        XCTAssertFalse(service.isRefreshingModels)
    }
}

private final class InventoryGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
