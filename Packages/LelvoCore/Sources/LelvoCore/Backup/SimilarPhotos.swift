import Foundation

/// Grouping near-identical photos (bursts, several shots of the same thing) for Duplicates review. Comparing pictures is
/// the slow part, so only photos taken close together in time are compared at all, and only with each other.
public enum SimilarPhotos {
    /// Photos further apart than this start a new run of candidates.
    public static let maxGap: TimeInterval = 60
    /// Feature-print distance (Vision) under which two photos count as the same shot.
    public static let maxDistance: Float = 0.35
    /// Runs longer than this are split, so one long shoot doesn't compare hundreds of photos with each other.
    public static let maxRun = 40

    public struct Candidate: Equatable, Sendable {
        public let id: String
        public let date: Date
        public let pixels: Int
        public let favorite: Bool

        public init(id: String, date: Date, pixels: Int, favorite: Bool) {
            self.id = id
            self.date = date
            self.pixels = pixels
            self.favorite = favorite
        }
    }

    /// Runs of at least two photos, each taken within `maxGap` of the one before, oldest first.
    public static func runs(_ candidates: [Candidate]) -> [[Candidate]] {
        var out: [[Candidate]] = []
        var run: [Candidate] = []
        func close() {
            if run.count > 1 {
                out += stride(from: 0, to: run.count, by: maxRun).map { Array(run[$0 ..< min($0 + maxRun, run.count)]) }.filter { $0.count > 1 }
            }
            run = []
        }
        for c in candidates.sorted(by: { $0.date < $1.date }) {
            if let last = run.last, c.date.timeIntervalSince(last.date) > maxGap { close() }
            run.append(c)
        }
        close()
        return out
    }

    /// Groups of a run whose photos are linked by distances under `maxDistance` (nil when two can't be compared).
    public static func groups(in run: [Candidate], distance: (Candidate, Candidate) -> Float?) -> [[Candidate]] {
        var parent = Array(run.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in run.indices {
            for j in run.indices where j > i {
                guard let d = distance(run[i], run[j]), d < maxDistance else { continue }
                parent[root(j)] = root(i)
            }
        }
        return Dictionary(grouping: run.indices, by: root).values
            .filter { $0.count > 1 }
            .map { $0.sorted().map { run[$0] } }
            .sorted { $0[0].date < $1[0].date }
    }

    /// The photo to suggest keeping: a favourite, else the largest, else the first taken.
    public static func best(_ group: [Candidate]) -> Candidate? {
        group.min { a, b in
            if a.favorite != b.favorite { return a.favorite }
            if a.pixels != b.pixels { return a.pixels > b.pixels }
            return a.date < b.date
        }
    }
}
