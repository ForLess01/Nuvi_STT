import XCTest
@testable import Nuvi

final class ModelDownloadServiceTests: XCTestCase {
    func testCancelThenRestartKeepsNewAttemptOwnedByNewGeneration() async {
        let model = makeWhisperModel()
        let gate = DownloadGate()
        let service = ModelDownloadService(
            testingCatalog: [model],
            whisperDownloadOperation: gate.operation
        )

        service.startDownload(modelId: model.id)
        await gate.firstStarted.wait()

        service.cancelDownload(modelId: model.id)
        XCTAssertFalse(service.isDownloadActive(modelId: model.id))

        service.startDownload(modelId: model.id)
        await gate.secondStarted.wait()
        XCTAssertTrue(service.isDownloadActive(modelId: model.id))

        // The first operation deliberately succeeds even after cancellation.
        // Its completion must not remove or complete the second attempt.
        gate.firstRelease.signal()
        await gate.firstFinished.wait()
        await Task.yield()
        XCTAssertTrue(service.isDownloadActive(modelId: model.id))
        XCTAssertNil(service.lastError)

        gate.secondRelease.signal()
        await gate.secondFinished.wait()
        await waitUntil { !service.isDownloadActive(modelId: model.id) }
        XCTAssertFalse(service.isDownloadActive(modelId: model.id))
        XCTAssertNil(service.lastError)
    }

    func testCancellationErrorDoesNotBecomeDownloadError() async {
        let model = makeWhisperModel()
        let gate = DownloadGate()
        let service = ModelDownloadService(
            testingCatalog: [model],
            whisperDownloadOperation: gate.cancellationOperation
        )

        service.startDownload(modelId: model.id)
        await gate.firstStarted.wait()

        service.cancelDownload(modelId: model.id)
        gate.firstRelease.signal()
        await gate.firstFinished.wait()
        await waitUntil { !service.isDownloadActive(modelId: model.id) }

        XCTAssertFalse(service.isDownloadActive(modelId: model.id))
        XCTAssertNil(service.lastError)
    }

    func testPauseThenResumeKeepsPartialAttemptOwnedByNewGeneration() async throws {
        let model = makeWhisperModel()
        let gate = DownloadGate()
        let service = ModelDownloadService(
            testingCatalog: [model],
            whisperDownloadOperation: gate.operation
        )

        service.startDownload(modelId: model.id)
        await gate.firstStarted.wait()
        await waitUntil { service.downloadProgress[model.id] == 0.42 }
        XCTAssertEqual(service.downloadProgress[model.id], 0.42)

        service.pauseDownload(modelId: model.id)
        XCTAssertTrue(service.isDownloadPaused(modelId: model.id))
        XCTAssertFalse(service.isDownloadActive(modelId: model.id))
        XCTAssertEqual(service.downloadProgress[model.id], 0.42)

        // Resume is serialized behind the cancelled operation. Repeated taps
        // must not queue a second generation against the same cache.
        service.resumeDownload(modelId: model.id)
        service.resumeDownload(modelId: model.id)
        await Task.yield()
        XCTAssertEqual(gate.numberOfCalls, 1)
        XCTAssertTrue(service.isDownloadPaused(modelId: model.id))
        XCTAssertFalse(service.isDownloadActive(modelId: model.id))
        XCTAssertEqual(service.downloadProgress[model.id], 0.42)

        // The provider may finish its cancellation boundary by returning
        // normally. That stale completion must not consume the paused state.
        gate.firstRelease.signal()
        await gate.firstCancellationObserved.wait()
        await gate.firstFinished.wait()
        await gate.secondStarted.wait()
        XCTAssertFalse(service.isDownloadPaused(modelId: model.id))
        XCTAssertTrue(service.isDownloadActive(modelId: model.id))
        XCTAssertEqual(gate.numberOfCalls, 2)

        gate.secondRelease.signal()
        await gate.secondFinished.wait()
        await waitUntil { !service.isDownloadActive(modelId: model.id) }
        XCTAssertFalse(service.isDownloadPaused(modelId: model.id))
        XCTAssertNil(service.lastError)
    }

