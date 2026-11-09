import SwiftUI
import LelvoCore

/// Progress and result messages shown as a floating pill, so a tap always answers, also when there is nothing to do.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    struct Toast: Equatable {
        enum Style { case progress, success, failure, info }
        var style: Style
        var title: String
        var detail: String?
        var progress: Double?
        var canStop = false
    }

    @Published private(set) var current: Toast?
    private var hideTask: Task<Void, Never>?
    private var stoppable: Task<Void, Never>?

    func progress(_ title: String, detail: String? = nil, fraction: Double? = nil) {
        hideTask?.cancel()
        current = Toast(style: .progress, title: title, detail: detail, progress: fraction, canStop: stoppable != nil)
    }

    /// Moves the bar of the progress on screen. Does nothing once it's gone, so a late update can't bring it back.
    func update(fraction: Double) {
        guard current?.style == .progress else { return }
        current?.progress = fraction
    }

    /// Runs slow work whose progress pill offers a stop button. Cancelling reaches `work` as task cancellation.
    func runStoppable(_ work: @escaping @MainActor () async -> Void) async {
        let task = Task { @MainActor in await work() }
        stoppable = task
        await task.value
        if stoppable == task { stoppable = nil }
    }

    func stop() {
        stoppable?.cancel()
        stoppable = nil
        dismiss()
    }

    func show(_ style: Toast.Style, _ title: String, detail: String? = nil, seconds: Double = 3.5) {
        hideTask?.cancel()
        current = Toast(style: style, title: title, detail: detail)
        AccessibilityNotification.Announcement([title, detail].compactMap { $0 }.joined(separator: ". ")).post()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            current = nil
        }
    }

    func dismiss() {
        hideTask?.cancel()
        current = nil
    }
}

struct ToastView: View {
    let toast: ToastCenter.Toast
    var stop: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            switch toast.style {
            case .progress:
                if let p = toast.progress { ProgressView(value: p).progressViewStyle(.circular).controlSize(.small) }
                else { ProgressView().controlSize(.small) }
            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
            case .failure: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
            case .info: Image(systemName: "info.circle.fill").foregroundStyle(.tint).font(.title3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title).font(.callout.weight(.semibold))
                if let detail = toast.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            if toast.canStop {
                Button(action: stop) {
                    Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .frame(maxWidth: 520)
    }
}

private struct ToastHost: ViewModifier {
    @ObservedObject private var center = ToastCenter.shared
    @GestureState private var drag: CGFloat = 0
    let bottomPadding: CGFloat

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = center.current {
                // Swipe and tap to dismiss apply while it takes touches: only a message with a Stop button does, so
                // others never block what's under them.
                let dismissable = toast.style != .progress
                ToastView(toast: toast) { center.stop() }
                    .padding(.horizontal, 16)
                    .padding(.bottom, bottomPadding)
                    .offset(y: max(0, drag))
                    .gesture(DragGesture(minimumDistance: 6)
                        .updating($drag) { value, state, _ in state = value.translation.height }
                        .onEnded { value in
                            if value.translation.height > 24 || value.predictedEndTranslation.height > 60 { center.dismiss() }
                        }, including: dismissable ? .all : .subviews)
                    .onTapGesture { if dismissable { center.dismiss() } }
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .opacity.combined(with: .scale(scale: 0.96))))
                    // Only a toast with a Stop button takes touches; others let taps through to the buttons under them
                    // (the floating selection bar sits right there), and still go away on their own.
                    .allowsHitTesting(toast.canStop)
            }
        }
        .motion(Motion.standard, value: center.current)
    }
}

extension View {
    /// Shows `ToastCenter.shared` over this view.
    func toastHost(bottomPadding: CGFloat = 18) -> some View { modifier(ToastHost(bottomPadding: bottomPadding)) }
}

/// "Re-scan the Telegram library": reads the channel and says what it found, also when that's nothing new.
@MainActor
enum LibraryRescan {
    private(set) static var isRunning = false

    /// Returns when the scan is over. A tap while one runs only brings its progress back on screen.
    static func run() async {
        let toast = ToastCenter.shared
        toast.progress("Checking your Telegram library…")
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let env = AppEnvironment.shared
        if DemoMode.isActive {
            let count = await Task.detached { (try? env.store.allItems().count) ?? 0 }.value
            let report = RescanReport(itemsBefore: count, itemsAfter: count, incomplete: 0, duplicates: 0)
            toast.show(.success, report.title, detail: report.detail)
            Haptics.success()
            return
        }
        let before = await Task.detached { (try? env.store.allItems().count) ?? 0 }.value
        do {
            let summary = try await env.library.scan(full: true) { read in
                // A late hop must not replace the result.
                Task { @MainActor in
                    if isRunning { toast.progress("Checking your Telegram library…", detail: "\(read.formatted()) messages read") }
                }
            }
            let after = await Task.detached {
                env.engine.relinkRestoredItems()
                return (try? env.store.allItems().count) ?? 0
            }.value
            let report = RescanReport(itemsBefore: before, itemsAfter: after, incomplete: summary.incomplete, duplicates: summary.orphans.count)
            toast.show(report.upToDate ? .success : .info, report.title, detail: report.detail)
            Haptics.success()
        } catch {
            toast.show(.failure, "Couldn't check your Telegram library", detail: error.localizedDescription, seconds: 5)
            Haptics.error()
        }
    }
}
