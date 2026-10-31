import Foundation

public struct DeadlineExceeded: Error, Equatable {
    public let seconds: TimeInterval
    public init(seconds: TimeInterval) { self.seconds = seconds }
}

/// Runs `operation` and gives up after `seconds`, even when it is stuck in a call that ignores cancellation (TDLib
/// requests do: a synchronous download waits until its bytes arrive, however long that takes). A task group can't do
/// this, because it waits for every child before it returns. On timeout the operation is cancelled and left to finish
/// on its own; its result is dropped.
public func withDeadline<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = ResumeOnce<T>()
    let work = Task { await once.resume(with: await Result(catching: operation)) }
    let timer = Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await once.resume(with: .failure(DeadlineExceeded(seconds: seconds)))
    }
    return try await withTaskCancellationHandler {
        defer {
            work.cancel()
            timer.cancel()
        }
        return try await once.value()
    } onCancel: {
        work.cancel()
        Task { await once.resume(with: .failure(CancellationError())) }
    }
}

/// The first result wins; later ones are ignored.
private actor ResumeOnce<T: Sendable> {
    private var result: Result<T, Error>?
    private var waiter: CheckedContinuation<T, Error>?

    func resume(with r: Result<T, Error>) {
        guard result == nil else { return }
        result = r
        waiter?.resume(with: r)
        waiter = nil
    }

    func value() async throws -> T {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
