import Foundation
import Testing
import MemvoCore

@Suite struct DeadlineTests {
    @Test func returnsTheResultInTime() async throws {
        #expect(try await withDeadline(seconds: 5) { 42 } == 42)
    }

    @Test func passesOnTheOperationsError() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await withDeadline(seconds: 5) { throw Boom() } }
    }

    /// The case that hung video playback: a wait that never ends and ignores cancellation.
    @Test func givesUpOnAnOperationThatIgnoresCancellation() async {
        let started = Date()
        await #expect(throws: DeadlineExceeded(seconds: 0.2)) {
            try await withDeadline(seconds: 0.2) { () -> Int in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }  // never resumes
                return 1
            }
        }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func cancellingTheCallerStopsWaiting() async {
        let task = Task {
            try await withDeadline(seconds: 30) { () -> Int in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return 1
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
