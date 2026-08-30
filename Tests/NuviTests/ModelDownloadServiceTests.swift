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
    let secondStarted = AsyncGate()
    let firstRelease = AsyncGate()
    let secondRelease = AsyncGate()
    let firstFinished = AsyncGate()
    let secondFinished = AsyncGate()

    private let lock = NSLock()
    private var callCount = 0

    var operation: ModelDownloadService.WhisperDownloadOperation {
        { [self] _, _ in
            let call = nextCall()
            switch call {
            case 1:
                firstStarted.signal()
                await firstRelease.wait()
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
