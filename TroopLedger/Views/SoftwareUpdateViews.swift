#if os(macOS)
import SwiftUI

struct CheckForSoftwareUpdatesButton: View {
    @ObservedObject var updates: SoftwareUpdateService
    var body: some View {
        Button("Check for Updates…", action: updates.checkForUpdates)
            .disabled(updates.configurationError != nil || !updates.canCheckForUpdates)
    }
}

struct SoftwareUpdateSettingsView: View {
    @ObservedObject private var updates = SoftwareUpdateService.shared
    var body: some View {
        Form {
            Section("Software Updates") {
                LabeledContent("Installed version", value: version)
                if let error = updates.configurationError {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticChecks($0) }
                    ))
                    CheckForSoftwareUpdatesButton(updates: updates)
                    if let date = updates.lastUpdateCheckDate {
                        LabeledContent("Last checked", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    Text("TroopLedger checks for new versions daily when automatic checks are enabled. You can review an update before installing it. Installation restarts the app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }
}
#endif
