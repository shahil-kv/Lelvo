import SwiftUI
import MapKit
import Photos
import CloudGalleryCore

/// The ⌘I inspector: details, backup state and location of the item in the viewer or the selection.
struct MacInfoPanel: View {
    let entries: [GalleryEntry]

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView("No Selection", systemImage: "info.circle",
                                       description: Text("Select a photo or video to see its details."))
            } else if entries.count == 1, let entry = entries.first {
                SingleInfo(entry: entry).id(entry.id)
            } else {
                MultipleInfo(entries: entries)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SingleInfo: View {
    let entry: GalleryEntry
    @State private var resourceName: String?
    @State private var resourceSize: Int64?

    private var coordinate: CLLocationCoordinate2D? {
        if let loc = entry.asset?.location { return loc.coordinate }
        if let lat = entry.item?.latitude, let lon = entry.item?.longitude { return CLLocationCoordinate2D(latitude: lat, longitude: lon) }
        return nil
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.item?.filename ?? resourceName ?? "—")
                        .font(.headline)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Text(Format.date(entry.date, style: .full, time: .short))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            Section("Details") {
                let w = entry.asset?.pixelWidth ?? entry.item?.pixelWidth ?? 0
                let h = entry.asset?.pixelHeight ?? entry.item?.pixelHeight ?? 0
                LabeledContent("Kind", value: entry.isVideo ? "Video" : (entry.isLive ? "Live Photo" : "Photo"))
                if w > 0 {
                    LabeledContent("Dimensions", value: "\(w) × \(h)")
                    if !entry.isVideo { LabeledContent("Resolution", value: String(format: "%.1f MP", Double(w * h) / 1_000_000)) }
                }
                if let size = entry.item.map({ $0.fileSize + ($0.pairedVideoSize ?? 0) }) ?? resourceSize {
                    LabeledContent("Size", value: Format.bytes(size))
                }
                if entry.isVideo, let d = entry.duration {
                    LabeledContent("Duration", value: Duration.seconds(d).formatted(.time(pattern: .minuteSecond)))
                }
                if let codec = entry.item?.codec { LabeledContent("Codec", value: codec.uppercased()) }
                if let hdr = entry.item?.hdr, hdr > 0 { LabeledContent("Dynamic range", value: hdr == 2 ? "Dolby Vision" : "HDR") }
            }
            Section("Backup") {
                Label { Text(entry.badge.label) } icon: { Image(systemName: entry.badge.symbol).foregroundStyle(entry.badge.listTint) }
                if let item = entry.item {
                    if let up = item.uploadedAt { LabeledContent("Uploaded", value: Format.date(up)) }
                    if let v = item.verifiedAt { LabeledContent("Verified", value: Format.relative(v)) }
                    if item.encrypted { Label("End-to-end encrypted", systemImage: "lock.fill") }
                    if let e = item.lastError { Text(e).font(.callout).foregroundStyle(.orange) }
                }
            }
            if let coordinate {
                Section("Location") {
                    Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 2000, longitudinalMeters: 2000))) {
                        Marker("", coordinate: coordinate)
                    }
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    LabeledContent("Coordinates", value: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            guard entry.item == nil, let asset = entry.asset else { return }
            let resource = PHAssetResource.assetResources(for: asset).first
            resourceName = resource?.originalFilename
            resourceSize = (resource?.value(forKey: "fileSize") as? NSNumber)?.int64Value
        }
    }
}

private struct MultipleInfo: View {
    let entries: [GalleryEntry]

    var body: some View {
        let videos = entries.filter(\.isVideo).count
        let cloudBytes = entries.compactMap(\.item).reduce(Int64(0)) { $0 + $1.fileSize + ($1.pairedVideoSize ?? 0) }
        let byBadge = Dictionary(grouping: entries, by: \.badge).mapValues(\.count)
        Form {
            Section {
                Text("\(entries.count.formatted()) items selected").font(.headline)
                LabeledContent("Photos", value: (entries.count - videos).formatted())
                LabeledContent("Videos", value: videos.formatted())
                if cloudBytes > 0 { LabeledContent("Size in backup", value: Format.bytes(cloudBytes)) }
            }
            Section("Backup") {
                ForEach(BackupBadge.allCases.filter { byBadge[$0] != nil }, id: \.self) { badge in
                    LabeledContent {
                        Text((byBadge[badge] ?? 0).formatted()).monospacedDigit()
                    } label: {
                        Label { Text(badge.label) } icon: { Image(systemName: badge.symbol).foregroundStyle(badge.listTint) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
