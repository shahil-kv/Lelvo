import Foundation
import Testing
@testable import LelvoCore

@Suite struct SharedWorkTests {
    /// Thread-safe flags for what the work saw.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Double] = [:]
        func set(_ key: String, _ value: Double = 1) { lock.withLock { values[key] = value } }
        func get(_ key: String) -> Double? { lock.withLock { values[key] } }
    }

    private func wait(_ condition: @Sendable () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// Runs until cancelled or released, reporting what happened in `box`.
    private func slowWork(_ box: Box) -> @Sendable (@escaping SharedWork<String>.Progress) async throws -> String {
        { report in
            box.set("started", (box.get("started") ?? 0) + 1)
            report(0.25)
            do {
                while box.get("release") == nil {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
            } catch {
                box.set("cancelled")
                throw error
            }
            return "done"
        }
    }

    @Test func cancellingTheOnlyFollowerStopsTheWork() async throws {
        let work = SharedWork<String>(), box = Box()
        let waiter = Task { try await work.run("k", progress: { _ in }, slowWork(box)) }
        await wait { box.get("started") != nil }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        await wait { box.get("cancelled") != nil }
        #expect(box.get("cancelled") != nil)
    }

    @Test func aCancelReturnsAtOnceWhileAnotherWaiterKeepsTheWork() async throws {
        let work = SharedWork<String>(), box = Box()
        let stays = Task { try await work.run("k", slowWork(box)) }
        await wait { box.get("started") != nil }
        let leaves = Task { try await work.run("k", progress: { _ in }, slowWork(box)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        leaves.cancel()
        await #expect(throws: CancellationError.self) { try await leaves.value }
        #expect(box.get("cancelled") == nil)
        box.set("release")
        #expect(try await stays.value == "done")
        #expect(box.get("started") == 1)
    }

    @Test func aWaiterWithoutProgressLeavesTheWorkRunning() async throws {
        let work = SharedWork<String>(), box = Box()
        let waiter = Task { try await work.run("k") { report in
            let value = try await slowWork(box)(report)
            box.set("finished")
            return value
        } }
        await wait { box.get("started") != nil }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        box.set("release")
        await wait { box.get("finished") != nil }
        #expect(box.get("cancelled") == nil)
        #expect(box.get("finished") != nil)
    }

    @Test func someoneWhoJoinsLateSeesTheProgress() async throws {
        let work = SharedWork<String>(), box = Box()
        let first = Task { try await work.run("k", slowWork(box)) }
        await wait { box.get("started") != nil }
        try await Task.sleep(nanoseconds: 20_000_000)
        let late = Task { try await work.run("k", progress: { box.set("seen", $0) }, slowWork(box)) }
        await wait { box.get("seen") != nil }
        #expect(box.get("seen") == 0.25)
        box.set("release")
        _ = try await (first.value, late.value)
    }

    @Test func aFailureReachesEveryoneAndTheNextRequestStartsAgain() async throws {
        struct Boom: Error {}
        let work = SharedWork<String>()
        await #expect(throws: Boom.self) { try await work.run("k") { _ in throw Boom() } }
        #expect(try await work.run("k") { _ in "again" } == "again")
    }

    @Test func aRequestAfterACancelStartsNewWork() async throws {
        let work = SharedWork<String>(), box = Box()
        let waiter = Task { try await work.run("k", progress: { _ in }, slowWork(box)) }
        await wait { box.get("started") != nil }
        waiter.cancel()
        _ = try? await waiter.value
        box.set("release")
        #expect(try await work.run("k", slowWork(box)) == "done")
        #expect(box.get("started") == 2)
    }

    @Test func anAlreadyCancelledCallerNeverStartsTheWork() async throws {
        let work = SharedWork<String>(), box = Box()
        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await work.run("k", progress: { _ in }, slowWork(box))
        }
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(box.get("started") == nil)
    }
}
