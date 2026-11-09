import SwiftUI

/// The gear at the top right of every tab, like the profile button in Google Photos: Settings opens as a sheet.
private struct SettingsButtonModifier: ViewModifier {
    /// Hidden while selecting photos, so the top bar holds only ••• and close, like Photos.
    var hidden = false
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                if !hidden {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showing = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Settings")
                    }
                }
            }
            // Its own toast host: the one under the tabs is hidden behind the sheet.
            .sheet(isPresented: $showing) { SettingsView().toastHost() }
    }
}

extension View {
    func settingsButton(hidden: Bool = false) -> some View { modifier(SettingsButtonModifier(hidden: hidden)) }
}
