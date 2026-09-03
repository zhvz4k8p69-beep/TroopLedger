import SwiftUI
import SwiftData

struct AuditLogView: View {
    @Query(sort: \AuditLogEntry.timestamp, order: .reverse) private var entries: [AuditLogEntry]
    @State private var searchText = ""
    @State private var actionFilter: AuditAction?

    private var filteredEntries: [AuditLogEntry] {
        entries.filter { entry in
            let matchesAction = actionFilter == nil || entry.action == actionFilter
            guard matchesAction else { return false }
            guard !searchText.isEmpty else { return true }
            return entry.summary.localizedCaseInsensitiveContains(searchText) ||
                entry.details.localizedCaseInsensitiveContains(searchText) ||
                entry.recordType.localizedCaseInsensitiveContains(searchText) ||
                entry.deviceName.localizedCaseInsensitiveContains(searchText) ||
                entry.userIdentity.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Action", selection: $actionFilter) {
                Text("All Actions").tag(nil as AuditAction?)
                ForEach(AuditAction.allCases) { action in
                    Text(action.rawValue).tag(action as AuditAction?)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if entries.isEmpty {
                EmptyMessage(
                    title: "No audit activity yet",
                    message: "New changes, imports, reconciliations, period locks, and adjustments will be recorded here.",
                    systemImage: "list.clipboard"
                )
            } else if filteredEntries.isEmpty {
                EmptyMessage(title: "No matching activity", message: "Change the action filter or search text.", systemImage: "magnifyingglass")
            } else {
                List(filteredEntries) { entry in
                    NavigationLink {
                        AuditLogDetailView(entry: entry)
                    } label: {
                        AuditLogRow(entry: entry)
                    }
                }
                .searchable(text: $searchText, prompt: "Summary, details, record, device, or user")
            }
        }
        .pageHeader(title: "Audit Log")
    }
}

private struct AuditLogRow: View {
    let entry: AuditLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.action.systemImage)
                .foregroundStyle(entry.action == .delete ? Color.red : Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.summary).font(.headline)
                Text("\(entry.action.rawValue) • \(entry.recordType)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

private struct AuditLogDetailView: View {
    let entry: AuditLogEntry

    var body: some View {
        List {
            Section("Activity") {
                LabeledContent("Action", value: entry.action.rawValue)
                LabeledContent("Record type", value: entry.recordType)
                LabeledContent("Timestamp", value: entry.timestamp.formatted(date: .complete, time: .standard))
                if let recordID = entry.recordID {
                    LabeledContent("Record ID") {
                        Text(recordID.uuidString).font(.caption.monospaced())
                    }
                }
            }
            Section("Summary") { Text(entry.summary) }
            if !entry.details.isEmpty {
                Section("Details") { Text(entry.details) }
            }
            Section("Origin") {
                LabeledContent("Device", value: entry.deviceName.isEmpty ? "Unavailable" : entry.deviceName)
                LabeledContent("User", value: entry.userIdentity.isEmpty ? "Unavailable" : entry.userIdentity)
                LabeledContent("System", value: entry.operatingSystem)
            }
            Section {
                Label("Audit entries are read-only and cannot be edited or deleted in TroopLedger.", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Audit Entry")
    }
}
