import SwiftUI
import CloudGalleryCore

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UITestSupport.prepareIfNeeded()
        #if DEBUG
        DebugHooks.install()
        #endif
        BackgroundTasks.register()
        AppEnvironment.shared.td.start()
        if Prefs.onboardingComplete { BackgroundTasks.scheduleAll() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let env = AppEnvironment.shared
        env.originalsCache.flush()
        env.thumbnailCache.flush()
    }

    /// Like Photos: closing the window keeps backups (and the menu bar status) running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct CloudGalleryMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @StateObject private var navigation = MacNavigation.shared
    @AppStorage(MacPrefs.showMenuBarExtra) private var showMenuBarExtra = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("CloudGallery", id: MacNavigation.mainWindowId) {
            MacRootView()
                .environmentObject(model)
                .environmentObject(navigation)
                .environmentObject(BackupActivity.shared)
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { MacCommands(navigation: navigation, model: model) }
        .onChange(of: scenePhase) { _, phase in handle(phase) }

        Settings {
            MacSettingsView()
                .environmentObject(model)
                .environmentObject(BackupActivity.shared)
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarStatusView()
                .environmentObject(model)
                .environmentObject(navigation)
                .environmentObject(BackupActivity.shared)
        } label: {
            MenuBarIcon().environmentObject(BackupActivity.shared)
        }
        .menuBarExtraStyle(.window)
    }

    private func handle(_ phase: ScenePhase) {
        let env = AppEnvironment.shared
        switch phase {
        case .active:
            guard model.onboardingComplete else { return }
            env.td.start()
            Task { await env.enforceCacheLimits() }
            Task.detached(priority: .userInitiated) { env.engine.relinkRestoredItems() }
        case .background:
            env.originalsCache.flush()
            env.thumbnailCache.flush()
        default: break
        }
    }
}

enum MacPrefs {
    static let showMenuBarExtra = "macShowMenuBarExtra"
    static let tileSize = "macTileSize"
    static let squareTiles = "macSquareTiles"
}

/// Sidebar selection and app-wide requests (menu commands, menu bar extra) for the main window.
@MainActor
final class MacNavigation: ObservableObject {
    static let shared = MacNavigation()
    static let mainWindowId = "main"

    @Published var selection: SidebarItem? = .library
    /// Commands from the menu bar, handled by whichever view is on screen.
    let commands = PassthroughCommands()
}

/// Lightweight fan-out for menu commands (zoom, info, select all…).
@MainActor
final class PassthroughCommands {
    enum Command { case zoomIn, zoomOut, toggleInfo, selectAll, find }
    private var handlers: [UUID: (Command) -> Bool] = [:]

    func subscribe(_ handler: @escaping (Command) -> Bool) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    func unsubscribe(_ id: UUID) { handlers[id] = nil }

    func send(_ command: Command) {
        for handler in handlers.values where handler(command) { return }
    }
}

struct MacRootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.onboardingComplete && !model.needsSignIn {
                MainWindowView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .frame(minWidth: 820, minHeight: 640)
                    .toolbar(removing: .title)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: model.onboardingComplete && !model.needsSignIn)
    }
}

struct MacCommands: Commands {
    @ObservedObject var navigation: MacNavigation
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        SidebarCommands()
        InspectorCommands()
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .newItem) {
            Button("Back Up Now") { ContinuedBackup.start(everything: true) }
                .keyboardShortcut("b", modifiers: [.command])
                .disabled(!model.onboardingComplete)
            Button("Pause Backup") { AppEnvironment.shared.engine.pause() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!model.onboardingComplete)
        }
        CommandGroup(before: .toolbar) {
            Button("Zoom In") { navigation.commands.send(.zoomIn) }.keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { navigation.commands.send(.zoomOut) }.keyboardShortcut("-", modifiers: .command)
            Button("Show Info") { navigation.commands.send(.toggleInfo) }.keyboardShortcut("i", modifiers: .command)
            Divider()
        }
        CommandMenu("Go") {
            ForEach(SidebarItem.goMenu, id: \.self) { item in
                Button(item.title) {
                    openWindow(id: MacNavigation.mainWindowId)
                    navigation.selection = item
                }
                .keyboardShortcut(item.shortcut, modifiers: .command)
            }
        }
    }
}
