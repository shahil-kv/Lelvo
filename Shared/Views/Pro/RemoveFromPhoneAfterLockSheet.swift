import SwiftUI
import LelvoCore

/// After locking green (backed-up) photos: optional Free Up–safe delete from Photos / This Mac only.
/// Copy stresses Lelvo + Telegram keep the files so “remove from phone” isn’t read as losing the photo.
struct RemoveFromPhoneAfterLockSheet: View {
    let entries: [GalleryEntry]
    var onKeep: () -> Void
    var onDeleteFromPhotos: () -> Void

    private static let previewCount = 5

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 14)

            Text("Free space on this \(Device.name)?")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Text(explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 8)

            previewRow
                .padding(.vertical, 18)

            VStack(spacing: 10) {
                Button(action: onKeep) {
                    Text("Keep in Photos")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive, action: onDeleteFromPhotos) {
                    Text("Delete from Photos app only")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            Text("Your Locked Folder and Telegram library are untouched.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
        #if os(iOS)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        #endif
    }

    private var explanation: String {
        let n = entries.count
        let count = n == 1 ? "This photo is" : "These \(n.formatted()) photos are"
        return "\(count) already backed up (green) and hidden in Lelvo. Deleting from Photos frees space on this \(Device.name) only — the copies in Lelvo and Telegram stay."
    }

    private var previewRow: some View {
        let shown = Array(entries.prefix(Self.previewCount))
        let extra = entries.count - shown.count
        return HStack(spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                ZStack {
                    SheetThumb(entry: entry)
                    if index == shown.count - 1, extra > 0 {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.black.opacity(0.45))
                        Text("+\(extra.formatted())")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 56, height: 56)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entries.count.formatted()) photos")
    }

    /// Green / on-phone backed-up only. Phone-only or uploading never triggers this sheet.
    static func removable(_ entries: [GalleryEntry]) -> [GalleryEntry] {
        entries.filter { $0.badge == .backedUp && $0.asset != nil && $0.item?.localIdentifier != nil }
    }

    static func mediaItems(from entries: [GalleryEntry]) -> [MediaItem] {
        entries.compactMap(\.item)
    }
}

private struct SheetThumb: View {
    let entry: GalleryEntry
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                #if os(iOS)
                Image(uiImage: image).resizable().scaledToFill()
                #else
                Image(nsImage: image).resizable().scaledToFill()
                #endif
            } else {
                #if os(iOS)
                Color(.secondarySystemFill)
                #else
                Color(nsColor: .controlBackgroundColor)
                #endif
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: entry.id) {
            for await img in ThumbnailPipeline.shared.images(for: entry, pixels: 160) {
                image = img
            }
        }
    }
}
