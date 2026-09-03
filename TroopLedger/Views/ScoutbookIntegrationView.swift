import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ImportHubView: View {
    @State private var selection = ImportSource.scoutbook

    /// The starting-workbook snapshot is only bundled in Debug builds.
    private var availableSources: [ImportSource] {
        ImportSource.allCases.filter { $0 != .startingWorkbook || Bundle.main.url(forResource: "TroopFinanceImport", withExtension: "json") != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Import source", selection: $selection) {
                ForEach(availableSources) { source in Text(source.rawValue).tag(source) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            switch selection {
            case .scoutbook: ScoutbookIntegrationView()
            case .spreadsheet: GeneralSpreadsheetImportView()
            case .startingWorkbook: SpreadsheetImportView()
            }
        }
        .pageHeader(title: "Imports")
    }
}

private enum ImportSource: String, CaseIterable, Identifiable {
    case scoutbook = "Scoutbook"
    case spreadsheet = "Spreadsheet"
    case startingWorkbook = "Starting Workbook"
    var id: String { rawValue }
}

struct ScoutbookIntegrationView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScoutbookImportRecord.importedAt, order: .reverse) private var importHistory: [ScoutbookImportRecord]
    @Query(sort: \ExternalCalendarSubscription.name) private var subscriptions: [ExternalCalendarSubscription]
    @State private var section = ScoutbookSection.quickExport
    @State private var showingFileImporter = false
    @State private var document: ScoutbookCSVDocument?
    @State private var selectedKind = ScoutbookCSVKind.members
    @State private var preview: ScoutbookImportPreview?
    @State private var showingImportConfirmation = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var subscriptionName = "Troop Calendar"
    @State private var subscriptionURL = ""
    @State private var syncingIDs: Set<UUID> = []
    @State private var pendingRemoval: ExternalCalendarSubscription?

    var body: some View {
        List {
            Section {
                Picker("Scoutbook integration", selection: $section) {
                    ForEach(ScoutbookSection.allCases) { option in Text(option.rawValue).tag(option) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if section == .quickExport {
                quickExportSections
            } else {
                calendarSections
            }
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]) { result in
            handleFileResult(result)
        }
        .confirmationDialog("Import Scoutbook export?", isPresented: $showingImportConfirmation, titleVisibility: .visible) {
            Button("Import \(preview?.validRowCount ?? 0) valid rows") { performCSVImport() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Matching member IDs or names will be updated. Payment-log rows use stable duplicate identifiers.")
        }
        .confirmationDialog(
            "Remove this calendar subscription?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { subscription in
            Button("Remove \(subscription.name)", role: .destructive) { remove(subscription) }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { subscription in
            Text("Every event synchronized from \(subscription.name) will be deleted unless it has local financial or roster records. Scoutbook itself is not changed.")
        }
        .alert("Scoutbook Integration", isPresented: Binding(get: { errorMessage != nil || statusMessage != nil }, set: { if !$0 { errorMessage = nil; statusMessage = nil } })) {
            Button("OK") { errorMessage = nil; statusMessage = nil }
        } message: {
            Text(errorMessage ?? statusMessage ?? "")
        }
    }

    @ViewBuilder
    private var quickExportSections: some View {
        Section("Quick Export File") {
            Text("Import Scoutbook Plus Quick Export CSV/TSV files for Scouts/Members, Leaders & Parents, or Payment Logs. The app previews and validates rows before changing the ledger.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Choose Scoutbook Export", systemImage: "doc.badge.plus") { showingFileImporter = true }
        }

        if let document, let preview {
            Section("Preview") {
                LabeledContent("File", value: document.sourceName)
                LabeledContent("Rows", value: "\(document.rows.count)")
                LabeledContent("Valid", value: "\(preview.validRowCount)")
                LabeledContent("Needs review", value: "\(preview.invalidRowCount)")
                Picker("Export type", selection: $selectedKind) {
                    ForEach(ScoutbookCSVKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                }
                .onChange(of: selectedKind) { _, newValue in refreshPreview(kind: newValue) }
                Text("Detected columns: \(document.headers.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Sample Rows") {
                ForEach(document.rows.prefix(5)) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rowSummary(row)).lineLimit(2)
                        Text("Source row \(row.id)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if !preview.issues.isEmpty {
                Section("Preview Issues") {
                    ForEach(Array(preview.issues.enumerated()), id: \.offset) { _, issue in
                        Label(issue, systemImage: "exclamationmark.triangle")
                    }
                }
            }

            Section("Import") {
                Button("Import Valid Rows", systemImage: "square.and.arrow.down") { showingImportConfirmation = true }
                    .disabled(preview.validRowCount == 0 || alreadyImported(document.fingerprint))
                if alreadyImported(document.fingerprint) {
                    Label("This exact file was already imported", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }

        if !importHistory.isEmpty {
            Section("Recent Scoutbook Imports") {
                ForEach(importHistory.prefix(8)) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.sourceName).font(.headline)
                        Text("\(record.importKind) • \(record.importedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(record.insertedCount) added, \(record.updatedCount) updated, \(record.skippedCount) skipped")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var calendarSections: some View {
        Section("Add Read-Only Calendar") {
            Text("Paste one of the HTTPS .ics subscription links shown at the bottom of the Scoutbook Plus Calendar page. Use a troop or patrol feed as needed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Calendar name", text: $subscriptionName)
            TextField("https://…", text: $subscriptionURL)
#if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
#endif
            Button("Add and Sync Calendar", systemImage: "calendar.badge.plus", action: addSubscription)
                .disabled(subscriptionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        Section("Calendar Privacy") {
            Text("TroopLedger stores the subscription URL in your private SwiftData/CloudKit database. It never asks for or stores your my.Scouting username or password. Treat the subscription URL as private because anyone who obtains it may be able to read that calendar feed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section("Subscriptions") {
            if subscriptions.isEmpty {
                Text("No Scoutbook calendars subscribed.").foregroundStyle(.secondary)
            } else {
                ForEach(subscriptions) { subscription in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(subscription.name).font(.headline)
                                Text(subscriptionStatus(subscription)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if syncingIDs.contains(subscription.id) { ProgressView() }
                            Button("Sync", systemImage: "arrow.clockwise") { sync(subscription) }
                                .labelStyle(.iconOnly)
                                .disabled(syncingIDs.contains(subscription.id))
                        }
                        if !subscription.lastError.isEmpty {
                            Label(subscription.lastError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .deleteDisabled(syncingIDs.contains(subscription.id))
                }
                .onDelete(perform: removeSubscriptions)
            }
        }

        Section("How Calendar Sync Works") {
            Text("Subscribed events appear in the main Events calendar with a link symbol. They are read-only in TroopLedger and are updated by UID whenever you select Sync. Removing a subscription also removes its synchronized events; it does not change Scoutbook.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func handleFileResult(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try ImportedFileReader.read(url, maximumBytes: ScoutbookImporter.maximumFileBytes, tooLargeError: ScoutbookImportError.fileTooLarge)
            let parsed = try ScoutbookImporter.parse(data: data, sourceName: url.lastPathComponent)
            document = parsed
            selectedKind = parsed.detectedKind
            preview = ScoutbookImporter.preview(document: parsed, kind: parsed.detectedKind)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshPreview(kind: ScoutbookCSVKind) {
        guard let document else { return }
        preview = ScoutbookImporter.preview(document: document, kind: kind)
    }

    private func performCSVImport() {
        guard let document else { return }
        do {
            let result = try ScoutbookImporter.importDocument(document, kind: selectedKind, into: modelContext)
            statusMessage = "Import complete: \(result.inserted) added, \(result.updated) updated, and \(result.skipped) skipped."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func alreadyImported(_ fingerprint: String) -> Bool {
        importHistory.contains { $0.sourceFingerprint == fingerprint }
    }

    private func rowSummary(_ row: ScoutbookCSVRow) -> String {
        let preferred = row.value(["Name", "Member Name", "Scout Name", "First Name"])
        let detail = row.value(["Last Name", "Transaction Date", "Date", "Position", "Category", "Description"])
        let amount = row.value(["Amount", "Transaction Amount"])
        let values = [preferred, detail, amount].filter { !$0.isEmpty }
        guard values.isEmpty else { return values.joined(separator: " • ") }
        // Fall back to the first populated columns in file order rather than dictionary order.
        return (document?.headers ?? [])
            .compactMap { row.values[ScoutbookCSVDocument.normalizedHeader($0)] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: " • ")
    }

    private func addSubscription() {
        do {
            let url = try ScoutbookCalendarService.validatedURL(subscriptionURL)
            // The same feed subscribed twice creates every event twice, because each subscription matches
            // only its own events.
            if let existing = subscriptions.first(where: { URL(string: $0.feedURLString.trimmingCharacters(in: .whitespacesAndNewlines)) == url }) {
                errorMessage = "That feed is already subscribed as \(existing.name). Use Sync to refresh it."
                return
            }
            let subscription = ExternalCalendarSubscription(
                name: subscriptionName.trimmingCharacters(in: .whitespacesAndNewlines),
                feedURLString: subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            modelContext.insert(subscription)
            AuditLogger.record(
                .create,
                recordType: "Calendar Subscription",
                recordID: subscription.id,
                summary: "Added Scoutbook calendar \(subscription.name)",
                // The full URL carries an access token and stays out of the log; the host still identifies the feed.
                details: AuditLogger.details([("Feed host", url.host), ("Note", "Subscription URL intentionally omitted from the audit log.")]),
                in: modelContext
            )
            try modelContext.save()
            subscriptionURL = ""
            sync(subscription)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sync(_ subscription: ExternalCalendarSubscription) {
        syncingIDs.insert(subscription.id)
        Task {
            defer { syncingIDs.remove(subscription.id) }
            do {
                let result = try await ScoutbookCalendarService.sync(subscription: subscription, into: modelContext)
                let preservation = result.detached == 0 ? "" : " \(result.detached) event(s) with local records were preserved as editable events."
                statusMessage = "\(subscription.name) synced \(result.eventCount) events: \(result.inserted) added, \(result.updated) updated, and \(result.removed) removed.\(preservation)"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func removeSubscriptions(at offsets: IndexSet) {
        guard let index = offsets.first else { return }
        pendingRemoval = subscriptions[index]
    }

    private func remove(_ subscription: ExternalCalendarSubscription) {
        pendingRemoval = nil
        do {
            try ScoutbookCalendarService.remove(subscription: subscription, from: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func subscriptionStatus(_ subscription: ExternalCalendarSubscription) -> String {
        if let lastSyncedAt = subscription.lastSyncedAt {
            return "\(subscription.lastEventCount) events • synced \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Not yet synced"
    }
}

private enum ScoutbookSection: String, CaseIterable, Identifiable {
    case quickExport = "Quick Export"
    case calendar = "Calendar"
    var id: String { rawValue }
}
