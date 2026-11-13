import SwiftUI

/// Which Google product the Takeout guide is for. The steps are the same apart from the one thing to select.
enum TakeoutSource {
    case photos, drive

    var navigationTitle: String { self == .photos ? "Google Photos" : "Google Drive" }

    fileprivate var selectOnly: String { self == .photos ? "Google Photos" : "Drive" }
}

/// How to request a Takeout and bring it here. One guide for Photos and Drive; the import screen is shared.
struct TakeoutGuideView: View {
    var source: TakeoutSource

    private var steps: [String] {
        [
            "Open Google Takeout and sign in with the Google account that has your photos.",
            "Tap **Deselect all**, then select only **\(source.selectOnly)**.",
            "Choose **Send download link via email**, **Export once**, file type **.zip**, size **2 GB**.",
            "Wait for Google's email. It can take a few hours or a few days for a big library.",
            "Download the first zip into Files (or onto a USB drive or SD card if your phone is full).",
            "Come back here and tap **Choose files**.",
            "When Lelvo says a zip is done, delete it and download the next one.",
        ]
    }

    /// Said under the steps. The words are the ones in the design.
    private static let footer = "Wi-Fi recommended. Keep Lelvo open while it imports. Takeout links expire after 7 days, so download them in time. You can always request a new export."

    private var limits: [String] {
        [
            "Photos saved in Google's \"Storage saver\" quality are smaller copies, so they won't match the originals on this \(Device.name) and can appear twice. The Duplicates tool only catches exact copies.",
            "Google's export of edited photos is the edit only for some items. Whatever Google gives is imported.",
            "Pixel motion photos import as one JPEG with the video inside, shown as a still for now.",
            "A Live Photo or edited copy split across two zips imports as two separate items.",
        ]
    }

    var body: some View {
        Form {
            Section {
                Button {
                    if let url = URL(string: "https://takeout.google.com") { PlatformActions.open(url) }
                } label: {
                    Label("Open Google Takeout", systemImage: "arrow.up.right.square")
                }
            }

            Section {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    stepRow(index + 1, step)
                }
            } footer: {
                Text(Self.footer)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                NavigationLink { TakeoutImportView() } label: {
                    Text("Choose files")
                }
            }

            Section("Good to know") {
                ForEach(limits, id: \.self) { limit in
                    Text(limit)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .platformGroupedForm()
        .navigationTitle(source.navigationTitle)
    }

    private func stepRow(_ number: Int, _ markdown: String) -> some View {
        let plain = markdown.replacingOccurrences(of: "*", with: "")
        let styled = (try? AttributedString(markdown: markdown)) ?? AttributedString(plain)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).")
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(styled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(plain)")
    }
}
