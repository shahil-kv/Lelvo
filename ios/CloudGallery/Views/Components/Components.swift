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

/// What a gallery tile represents relative to the cloud.
enum BackupBadge: Equatable {
    case phoneOnly, uploading, backedUp, cloudOnly, tooLarge, viewNeedsV2, failed

    var symbol: String {
        switch self {
        case .phoneOnly: return "iphone"
        case .uploading: return "arrow.up.circle"
        case .backedUp: return "checkmark.icloud.fill"
        case .cloudOnly: return "icloud.fill"
        case .tooLarge: return "exclamationmark.triangle.fill"
        case .viewNeedsV2: return "icloud.slash"
        case .failed: return "exclamationmark.icloud.fill"
        }
    }

    var label: String {
        switch self {
        case .phoneOnly: return "On phone only"
        case .uploading: return "Uploading"
        case .backedUp: return "Backed up"
        case .cloudOnly: return "In cloud only"
        case .tooLarge: return "Not backed up"
        case .viewNeedsV2: return "Backed up (legacy bot upload)"
        case .failed: return "Backup failed, will retry"
        }
    }

    var tint: Color {
        switch self {
        case .phoneOnly: return .white
        case .uploading: return .white
        case .backedUp: return .white
        case .cloudOnly: return .cyan
        case .tooLarge: return .orange
        case .viewNeedsV2: return .yellow
        case .failed: return .red
        }
    }
}

struct BadgeView: View {
    let badge: BackupBadge
    var body: some View {
        Image(systemName: badge.symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(badge.tint)
            .padding(3)
            .background(.black.opacity(0.45), in: Circle())
            .accessibilityLabel(badge.label)
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
