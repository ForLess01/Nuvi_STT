import AppKit
import XCTest
@testable import Nuvi

@MainActor
final class TextInsertionSchedulingTests: XCTestCase {
    func testSuspendedInsertionDoesNotBlockMainActorOrAllowOverlappingOutput() async throws {
        let queue = TextInsertionQueue()
        let gate = InsertionGate()
        var events: [String] = []
        let first = queue.enqueue {
            events.append("first-start")
            await gate.wait()
            events.append("first-end")
        }
        await gate.entered()
        let second = queue.enqueue { events.append("second") }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(events, ["first-start"])
        gate.release()
        try await first.value
        try await second.value
        XCTAssertEqual(events, ["first-start", "first-end", "second"])
    }

    func testCancelledQueuedInsertionDoesNotWriteIntoReplacementSession() async throws {
        let queue = TextInsertionQueue()
        let gate = InsertionGate()
        let first = queue.enqueue { await gate.wait() }
        await gate.entered()
        var didWrite = false
        let cancelled = queue.enqueue { didWrite = true }
        cancelled.cancel()
        gate.release()
        try await first.value
        do { try await cancelled.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(didWrite)
    }
    func testLiveCancellationRollsBackOnlyPostedTextBeforeReplacementOutput() async throws {
        let gate = InsertionGate()
        var events: [String] = []
        var pauses = 0
        let session = TextInjector.LiveSession(hooks: .init(
            validate: { true }, backspace: { events.append("delete"); return true },
            paste: { _ in events.append("paste"); return true }, readback: { _ in true },
            restore: { events.append("restore") }, sleep: { _ in
                pauses += 1
                if pauses == 1 { await gate.wait() }
            }))
        session.text = "abc"
        let update = Task { await TextInjector.updateLiveSession(session, with: "xyz") }
        await gate.entered()
        XCTAssertEqual(session.text, "ab")
        update.cancel()
        TextInjector.cancelLiveSession(session)
        let replacement = TextInsertionQueue.shared.enqueue { events.append("replacement") }
        gate.release()
        let updated = await update.value
        XCTAssertFalse(updated)
        try await replacement.value
        XCTAssertEqual(events, ["delete", "delete", "delete", "restore", "replacement"])
        XCTAssertEqual(session.text, "")
    }

    func testLiveTargetBecomingSecureDuringPauseStopsRemainingNativeEvents() async {
        let gate = InsertionGate()
        var safe = true
        var deletes = 0
        var pastes = 0
        let session = TextInjector.LiveSession(hooks: .init(
            validate: { safe }, backspace: { deletes += 1; return true },
            paste: { _ in pastes += 1; return true }, readback: { _ in true },
            restore: {}, sleep: { _ in await gate.wait() }))
        session.text = "abc"
        let update = Task { await TextInjector.updateLiveSession(session, with: "xyz") }
        await gate.entered()
        safe = false
        gate.release()
        let updated = await update.value
        XCTAssertFalse(updated)
        XCTAssertEqual(deletes, 1)
        XCTAssertEqual(pastes, 0)
    }

    func testUntrustedUnicodeUsesNoClipboardAndStopsWhenOriginalPIDChanges() async {
        let gate = InsertionGate()
        var originalPID = true
        var chunks: [[UniChar]] = []
        let typing = Task {
            await TextInjector.typeUnicode(String(repeating: "x", count: 80), valid: { originalPID },
                post: { chunks.append($0); return true }, sleep: { _ in await gate.wait() })
        }
        await gate.entered()
        originalPID = false
        gate.release()
        let typed = await typing.value
        XCTAssertFalse(typed)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.count, 32)
        if case .manualFallback = TextInjector.untrustedAttemptResult(didPostEvent: true) {} else {
            XCTFail("Untrusted output must never claim verification or choose clipboard")
        }
    }

    func testReadbackWaitYieldsMainActorAndRevalidatesTarget() async {
        let gate = InsertionGate()
        var valid = true
        let readback = Task {
            await TextInjector.waitForTarget(nanoseconds: 80_000_000, valid: { valid },
                                            sleep: { _ in await gate.wait() })
        }
        await gate.entered()
        valid = false
        gate.release()
        let verified = await readback.value
        XCTAssertFalse(verified)
    }

    func testReplacementCapturesClipboardOnlyAfterPredecessorRollback() async throws {
        let gate = InsertionGate()
        var clipboard = "previous temporary text"
        var captured: String?
        let rollback = TextInsertionQueue.shared.enqueue {
            await gate.wait()
            clipboard = "original clipboard"
        }
        await gate.entered()
        let session = TextInjector.LiveSession(hooks: .init(
            validate: { true }, backspace: { true }, paste: { _ in true }, readback: { _ in true },
            restore: {}, sleep: { _ in }, capture: { captured = clipboard }))
        let replacement = Task { await TextInjector.updateLiveSession(session, with: "new session") }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(captured)
        gate.release()
        try await rollback.value
        let updated = await replacement.value
        XCTAssertTrue(updated)
        XCTAssertEqual(captured, "original clipboard")
    }

    func testUnicodePreservesChunkOrderForUnchangedOriginalTarget() async {
        let text = String(repeating: "abc", count: 30)
        var chunks: [[UniChar]] = []
        let posted = await TextInjector.typeUnicode(text, valid: { true },
            post: { chunks.append($0); return true }, sleep: { _ in })
        XCTAssertTrue(posted)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
    }

}

@MainActor
private final class InsertionGate {
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { waiter = $0 } }
    func entered() async { while waiter == nil { await Task.yield() } }
    func release() { waiter?.resume(); waiter = nil }
}
