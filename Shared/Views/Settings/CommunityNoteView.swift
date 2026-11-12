import SwiftUI

/// Once, a moment after the photos first show: Lelvo collects nothing, so it can't see what goes wrong or reach
/// anyone. The founder asks people to tell him in the Lelvo group. Never during setup, never in the demo (App Review).
struct CommunityNoteView: View {
    let onClose: () -> Void
    /// The content's height, so the sheet can be just that tall instead of the whole screen.
    var onHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                Text("Found a bug? Tell me")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Group {
                    Text("Lelvo collects nothing.").foregroundStyle(.primary).fontWeight(.medium)
                        + Text(" No account with us, no analytics, no tracking. That keeps your photos private, but it also means we never see when something goes wrong, and we have no way to reach you.")
                    Text("So tell us. Join the Lelvo group on Telegram to report a bug or ask for a feature. I read every message myself, reply, and fix what you find fast.")
                    Text("No ads or promotions there. Only updates and your questions.")
                }
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text("\(AppLinks.developerName), founder")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                VStack(spacing: 4) {
                    Button {
                        PlatformActions.open(AppLinks.community)
                        onClose()
                    } label: {
                        Text("Join the Lelvo group").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    Button("Not now", action: onClose)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .padding(.top, 4)
            }
            .padding(24)
            .background(GeometryReader { g in Color.clear.preference(key: NoteHeight.self, value: g.size.height) })
        }
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(NoteHeight.self) { onHeight($0) }
        // Sheets don't always pick up the app's accent colour; Lelvo's purple, not the system blue.
        .tint(Color("AccentColor"))
    }
}

private struct NoteHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
