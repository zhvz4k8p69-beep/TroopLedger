import SwiftUI
import SwiftData

@main
struct TroopLedgerApp: App {
    private let container = ModelContainerFactory.makeCloudContainer()

    var body: some Scene {
#if os(macOS)
        WindowGroup {
            RootView()
                .troopLedgerAppearance()
                .appLockGate()
        }
        .modelContainer(container)
        .commands {
            TroopLedgerCommands()
        }

        Window("Preferences", id: "preferences") {
            PreferencesView(showsDismissButton: false)
                .modelContainer(container)
                .troopLedgerAppearance()
                .appLockGate()
        }
        .defaultSize(width: 760, height: 720)
        .windowResizability(.contentMinSize)
#else
        WindowGroup {
            RootView()
                .troopLedgerAppearance()
                .appLockGate()
        }
        .modelContainer(container)
#endif
    }
}

#if os(macOS)
private struct TroopLedgerCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppAppearance.storageKey) private var storedAppearance = ""

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Preferences…") { openWindow(id: "preferences") }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .toolbar) {
            Divider()
            Button("Toggle Light/Dark Appearance") {
                storedAppearance = AppAppearance.toggledRawValue(
                    storedRawValue: storedAppearance,
                    fallback: AppAppearance.currentMacSystemScheme
                )
            }
            .keyboardShortcut("d", modifiers: .command)
        }
    }
}
#endif
