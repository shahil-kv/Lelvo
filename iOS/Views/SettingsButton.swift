import SwiftUI

/// The gear at the top right of every tab, like the profile button in Google Photos: Settings opens as a sheet.
private struct SettingsButtonModifier: ViewModifier {
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showing = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showing) { SettingsView() }
    }
}

extension View {
    func settingsButton() -> some View { modifier(SettingsButtonModifier()) }
}
