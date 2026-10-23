import SwiftUI
import UIKit
import CloudGalleryCore

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func date(_ date: Date?, style: DateFormatter.Style = .medium, time: DateFormatter.Style = .short) -> String {
        guard let date else { return "Unknown date" }
        return DateFormatter.localizedString(from: date, dateStyle: style, timeStyle: time)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "never" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

/// Where a tile lives (phone, cloud, or both). Icons follow Google Photos: cloud-with-slash = not backed up,
/// spinning ring = uploading, red cloud = failed.
enum BackupBadge: Equatable, CaseIterable {
    case backedUp, phoneOnly, cloudOnly, waiting, uploading, failed, tooLarge, viewNeedsV2

    var symbol: String {
        switch self {
        case .backedUp: return "checkmark.icloud.fill"
        case .phoneOnly: return "icloud.slash.fill"
        case .cloudOnly: return "icloud.fill"
        case .waiting: return "clock.fill"
        case .uploading: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.icloud.fill"
        case .tooLarge: return "exclamationmark.triangle.fill"
        case .viewNeedsV2: return "archivebox.fill"
        }
    }

    var label: String {
        switch self {
        case .backedUp: return "On iPhone and in the cloud"
        case .phoneOnly: return "Only on this iPhone"
        case .cloudOnly: return "Only in the cloud"
        case .waiting: return "Waiting to upload"
        case .uploading: return "Uploading now"
        case .failed: return "Backup failed"
        case .tooLarge: return "Too large to back up"
        case .viewNeedsV2: return "In the old 1.0 channel"
        }
    }

    /// One-line explanation for the legend.
    var explanation: String {
        switch self {
        case .backedUp: return "Safe: on this iPhone and verified in your Telegram library."
        case .phoneOnly: return "Not backed up. It isn't in your backup selection (Settings) or isn't queued yet."
        case .cloudOnly: return "Not on this iPhone (deleted here or from another device). Opens from Telegram."
        case .waiting: return "Queued. It uploads on the next backup run."
        case .uploading: return "Being uploaded right now."
        case .failed: return "The upload didn't go through. Backup → Failed shows why; tap Retry."
        case .tooLarge: return "Larger than Telegram allows, so it stays on this iPhone only."
        case .viewNeedsV2: return "Uploaded by CloudGallery 1.0 (bot); it stays in the old channel."
        }
    }

    var tint: Color {
        switch self {
        case .backedUp: return .green
        case .phoneOnly: return .white
        case .cloudOnly: return .cyan
        case .waiting: return .white
        case .uploading: return .blue
        case .failed: return .red
        case .tooLarge: return .orange
        case .viewNeedsV2: return .yellow
        }
    }
}

struct BadgeView: View {
    let badge: BackupBadge
    var body: some View {
        icon
            .font(.caption2.weight(.bold))
            .foregroundStyle(badge.tint)
            .padding(3)
            .background(.black.opacity(0.55), in: Circle())
            .accessibilityLabel(badge.label)
    }

    @ViewBuilder private var icon: some View {
        if badge == .uploading, #available(iOS 18.0, *) {
            Image(systemName: badge.symbol).symbolEffect(.rotate, options: .repeat(.continuous))
        } else {
            Image(systemName: badge.symbol)
        }
    }
}

/// What each tile icon means (Photos menu).
struct BadgeLegendView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(BackupBadge.allCases, id: \.self) { badge in
                HStack(alignment: .top, spacing: 14) {
                    BadgeView(badge: badge).scaleEffect(1.5).frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(badge.label).font(.subheadline.weight(.semibold))
                        Text(badge.explanation).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            .navigationTitle("What the icons mean")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
    }
}

/// UIActivityViewController for sharing files.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
}

enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}
