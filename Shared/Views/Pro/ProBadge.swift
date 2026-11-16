import SwiftUI

/// Gold “PRO” pill (Ente-style). Marks Pro features in Collections, Settings, paywall and Locked Folder.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.caption2.weight(.heavy))
            .tracking(0.5)
            .foregroundStyle(Color(red: 0.24, green: 0.18, blue: 0.02))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.96, green: 0.84, blue: 0.43),
                        Color(red: 0.79, green: 0.64, blue: 0.15),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .accessibilityLabel("Pro")
    }
}

extension View {
    /// Title + gold PRO pill, for navigation bars and section headers.
    func proTitle(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            ProBadge()
        }
    }
}
