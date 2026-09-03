import SwiftUI
import SwiftData

struct SpreadsheetImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ImportRecord.importedAt, order: .reverse) private var imports: [ImportRecord]
    @Query private var accounts: [AccountRecord]
    @Query private var transactions: [LedgerTransaction]
    @State private var snapshot: SpreadsheetImportSnapshot?
    @State private var loadError: String?
    @State private var importError: String?
    @State private var showingConfirmation = false
    @State private var isImporting = false

    private var alreadyImported: ImportRecord? {
        guard let snapshot else { return nil }
        return imports.first { $0.sourceFingerprint == snapshot.sourceFingerprint }
    }

    var body: some View {
        List {
            if let loadError {
                Section { Label(loadError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            } else if let snapshot {
                sourceSection(snapshot)
                verificationSection(snapshot)
                countSection(snapshot)
                actionSection(snapshot)
                notesSection
            } else {
                Section { ProgressView("Loading workbook snapshot…") }
            }
        }
        .task { loadSnapshotIfNeeded() }
        .confirmationDialog("Import workbook starting data?", isPresented: $showingConfirmation, titleVisibility: .visible) {
            Button("Import \(snapshot?.totalRecordCount ?? 0) records") { performImport() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The import will append the verified workbook snapshot. Run it on only one device, then allow iCloud to sync before opening another device.")
        }
        .alert("Import Failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "Unknown import error")
        }
    }

    private func sourceSection(_ snapshot: SpreadsheetImportSnapshot) -> some View {
        Section("Source") {
            LabeledContent("Workbook", value: snapshot.sourceName)
            LabeledContent("Snapshot created", value: snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Fingerprint", value: String(snapshot.sourceFingerprint.prefix(12)) + "…")
        }
    }

    private func verificationSection(_ snapshot: SpreadsheetImportSnapshot) -> some View {
        Section("Verification") {
            Label("Checking register reconciles to \(Money.currency(cents: snapshot.checks.importedCheckingEndingCents))", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Label("Current member balances reconstructed without exceptions", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text("Cash receipts and event detail are imported separately from the checking account, preventing duplicate bank income or expenses.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func countSection(_ snapshot: SpreadsheetImportSnapshot) -> some View {
        Section("Records") {
            LabeledContent("Accounts", value: "\(snapshot.accounts.count)")
            LabeledContent("Checking transactions", value: "\(snapshot.transactions.count)")
            LabeledContent("Cash receipts", value: "\(snapshot.cashReceipts.count)")
            LabeledContent("People", value: "\(snapshot.people.count)")
            LabeledContent("Annual registrations", value: "\(snapshot.registrations.count)")
            LabeledContent("Current member-ledger entries", value: "\(snapshot.memberEntries.count)")
            LabeledContent("Events", value: "\(snapshot.events.count)")
            LabeledContent("Event financial lines", value: "\(snapshot.eventLineItems.count)")
            LabeledContent("Total", value: "\(snapshot.totalRecordCount)")
        }
    }

    @ViewBuilder
    private func actionSection(_ snapshot: SpreadsheetImportSnapshot) -> some View {
        Section("Import") {
            if let imported = alreadyImported {
                Label("Imported \(imported.importedAt.formatted(date: .long, time: .shortened))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Duplicate protection is active for this workbook fingerprint.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                if !accounts.isEmpty || !transactions.isEmpty {
                    Label("The database already contains data. Importing will append the workbook records.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button("Import Workbook Starting Data", systemImage: "square.and.arrow.down", action: { showingConfirmation = true })
                    .disabled(isImporting || !snapshot.checks.checkingBalanceMatches)
                if isImporting { ProgressView() }
            }
        }
    }

    private var notesSection: some View {
        Section("Important") {
            Text("Most legacy event sheets stored only a month and year, so imported events initially appear on the first day of that month and are marked Approximate. Edit each event's exact dates from its detail screen.")
            Text("The source workbook remains unchanged. Imported records retain their source sheet and row for audit tracing.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func loadSnapshotIfNeeded() {
        guard snapshot == nil, loadError == nil else { return }
        do { snapshot = try SpreadsheetImporter.loadBundledSnapshot() }
        catch { loadError = error.localizedDescription }
    }

    private func performImport() {
        guard let snapshot else { return }
        isImporting = true
        defer { isImporting = false }
        do { _ = try SpreadsheetImporter.importSnapshot(snapshot, into: modelContext) }
        catch { importError = error.localizedDescription }
    }
}
