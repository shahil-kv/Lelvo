import SwiftUI

/// Which Google product the Takeout guide is for. The steps are the same apart from the one thing to select.
enum TakeoutSource {
    case photos, drive

    var navigationTitle: String { self == .photos ? "Google Photos" : "Google Drive" }

    fileprivate var selectOnly: String { self == .photos ? "Google Photos" : "Drive" }
}

/// How to request a Takeout and bring it here, in three short steps. Choose files stays on screen at the bottom.
struct TakeoutGuideView: View {
    var source: TakeoutSource
    @ObservedObject private var importer = AppEnvironment.shared.importer
    @State private var showsDetails = false
    @State private var destination: Destination?

    /// The import screen, with the files just picked in Files (if any).
    private struct Destination: Hashable {
        var urls: [URL]
        var fresh: Bool
    }

    private struct Step: Identifiable {
        var id: Int
        var title: String
        var text: String
    }

    private var steps: [Step] {
        [
            Step(id: 1, title: "Ask Google for a copy",
                 text: "In Google Takeout, tap **Deselect all** and select only **\(source.selectOnly)**. Choose **.zip** and **2 GB**, then create the export."),
            Step(id: 2, title: "Download the zips",
                 text: "Google emails you when it's ready, in a few hours or days. Save the first zip in Files. The links last 7 days."),
            Step(id: 3, title: "Import here",
                 text: "Tap **Choose files** and pick the zip. When it's done, delete it and add the next one."),
        ]
    }

    private var limits: [String] {
        [
            "Photos saved in Google's \"Storage saver\" quality are smaller copies, so they won't match the originals on this \(Device.name) and can appear twice.",
            "For some edited photos Google only exports the edit. Whatever Google gives is imported.",
            "Pixel motion photos import as a still for now.",
            "A Live Photo split across two zips imports as two items.",
        ]
    }

    var body: some View {
        Form {
            Section {
                ForEach(steps) { step in
                    stepRow(step)
                }
                Button {
                    if let url = URL(string: "https://takeout.google.com") { PlatformActions.open(url) }
                } label: {
                    Label("Open Google Takeout", systemImage: "arrow.up.right.square")
                }
            } footer: {
                Text("Use Wi-Fi and keep Lelvo open while it imports.")
            }

            Section {
                DisclosureGroup("Good to know", isExpanded: $showsDetails) {
                    ForEach(limits, id: \.self) { limit in
                        Text(limit)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .platformGroupedForm()
        .navigationTitle(source.navigationTitle)
        .safeAreaInset(edge: .bottom) {
            Button(action: mainAction) {
                Text(importer.guideAction.title)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .navigationDestination(item: $destination) { target in
            TakeoutImportView(pending: target.urls, fresh: target.fresh)
        }
    }

    /// Choose files opens Files straight away; the import screen opens once something is picked.
    private func mainAction() {
        #if DEBUG
        if TakeoutFixture.enabled {
            destination = Destination(urls: [], fresh: false)
            return
        }
        #endif
        let action = importer.guideAction
        if action == .continueImport {
            destination = Destination(urls: [], fresh: false)
            return
        }
        TakeoutFilePicker.choose { urls in
            guard !urls.isEmpty else { return }
            if case .choose(let fresh) = action {
                destination = Destination(urls: urls, fresh: fresh)
            } else {
                destination = Destination(urls: urls, fresh: false)
            }
        }
    }

    private func stepRow(_ step: Step) -> some View {
        let plain = step.text.replacingOccurrences(of: "*", with: "")
        let styled = (try? AttributedString(markdown: step.text)) ?? AttributedString(plain)
        return HStack(alignment: .top, spacing: 12) {
            Text("\(step.id)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.tint))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(.headline)
                Text(styled)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(step.id). \(step.title). \(plain)")
    }
}
