import Foundation

/// One piece of slow work per key, shared by everyone who asks for it while it runs. A plain `Task` per key can't be
/// cancelled by the people waiting on it, so a Cancel button did nothing until the work ended.
///
/// A waiter that cancels returns at once. The work itself stops only if that waiter was the last one left and was
/// following the progress: someone who asked to follow it decided to stop it. A waiter without a progress handler
/// (loading ahead, a page swiped away) leaves the work running, so its result still reaches the caller's cache.
public final class SharedWork<Value: Sendable>: @unchecked Sendable {
    public typealias Progress = @Sendable (Double) -> Void

    private final class Entry {
        var task: Task<Void, Never>?
        var waiters: [UUID: Waiter] = [:]
        var latest: Double?
    }

    private struct Waiter {
        let continuation: CheckedContinuation<Value, Error>
        let progress: Progress?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    public func run(_ key: String, progress: Progress? = nil,
                    _ body: @escaping @Sendable (@escaping Progress) async throws -> Value) async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                join(key, id: id, waiter: Waiter(continuation: continuation, progress: progress), body)
            }
        } onCancel: {
            leave(key, id: id)
        }
    }

    private func join(_ key: String, id: UUID, waiter: Waiter,
                      _ body: @escaping @Sendable (@escaping Progress) async throws -> Value) {
        lock.lock()
        // Checked inside the lock: a cancel from here on waits for it, then finds this waiter in `leave`.
        if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) {
            lock.unlock()
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        if let entry = entries[key] {
            entry.waiters[id] = waiter
            let latest = entry.latest
            lock.unlock()
            if let latest { waiter.progress?(latest) }
            return
        }
        let entry = Entry()
        entry.waiters[id] = waiter
        entries[key] = entry
        entry.task = Task { [weak self] in
            let result: Result<Value, Error>
            do {
                result = .success(try await body { [weak self] in self?.report($0, key: key, entry: entry) })
            } catch {
                result = .failure(error)
            }
            self?.finish(key, entry: entry, result)
        }
        lock.unlock()
    }

    private func leave(_ key: String, id: UUID) {
        lock.lock()
        guard let entry = entries[key], let waiter = entry.waiters.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        let stop = entry.waiters.isEmpty && waiter.progress != nil
        if stop { entries[key] = nil }
        let task = entry.task
        lock.unlock()
        waiter.continuation.resume(throwing: CancellationError())
        if stop { task?.cancel() }
    }

    private func report(_ value: Double, key: String, entry: Entry) {
        lock.lock()
        entry.latest = value
        let handlers = entry.waiters.values.compactMap(\.progress)
        lock.unlock()
        for handler in handlers { handler(value) }
    }

    private func finish(_ key: String, entry: Entry, _ result: Result<Value, Error>) {
        lock.lock()
        // A stopped entry may already have been replaced by a new request for the same key.
        if entries[key] === entry { entries[key] = nil }
        let waiters = Array(entry.waiters.values)
        entry.waiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.continuation.resume(with: result) }
    }
}
