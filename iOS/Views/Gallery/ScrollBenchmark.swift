import UIKit
import LelvoCore

#if DEBUG
/// `-autoScrollTest`: scrolls the main grid top to bottom twice (cold, then warm) in 4 s each, at display rate,
/// and logs frame timing, hitches and memory. Works for either grid (it drives the underlying UIScrollView).
@MainActor
enum ScrollBenchmark {
    static var engine: String { "native" }

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-autoScrollTest") else { return }
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await Driver.run(pass: "cold")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await Driver.run(pass: "warm")
            try? await Task.sleep(nanoseconds: 500_000_000)
            exit(0)
        }
    }

    private static func gridScrollView() -> UIScrollView? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var best: UIScrollView?
        func walk(_ v: UIView) {
            if let s = v as? UIScrollView, s.contentSize.height > (best?.contentSize.height ?? 0) { best = s }
            v.subviews.forEach(walk)
        }
        windows.forEach(walk)
        return best
    }

    @MainActor private final class Driver: NSObject {
        private let scroll: UIScrollView
        private var link: CADisplayLink?
        private var start: CFTimeInterval = 0
        private var last: CFTimeInterval = 0
        private var gaps: [Double] = []
        private var nominal: Double = 1.0 / 60
        private var done: CheckedContinuation<Void, Never>?
        private let pass: String

        init(scroll: UIScrollView, pass: String) { self.scroll = scroll; self.pass = pass }

        static func run(pass: String) async {
            guard let scroll = ScrollBenchmark.gridScrollView() else { appLog("Benchmark: no grid"); return }
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let d = Driver(scroll: scroll, pass: pass)
            await withCheckedContinuation { cont in
                d.done = cont
                let link = CADisplayLink(target: d, selector: #selector(Driver.tick(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
                link.add(to: .main, forMode: .common)
                d.link = link
            }
        }

        @objc func tick(_ link: CADisplayLink) {
            if start == 0 { start = link.timestamp; last = link.timestamp; nominal = link.targetTimestamp - link.timestamp; return }
            gaps.append(link.timestamp - last)
            last = link.timestamp
            let t = min(1, (link.timestamp - start) / 4)
            let maxY = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
            scroll.contentOffset.y = -scroll.adjustedContentInset.top + (maxY + scroll.adjustedContentInset.top) * t
            guard t >= 1 else { return }
            link.invalidate()
            let sorted = gaps.sorted()
            let hitches = gaps.filter { $0 > nominal * 1.5 }.count
            let dropped = gaps.reduce(0) { $0 + max(0, Int(($1 / nominal).rounded()) - 1) }
            let ms = { (v: Double) in String(format: "%.1f", v * 1000) }
            appLog("Benchmark \(ScrollBenchmark.engine) \(pass): items \(ScrollBenchmark.itemCount) frames \(gaps.count) nominal \(ms(nominal)) ms avg \(ms(gaps.reduce(0, +) / Double(gaps.count))) p95 \(ms(sorted[Int(Double(sorted.count) * 0.95)])) max \(ms(sorted.last ?? 0)) hitches \(hitches) dropped \(dropped) memory \(ScrollBenchmark.memoryMB) MB")
            done?.resume()
            done = nil
        }
    }

    static var itemCount: Int { ((try? AppEnvironment.shared.store.counts()) ?? [:]).values.reduce(0, +) }

    static var memoryMB: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}
#endif
