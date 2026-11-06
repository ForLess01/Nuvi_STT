import XCTest
import FluidAudio
import CoreML
import WhisperKit
@testable import Nuvi

@MainActor
final class ModelPreparationTests: XCTestCase {
    private var model: AppModel {
        AppModel(id: "openai_whisper-test", name: "Test", desc: "Fixture", engine: .whisperKit,
                 accuracy: 1, speed: 1, sizeBytes: 1, ramBytes: 1, icon: "waveform")
    }

    func testAutomaticAcquisitionCoalescesAndReturnsIndependentReadSnapshot() async throws {
        let root = temporaryRoot()
        let began = expectation(description: "Provider started")
        let release = PreparationSignal()
        var calls = 0
        let service = ModelDownloadService(testingCatalog: [model], modelDownloadBase: root,
            stagedDownloadOperation: { model, base, _ in
                calls += 1
                began.fulfill()
                await release.wait()
                return try Self.writeModel(model, base: base)
            })
        let first = Task { try await service.prepareModelSnapshot(modelId: model.id) }
        let second = Task { try await service.prepareModelSnapshot(modelId: model.id) }
        await fulfillment(of: [began], timeout: 2)
        await release.signal()
        let a = try await first.value
        let b = try await second.value
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(a === b, "Concurrent preparations share one owned read copy")
        let canonical = ModelStorage.whisperModelDirectory(modelID: model.id, base: root)
        XCTAssertNotEqual(a.directory, canonical)
        service.deleteModel(modelId: model.id)
        await waitUntil { !FileManager.default.fileExists(atPath: canonical.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))
        XCTAssertEqual(try Data(contentsOf: a.directory.appendingPathComponent("marker")), Data("original".utf8))
    }

