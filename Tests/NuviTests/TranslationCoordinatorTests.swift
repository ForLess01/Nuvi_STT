import XCTest
@testable import Nuvi

@MainActor
final class TranslationCoordinatorTests: XCTestCase {
    private final class Clock {
        var durations: [UInt64] = []
        var callbacks: [@MainActor @Sendable () -> Void] = []
        var cancelled: [Int] = []
        func schedule(_ duration: UInt64, _ action: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
            let index = callbacks.count
            durations.append(duration)
            callbacks.append(action)
            return { self.cancelled.append(index) }
        }
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Expected asynchronous event", file: file, line: line)
    }

    func testPreparationHasSeparateBudgetThenTranslationDeadlineCancelsNativeOperation() async {
        let clock = Clock()
        let coordinator = TranslationCoordinator(translationTimeout: 5, preparationTimeout: 60,
                                                  scheduleTimeout: clock.schedule)
        let request = Task { try await coordinator.translate("Esta oración está escrita en español.", to: .englishUS) }
        await waitUntil { coordinator.configuration != nil }
        var preparation: CheckedContinuation<Void, Never>?
        var translation: CheckedContinuation<String, Never>?
        var cancellations = 0
        let operation = Task {
            await coordinator.perform(prepare: { await withCheckedContinuation { preparation = $0 } },
                                      translate: { _ in await withCheckedContinuation { translation = $0 } },
                                      cancel: { cancellations += 1 })
        }
        await waitUntil { preparation != nil }
        XCTAssertEqual(clock.durations, [60])
        XCTAssertNil(translation)
        preparation?.resume()
        await waitUntil { translation != nil }
        XCTAssertEqual(clock.durations, [60, 5])
        XCTAssertEqual(clock.cancelled, [0])
        // Even a queued callback from the cancelled preparation deadline must be stale.
        clock.callbacks[0]()
        XCTAssertNotNil(coordinator.configuration)
        clock.callbacks.last?()
        do { _ = try await request.value; XCTFail("Expected timeout") } catch {}
        XCTAssertEqual(cancellations, 1)
        XCTAssertNil(coordinator.configuration)
        translation?.resume(returning: "late result")
        await operation.value
        XCTAssertEqual(cancellations, 1)
    }

    func testUnidentifiableInputRetainsAutomaticCombinedFallback() async throws {
        let clock = Clock()
        let coordinator = TranslationCoordinator(translationTimeout: 5, preparationTimeout: 60,
                                                  scheduleTimeout: clock.schedule)
        XCTAssertNil(TranslationCoordinator.detectedSourceLanguage("12345"))
        let request = Task { try await coordinator.translate("12345", to: .englishUS) }
        await waitUntil { coordinator.configuration != nil }
        XCTAssertNil(coordinator.configuration?.source)
        var preparations = 0
        await coordinator.perform(prepare: { preparations += 1 }, translate: { text in text }, cancel: {})
        let result = try await request.value
        XCTAssertEqual(result, "12345")
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(clock.durations, [60])
        XCTAssertNil(coordinator.configuration)
    }

    func testCancellationDuringPreparationFinishesCallerAndIgnoresLateCompletion() async {
        let clock = Clock()
        let coordinator = TranslationCoordinator(scheduleTimeout: clock.schedule)
        let request = Task { try await coordinator.translate("Esta oración está escrita en español.", to: .englishUS) }
        await waitUntil { coordinator.configuration != nil }
        var preparation: CheckedContinuation<Void, Never>?
        var translations = 0
        var cancellations = 0
        let operation = Task {
            await coordinator.perform(prepare: { await withCheckedContinuation { preparation = $0 } },
                                      translate: { _ in translations += 1; return "unexpected" },
                                      cancel: { cancellations += 1 })
        }
        await waitUntil { preparation != nil }
        request.cancel()
        do { _ = try await request.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cancellations, 1)
        preparation?.resume()
        await operation.value
        XCTAssertEqual(translations, 0)
        XCTAssertNil(coordinator.configuration)
    }

    func testOriginalAndSameLanguageBypassAllOperations() async throws {
        let clock = Clock()
        let coordinator = TranslationCoordinator(scheduleTimeout: clock.schedule)
        let original = try await coordinator.translate("Hello", to: .original)
        let english = try await coordinator.translate("This is a complete English sentence.", to: .englishUS)
        XCTAssertEqual(original, "Hello")
        XCTAssertEqual(english, "This is a complete English sentence.")
        XCTAssertTrue(clock.durations.isEmpty)
    }
    func testReplacementRejectsOldCompletionAndInvalidatesSamePairConfiguration() async throws {
        let clock = Clock()
        let coordinator = TranslationCoordinator(scheduleTimeout: clock.schedule)
        let first = Task { try await coordinator.translate("Esta oración está escrita en español.", to: .englishUS) }
        await waitUntil { coordinator.configuration != nil }
        let version = coordinator.configuration?.version
        var late: CheckedContinuation<String, Never>?
        var cancellations = 0
        let operation = Task {
            await coordinator.perform(prepare: {},
                                      translate: { _ in await withCheckedContinuation { late = $0 } },
                                      cancel: { cancellations += 1 })
        }
        await waitUntil { late != nil }
        let second = Task { try await coordinator.translate("Esta otra oración también está en español.", to: .englishUS) }
        await waitUntil { coordinator.configuration?.version != version }
        do { _ = try await first.value; XCTFail("Expected replacement cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cancellations, 1)
        late?.resume(returning: "old")
        await operation.value
        XCTAssertNotNil(coordinator.configuration)
        await coordinator.perform(prepare: {}, translate: { _ in "new" }, cancel: {})
        let result = try await second.value
        XCTAssertEqual(result, "new")
        XCTAssertNil(coordinator.configuration)
    }

    func testPreparationTimeoutStopsBeforeTranslation() async {
        let clock = Clock()
        let coordinator = TranslationCoordinator(scheduleTimeout: clock.schedule)
        let request = Task { try await coordinator.translate("Esta oración está escrita en español.", to: .englishUS) }
        await waitUntil { coordinator.configuration != nil }
        var preparation: CheckedContinuation<Void, Never>?
        var translated = false
        var cancellations = 0
        let operation = Task {
            await coordinator.perform(prepare: { await withCheckedContinuation { preparation = $0 } },
                                      translate: { _ in translated = true; return "unexpected" },
                                      cancel: { cancellations += 1 })
        }
        await waitUntil { preparation != nil }
        clock.callbacks[0]()
        do { _ = try await request.value; XCTFail("Expected preparation timeout") } catch {}
        XCTAssertEqual(cancellations, 1)
        preparation?.resume()
        await operation.value
        XCTAssertFalse(translated)
        XCTAssertNil(coordinator.configuration)
    }
}
