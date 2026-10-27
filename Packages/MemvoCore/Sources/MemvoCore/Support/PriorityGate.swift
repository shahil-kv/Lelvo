import Foundation

/// Runs at most `limit` jobs at once and picks the next one the way image grids should: urgent jobs (tiles on screen)
/// before background ones (prefetch), and the newest first within each, because the newest request is what's on
/// screen now. First come, first served made a quick zoom out to the yearly grid queue ~170 thumbnails, and the tiles
/// on screen after zooming back in waited behind all of them.
public actor PriorityGate {
    private let limit: Int
    private var active = 0
    private var urgent: [(key: String, resume: CheckedContinuation<Void, Never>)] = []
    private var background: [(key: String, resume: CheckedContinuation<Void, Never>)] = []

    public init(limit: Int) { self.limit = limit }

    public func run<T: Sendable>(key: String, urgent isUrgent: Bool, _ body: @Sendable () async throws -> T) async throws -> T {
        if active < limit {
            active += 1
        } else {
            await withCheckedContinuation { c in
                if isUrgent { urgent.append((key, c)) } else { background.append((key, c)) }
            }
        }
        defer { next() }
        return try await body()
    }

    /// A background job for `key` became urgent (its tile came on screen while its prefetch waited): run it next.
    public func promote(_ key: String) {
        guard let i = background.lastIndex(where: { $0.key == key }) else { return }
        urgent.append(background.remove(at: i))
    }

    /// Hands the free slot to the next job, or frees it.
    private func next() {
        if let job = urgent.popLast() ?? background.popLast() { job.resume.resume() } else { active -= 1 }
    }
}