    func testReadSnapshotIsReusedAndRemovedAfterLastOwnerReleasesIt() async throws {
        let root = temporaryRoot()
        _ = try Self.writeModel(model, base: root)
        let service = ModelDownloadService(testingCatalog: [model], modelDownloadBase: root,
            stagedDownloadOperation: { _, _, _ in throw PreparationError.unexpectedDownload })
        var first: ModelReadSnapshot? = try await service.prepareModelSnapshot(modelId: model.id)
        var second: ModelReadSnapshot? = try await service.prepareModelSnapshot(modelId: model.id)
        let directory = try XCTUnwrap(first?.directory)
        XCTAssertTrue(first === second)
        first = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        second = nil
        await waitUntil { !FileManager.default.fileExists(atPath: directory.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDeleteWaitsForReadCopyAndInvalidatesPendingPreparation() async throws {
        let root = temporaryRoot()
        let canonical = try Self.writeModel(model, base: root)
        let copying = expectation(description: "Copy owns canonical read")
        let release = DispatchSemaphore(value: 0)
        let service = ModelDownloadService(testingCatalog: [model], modelDownloadBase: root,
            stagedDownloadOperation: { _, _, _ in throw PreparationError.unexpectedDownload },
            snapshotCopyOperation: { source, destination in
                copying.fulfill()
                release.wait()
                try FileManager.default.copyItem(at: source, to: destination)
            })
        let preparation = Task { try await service.prepareModelSnapshot(modelId: model.id) }
        await fulfillment(of: [copying], timeout: 2)
        service.deleteModel(modelId: model.id)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonical.path))
        release.signal()
        do { _ = try await preparation.value; XCTFail("Deletion must invalidate the pending preparation") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected error: \(error)") }
        await waitUntil { !FileManager.default.fileExists(atPath: canonical.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))
    }

    func testFailedAttemptPreservesPreviouslyCompleteCanonicalModel() async throws {
        let root = temporaryRoot()
        let canonical = try Self.writeModel(model, base: root)
        let before = try Data(contentsOf: canonical.appendingPathComponent("marker"))
        let service = ModelDownloadService(testingCatalog: [model], modelDownloadBase: root,
            stagedDownloadOperation: { _, _, _ in throw PreparationError.failedProvider })
        service.startDownload(modelId: model.id)
        await waitUntil { service.lastError != nil }
        XCTAssertNotNil(service.lastError)
        XCTAssertEqual(try Data(contentsOf: canonical.appendingPathComponent("marker")), before)
    }

    func testSuccessfulAcquisitionAtomicallyReplacesOnlyIncompleteCanonicalModel() async throws {
        let root = temporaryRoot()
        let canonical = ModelStorage.whisperModelDirectory(modelID: model.id, base: root)
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: canonical.appendingPathComponent("incomplete"))
        let service = ModelDownloadService(testingCatalog: [model], modelDownloadBase: root,
            stagedDownloadOperation: { model, base, _ in try Self.writeModel(model, base: base) })
        let snapshot = try await service.prepareModelSnapshot(modelId: model.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.appendingPathComponent("incomplete").path))
        XCTAssertEqual(try Data(contentsOf: canonical.appendingPathComponent("marker")), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: snapshot.directory.appendingPathComponent("marker")), Data("original".utf8))
    }

    func testFailedReadCopyCleansOwnedSnapshotAndPreservesCanonical() async throws {
        let root = temporaryRoot()
        let canonical = try Self.writeModel(model, base: root)
        let service = ModelDownloadService(testingCatalog: [model], modelDownloadBase: root,
            stagedDownloadOperation: { _, _, _ in throw PreparationError.unexpectedDownload },
            snapshotCopyOperation: { _, destination in
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                throw PreparationError.failedProvider
            })
        do { _ = try await service.prepareModelSnapshot(modelId: model.id); XCTFail("Expected copy failure") }
        catch {}
        let readers = try ModelStorage.downloadWorkspace(whisperBase: root).appendingPathComponent("Readers")
        await waitUntil { (try? FileManager.default.contentsOfDirectory(atPath: readers.path).isEmpty) == true }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: readers.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonical.path))
    }

    func testWhisperLocalConfigurationDisablesSDKAcquisitionAndAutomaticLoading() {
        let directory = temporaryRoot()
        let config = WhisperKitEngine.localConfiguration(directory: directory)
        XCTAssertEqual(config.modelFolder, directory.path)
        XCTAssertEqual(config.tokenizerFolder, directory)
        XCTAssertEqual(config.load, false)
        XCTAssertFalse(config.download)
        XCTAssertFalse(config.useBackgroundDownloadSession)
    }

    func testCompleteWhisperAndLegacyTokenizerPrepareOfflineAcrossServiceRestart() async throws {
        let root = temporaryRoot()
        var cached = model
        cached.id = "openai_whisper-tiny"
        _ = try Self.writeModel(cached, base: root)
        let legacyTokenizer = root.appendingPathComponent("models/openai/whisper-tiny")
        try FileManager.default.createDirectory(at: legacyTokenizer, withIntermediateDirectories: true)
        try Data("cached tokenizer".utf8).write(to: legacyTokenizer.appendingPathComponent("tokenizer.json"))
        var acquisitionCalls = 0
        var tokenizerCalls = 0
        func service() -> ModelDownloadService {
            let service = ModelDownloadService(testingCatalog: [cached], modelDownloadBase: root)
            service.whisperAssetAcquisitionOverride = { _, _, _ in
                acquisitionCalls += 1
                throw PreparationError.unexpectedDownload
            }
            service.whisperTokenizerPreparationOverride = { variant, base, _ in
                tokenizerCalls += 1
                XCTAssertEqual(variant.description, "tiny")
                let file = base.appendingPathComponent("models/openai/whisper-tiny/tokenizer.json")
                XCTAssertEqual(try Data(contentsOf: file), Data("cached tokenizer".utf8))
                return PreparationTokenizer()
            }
            return service
        }
        let first = try await service().prepareModelSnapshot(modelId: cached.id)
        XCTAssertNotNil(first.whisperTokenizer)
        XCTAssertEqual(acquisitionCalls, 0, "Complete local model must not call Hub model listing/download")
        // The coordinator published a private tokenizer cache; next process no
        // longer depends on the old SDK cache location or in-memory tokenizer.
        try FileManager.default.removeItem(at: legacyTokenizer)
        let second = try await service().prepareModelSnapshot(modelId: cached.id)
        XCTAssertNotNil(second.whisperTokenizer)
        XCTAssertEqual(acquisitionCalls, 0)
        XCTAssertEqual(tokenizerCalls, 2)
    }

    func testParakeetManifestMatchesV2V3Int8ComputeConfiguration() {
        for version: AsrModelVersion in [.v2, .v3] {
            let manifest = ParakeetEngine.localModelManifest(version: version)
            XCTAssertEqual(manifest.map(\.0), [ModelNames.ASR.preprocessorFile, ModelNames.ASR.encoderFile,
                ModelNames.ASR.decoderFile, version == .v2 ? ModelNames.ASR.jointFile : ModelNames.ASR.jointV3File])
            XCTAssertEqual(manifest[0].1, .cpuOnly)
            XCTAssertTrue(manifest.dropFirst().allSatisfy { $0.1 == AsrModels.defaultConfiguration().computeUnits })
        }
    }

    func testParakeetMissingCorruptAssetsFailLocallyWithoutRetryingLoader() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vocabulary = root.appendingPathComponent(ModelNames.ASR.vocabularyFile)
        var loads = 0
        let load: (URL, MLModelConfiguration) throws -> MLModel = { _, _ in
            loads += 1
            throw PreparationError.corruptModel
        }
        try Data("broken".utf8).write(to: vocabulary)
        XCTAssertThrowsError(try ParakeetEngine.loadLocalModels(directory: root, version: .v3, loader: load))
        XCTAssertEqual(loads, 0)
        try Data("{\"0\":\"token\"}".utf8).write(to: vocabulary)
        XCTAssertThrowsError(try ParakeetEngine.loadLocalModels(directory: root, version: .v3, loader: load))
        XCTAssertEqual(loads, 0)
        for (name, _) in ParakeetEngine.localModelManifest(version: .v3) {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        XCTAssertThrowsError(try ParakeetEngine.loadLocalModels(directory: root, version: .v3, loader: load))
        XCTAssertEqual(loads, 1, "A corrupt CoreML load must not trigger download/retry or deletion")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vocabulary.path))
        try Data("[\"a\",\"b\"]".utf8).write(to: vocabulary)
        XCTAssertEqual(try ParakeetEngine.localVocabulary(at: vocabulary), [0: "a", 1: "b"])
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("NuviTests-Preparation-\(UUID().uuidString)")
    }

    private static func writeModel(_ model: AppModel, base: URL) throws -> URL {
        let directory = ModelStorage.whisperModelDirectory(modelID: model.id, base: base)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data("original".utf8).write(to: directory.appendingPathComponent("marker"))
        for name in ["one", "two", "three"] {
            let bundle = directory.appendingPathComponent("\(name).mlmodelc")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data([1]).write(to: bundle.appendingPathComponent("weights.bin"))
        }
        return directory
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !predicate() && Date() < deadline { await Task.yield() }
    }
}

private enum PreparationError: Error { case unexpectedDownload, failedProvider, corruptModel }

private struct PreparationTokenizer: WhisperTokenizer {
    let specialTokens = SpecialTokens(endToken: 1, englishToken: 2, noSpeechToken: 3, noTimestampsToken: 4,
        specialTokenBegin: 5, startOfPreviousToken: 6, startOfTranscriptToken: 7, timeTokenBegin: 8,
        transcribeToken: 9, translateToken: 10, whitespaceToken: 11)
    let allLanguageTokens: Set<Int> = []
    func encode(text: String) -> [Int] { [] }
    func decode(tokens: [Int]) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) { ([], []) }
}

private actor PreparationSignal {
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func signal() {
        open = true
        continuation?.resume()
        continuation = nil
    }
}
