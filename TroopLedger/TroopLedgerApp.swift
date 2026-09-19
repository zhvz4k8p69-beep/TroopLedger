import SwiftUI
import SwiftData

@main
struct TroopLedgerApp: App {
#if os(macOS)
    @StateObject private var updates = SoftwareUpdateService.shared
#endif
    private let storage = ModelContainerFactory.openCloudContainer()

    var body: some Scene {
#if os(macOS)
        WindowGroup {
            mainContent
        }
        .commands {
            TroopLedgerCommands()
            CommandGroup(after: .appInfo) {
                CheckForSoftwareUpdatesButton(updates: updates)
            }
        }

        Window("Preferences", id: "preferences") {
            switch storage {
            case .success(let container):
                PreferencesView(showsDismissButton: false)
                    .modelContainer(container)
                    .troopLedgerAppearance()
                    .appLockGate()
            case .failure(let error):
                StorageFailureView(error: error)
            }
        }
        .defaultSize(width: 760, height: 720)
        .windowResizability(.contentMinSize)
#else
        WindowGroup {
            mainContent
        }
#endif
    }

    @ViewBuilder
    private var mainContent: some View {
        switch storage {
        case .success(let container):
            RootView()
                .modelContainer(container)
                .troopLedgerAppearance()
                .appLockGate()
        case .failure(let error):
            StorageFailureView(error: error)
        }
    }
}

/// Shown instead of crashing when the SwiftData store cannot be opened, so the treasurer sees what went wrong
/// and can act on it (free disk space, restore a backup, contact support) instead of a silent crash loop.
struct StorageFailureView: View {
    let error: Error

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("TroopLedger could not open its database")
                .font(.title2.bold())
            Text("No records were changed. Free up disk space, make sure iCloud is signed in, or restore from a plaintext backup, then relaunch. If this keeps happening, keep the details below for support.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(String(describing: error))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(32)
        .frame(minWidth: 420, maxWidth: 620)
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
