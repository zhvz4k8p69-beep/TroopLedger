import CryptoKit
import SwiftUI
import SwiftData

/// The audit entries that mention one record, reachable from that record's own screen.
struct AuditHistoryView: View {
    let recordID: UUID
    let title: String
    @Query private var related: [AuditLogEntry]

    init(recordID: UUID, title: String) {
        self.recordID = recordID
        self.title = title
        // Filter in the store. This screen is reachable from every record, and it used to load the entire
        // audit log and substring-search every row's details on each render.
        let id: UUID? = recordID
        let text = recordID.uuidString
        _related = Query(
            filter: #Predicate<AuditLogEntry> { $0.recordID == id || $0.details.localizedStandardContains(text) },
            sort: \AuditLogEntry.timestamp,
            order: .reverse
        )
    }

    var body: some View {
        List {
            if related.isEmpty {
                Text("No audit entries mention this record.").foregroundStyle(.secondary)
            } else {
                ForEach(related) { entry in
                    NavigationLink { AuditLogDetailView(entry: entry) } label: { AuditLogRow(entry: entry) }
                }
            }
        }
        .pageHeader(title: "History • \(title)")
    }
}

struct AuditLogView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AuditLogEntry.timestamp, order: .reverse) private var entries: [AuditLogEntry]
    @State private var searchText = ""
    @State private var actionFilter: AuditAction?
    @State private var exportDocument: ReimbursementApprovalCSVDocument?
    @State private var exportFilename = "TroopLedger Audit Log.csv"
    @State private var exportedCount = 0
    @State private var exportFingerprint = ""
    @State private var showingExporter = false
    @State private var exportMessage: String?

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
            }
        }
        // Attached to the container rather than the list: when a search matched nothing, the list (and the
        // search field with it) disappeared, leaving no way to clear the search.
        .searchable(text: $searchText, prompt: "Summary, details, record, device, or user")
        .pageToolbar(title: "Audit Log") {
            Button("Export CSV", systemImage: "square.and.arrow.up") { prepareExport() }
                .disabled(entries.isEmpty)
        }
        .fileExporter(isPresented: $showingExporter, document: exportDocument, contentType: .commaSeparatedText, defaultFilename: exportFilename) { completeExport($0) }
        .alert("Audit Log", isPresented: Binding(get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } })) {
            Button("OK") { exportMessage = nil }
        } message: { Text(exportMessage ?? "") }
    }

    /// Auditors and committee reviewers can receive the log on its own instead of a full backup of every record.
    private func prepareExport() {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        exportFilename = String(format: "TroopLedger Audit Log %04d-%02d-%02d.csv", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        exportedCount = entries.count
        let csv = AuditLogger.csv(for: entries)
        exportFingerprint = SHA256.hash(data: Data(csv.utf8)).map { String(format: "%02x", $0) }.joined()
        exportDocument = ReimbursementApprovalCSVDocument(csv: csv)
        showingExporter = true
    }

    private func completeExport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            AuditLogger.record(.export, recordType: "Audit Log", recordID: nil, summary: "Exported audit log", details: AuditLogger.details([("File", url.lastPathComponent), ("Entries", String(exportedCount)), ("SHA-256", exportFingerprint)]), in: modelContext)
            do {
                try modelContext.save()
                exportMessage = "Exported \(exportedCount) audit entries."
            } catch {
                exportMessage = "The log was exported, but the export entry could not be saved: \(error.localizedDescription)"
            }
        case .failure(let error):
            let nsError = error as NSError
            guard !(error is CancellationError), nsError.code != NSUserCancelledError else { return }
            exportMessage = "The audit log could not be exported: \(error.localizedDescription)"
        }
    }
}

struct AuditLogRow: View {
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

struct AuditLogDetailView: View {
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
