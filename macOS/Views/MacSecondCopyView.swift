import SwiftUI
import UniformTypeIdentifiers
import LelvoCore

/// Settings → Second copy: keep the whole library in a folder the user owns, kept up to date on its own (#71).
struct MacSecondCopyView: View {
    @ObservedObject private var activity = SecondCopyActivity.shared
    @State private var picking = false
    @State private var confirmOff = false
    @State private var alert: GalleryAlert?
    private var env: AppEnvironment { AppEnvironment.shared }

    var body: some View {
        Form {
            Section {
                Label("Pick a folder on an external drive, a NAS or this Mac. Lelvo copies your whole library there and keeps it up to date.",
                      systemImage: "externaldrive.badge.checkmark")
                Label("Originals with their real names, plus edited versions and Live Photo videos, in Year/Month folders.",
                      systemImage: "doc.on.doc")
                Label("Encrypted items are decrypted, so the copy opens anywhere.", systemImage: "lock.open")
                Label("Nothing is ever deleted from the copy, even when you delete a photo from your library.", systemImage: "trash.slash")
            } footer: {
                Text("Two copies in two places: your Telegram library and a drive you own.")
            }
            .font(.subheadline)

            Section {
                if activity.phase == .off && !env.secondCopy.isOn {
                    Button { picking = true } label: { Label("Choose a folder", systemImage: "folder.badge.plus") }
                } else {
                    LabeledContent("Folder", value: activity.folderName ?? Prefs.secondCopyVolume ?? "…")
                    status
                    HStack {
                        Button("Copy now") { env.secondCopy.syncNow() }
                            .disabled(activity.phase == .copying || activity.phase == .checking)
                        Button("Change folder…") { picking = true }
                        Spacer()
                        Button("Turn off", role: .destructive) { confirmOff = true }
                    }
                }
            } header: {
                Text("Keep a second copy")
            } footer: {
                if activity.removedFromLibrary > 0 {
                    Text("\(activity.removedFromLibrary.formatted()) items you deleted from your library are still in the folder. Lelvo never removes them.")
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            do { try env.secondCopy.choose(url) } catch {
                alert = GalleryAlert(title: "Couldn't use that folder", message: error.localizedDescription)
            }
        }
        .alert("Turn off the second copy?", isPresented: $confirmOff) {
            Button("Cancel", role: .cancel) {}
            Button("Turn Off", role: .destructive) { env.secondCopy.turnOff() }
        } message: {
            Text("Lelvo stops copying new photos. Everything already in the folder stays there.")
        }
        .alert(item: $alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        .task { if env.secondCopy.isOn { env.secondCopy.syncNow() } }
    }

    @ViewBuilder private var status: some View {
        switch activity.phase {
        case .off, .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the folder…").foregroundStyle(.secondary) }
        case .copying:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(activity.files), total: Double(max(activity.files + activity.left, 1)))
                Text("\(activity.left.formatted()) left to copy, \(Format.bytes(activity.leftBytes))")
                    .font(.subheadline.monospacedDigit())
                if let current = activity.current {
                    Text(current).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        case .upToDate:
            Label("Up to date, \(activity.files.formatted()) files, \(Format.bytes(activity.bytes))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .paused:
            Label(activity.message ?? "Paused.", systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
        case .needsSpace:
            Label(activity.message ?? "The drive is almost full.", systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
        case .failed:
            Label(activity.message ?? "Some files couldn't be copied. Lelvo tries again in a few minutes.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