    func testDownloadedWhisperVariantsRequireMetadataAndCoreMLBundles() async throws {
        let model = makeWhisperModel()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nuvi-model-download-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let partial = base.appendingPathComponent(model.id, isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: partial.appendingPathComponent("config.json"))
        try addCoreMLBundle(named: "one", to: partial)

        let unknown = base.appendingPathComponent("unknown-variant", isDirectory: true)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: unknown.appendingPathComponent("config.json"))
        try addCoreMLBundle(named: "one", to: unknown)
        try addCoreMLBundle(named: "two", to: unknown)
        try addCoreMLBundle(named: "three", to: unknown)

        let service = ModelDownloadService(
            testingCatalog: [model],
            modelDownloadBase: base
        )
        service.refreshDownloadedModels()
        await waitUntil { service.downloadedModels.isEmpty }
        XCTAssertFalse(service.downloadedModels.contains(model.id))
        XCTAssertFalse(service.downloadedModels.contains("unknown-variant"))

        try addCoreMLBundle(named: "two", to: partial)
        try addCoreMLBundle(named: "three", to: partial)
        try Data().write(to: partial.appendingPathComponent("config.json"))
        service.refreshDownloadedModels()
        await waitUntil { service.downloadedModels.isEmpty }
        XCTAssertFalse(service.downloadedModels.contains(model.id))

        try Data("{}".utf8).write(to: partial.appendingPathComponent("config.json"))
        service.refreshDownloadedModels()
        await waitUntil { service.downloadedModels.contains(model.id) }
        XCTAssertTrue(service.downloadedModels.contains(model.id))
        XCTAssertFalse(service.downloadedModels.contains("unknown-variant"))
    }

    private func addCoreMLBundle(named name: String, to modelDirectory: URL) throws {
        let weights = modelDirectory
            .appendingPathComponent("\(name).mlmodelc", isDirectory: true)
            .appendingPathComponent("weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data([1]).write(to: weights.appendingPathComponent("weight.bin"))
    }

    private func makeWhisperModel() -> AppModel {
        AppModel(
            id: "openai_whisper-test",
            name: "Test Whisper",
            desc: "Test model",
            engine: .whisperKit,
            accuracy: 0.9,
            speed: 0.9,
            sizeBytes: 1,
            ramBytes: 1,
            icon: "waveform"
        )
    }

    private func waitUntil(
        _ predicate: @escaping () -> Bool,
        timeout: TimeInterval = 1
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            await Task.yield()
        }
    }
}

private final class DownloadGate: @unchecked Sendable {
    let firstStarted = AsyncGate()
    let firstCancellationObserved = AsyncGate()
    let secondStarted = AsyncGate()
    let firstRelease = AsyncGate()
    let secondRelease = AsyncGate()
    let firstFinished = AsyncGate()
    let secondFinished = AsyncGate()

    private let lock = NSLock()
    private var callCount = 0

    var numberOfCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    var operation: ModelDownloadService.WhisperDownloadOperation {
        { [self] _, reportProgress in
            let call = nextCall()
            reportProgress(call == 1 ? 0.42 : 0.84)
            switch call {
            case 1:
                firstStarted.signal()
                await firstRelease.wait()
                if Task.isCancelled {
                    firstCancellationObserved.signal()
                }
                firstFinished.signal()
            case 2:
                secondStarted.signal()
                await secondRelease.wait()
                secondFinished.signal()
            default:
                XCTFail("Unexpected extra download attempt")
            }
        }
    }

    var cancellationOperation: ModelDownloadService.WhisperDownloadOperation {
        { [self] _, _ in
            firstStarted.signal()
            await firstRelease.wait()
            firstFinished.signal()
            throw CancellationError()
        }
    }

    private func nextCall() -> Int {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        return callCount
    }
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<Void, Never>?
    private var signaled = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                signaled = false
                lock.unlock()
                continuation.resume()
            } else {
                pending = continuation
                lock.unlock()
            }
        }
    }

    func signal() {
        lock.lock()
        guard let continuation = pending else {
            signaled = true
            lock.unlock()
            return
        }
        pending = nil
        lock.unlock()
        continuation.resume()
    }
}
