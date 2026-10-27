import Foundation
import Testing
import MemvoCore

@Suite struct PriorityGateTests {
    actor Recorder {
        var order: [String] = []
        func add(_ s: String) { order.append(s) }
    }

    /// Holds the only slot until released, so the jobs queued meanwhile run in the gate's order.
    actor Blocker {
        private var waiter: CheckedContinuation<Void, Never>?
        private var open = false
        func wait() async { if open { return }; await withCheckedContinuation { waiter = $0 } }
        func release() { open = true; waiter?.resume(); waiter = nil }
    }

    func run(_ jobs: [(key: String, urgent: Bool)], promote: String? = nil) async -> [String] {
        let gate = PriorityGate(limit: 1)
        let recorder = Recorder(), blocker = Blocker()
        let first = Task { try await gate.run(key: "first", urgent: true) { await blocker.wait() } }
        try? await Task.sleep(nanoseconds: 50_000_000)
        var tasks: [Task<Void, Error>] = []
        for job in jobs {
            tasks.append(Task { try await gate.run(key: job.key, urgent: job.urgent) { await recorder.add(job.key) } })
            try? await Task.sleep(nanoseconds: 20_000_000)  // queue them in this order
        }
        if let promote { await gate.promote(promote) }
        await blocker.release()
        _ = try? await first.value
        for t in tasks { _ = try? await t.value }
        return await recorder.order
    }

    @Test func onScreenBeforePrefetchAndNewestFirst() async {
        let order = await run([("old tile", true), ("prefetch", false), ("new tile", true)])
        #expect(order == ["new tile", "old tile", "prefetch"])
    }

    @Test func aPrefetchThatComesOnScreenRunsNext() async {
        let order = await run([("tile", true), ("prefetch a", false), ("prefetch b", false)], promote: "prefetch a")
        #expect(order == ["prefetch a", "tile", "prefetch b"])
    }

    @Test func neverRunsMoreThanTheLimit() async throws {
        let gate = PriorityGate(limit: 3)
        actor Count { var now = 0, most = 0; func enter() { now += 1; most = max(most, now) }; func leave() { now -= 1 } }
        let count = Count()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    try await gate.run(key: "\(i)", urgent: i % 2 == 0) {
                        await count.enter()
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        await count.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await count.most == 3)
    }
}
