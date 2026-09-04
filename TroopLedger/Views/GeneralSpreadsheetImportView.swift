import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct GeneralSpreadsheetImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query(sort: \ReconciliationRecord.statementDate, order: .reverse) private var reconciliations: [ReconciliationRecord]
    @Query(sort: \GeneralSpreadsheetImportRecord.importedAt, order: .reverse) private var importHistory: [GeneralSpreadsheetImportRecord]
    @Query private var transactions: [LedgerTransaction]
    @State private var showingFileImporter = false
    @State private var document: GeneralSpreadsheetDocument?
    @State private var mapping = TransactionColumnMapping()
    @State private var accountID: UUID?
    @State private var defaultDirection: TransactionDirection = .expense
    @State private var defaultCategory = "Uncategorized"
    @State private var skipExceptions = false
    @State private var showingConfirmation = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var preview: GeneralSpreadsheetPreview? {
        guard let document else { return nil }
        return GeneralSpreadsheetImporter.preview(
            document: document,
            mapping: mapping,
            accountID: accountID,
            defaultDirection: defaultDirection,
            defaultCategory: defaultCategory,
            reconciliations: reconciliations,
            // The import itself flags rows that duplicate existing register entries; the on-screen dry run
            // must see the same rows or it reports "0 exceptions" and the import then fails after confirmation.
            existingTransactions: transactions
        )
    }

    private var alreadyImported: Bool {
        guard let document else { return false }
        return importHistory.contains { $0.sourceFingerprint == document.fingerprint }
    }

    private func canImport(_ preview: GeneralSpreadsheetPreview?) -> Bool {
        guard let preview else { return false }
        return !alreadyImported &&
            preview.mappingIssues.isEmpty &&
            !preview.validRows.isEmpty &&
            (preview.invalidRows.isEmpty || skipExceptions)
    }

    var body: some View {
        // The dry run parses every row of the file; evaluate it once per render rather than three times.
        let preview = self.preview
        return List {
            Section("Transaction Spreadsheet") {
                Text("Import a transaction register exported from any spreadsheet as CSV or tab-separated text. TroopLedger does not modify the source file and performs a complete dry run before writing anything.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Choose CSV or TSV File", systemImage: "tablecells.badge.ellipsis") {
                    showingFileImporter = true
                }
            }

            if let document {
                sourceSection(document)
                destinationSection
                mappingSection(document)
                previewSections(document, preview: preview)
            }

            if !importHistory.isEmpty {
                Section("Recent Spreadsheet Imports") {
                    ForEach(importHistory.prefix(8)) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.sourceName).font(.headline)
                            Text(record.importedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(record.importedCount) imported, \(record.skippedCount) skipped")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]
        ) { result in
            handleFileResult(result)
        }
        .confirmationDialog(
            "Import previewed transactions?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Import \(preview?.validRows.count ?? 0) Transactions") { performImport() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only rows marked Ready will be added. The source fingerprint, mapping, exception count, and first 200 exception details will be retained in the audit history.")
        }
        .alert("Spreadsheet Import", isPresented: Binding(
            get: { statusMessage != nil || errorMessage != nil },
            set: { if !$0 { statusMessage = nil; errorMessage = nil } }
        )) {
            Button("OK") { statusMessage = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? statusMessage ?? "")
        }
        .onAppear {
            if accountID == nil { accountID = AccountSelectionPolicy.defaultOperatingAccount(in: accounts)?.id ?? accounts.first?.id }
        }
    }

    private func sourceSection(_ document: GeneralSpreadsheetDocument) -> some View {
        Section("Source") {
            LabeledContent("File", value: document.sourceName)
            LabeledContent("Rows", value: String(document.rows.count))
            LabeledContent("Columns", value: String(document.headers.count))
            LabeledContent("Fingerprint", value: String(document.fingerprint.prefix(12)) + "…")
            if alreadyImported {
                Label("This exact file was already imported", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var destinationSection: some View {
        Section("Destination and Defaults") {
            Picker("Account", selection: $accountID) {
                Text("Choose an account").tag(nil as UUID?)
                    // The importer refuses an inactive destination after confirmation; do not offer one.
                ForEach(accounts.filter(\.isActive)) { account in Text(account.name).tag(account.id as UUID?) }
            }
            Picker("Default type", selection: $defaultDirection) {
                ForEach(TransactionDirection.allCases) { direction in Text(direction.rawValue).tag(direction) }
            }
            TextField("Default category", text: $defaultCategory)
            Text("The default type is used for positive values in a single Amount column when no Type column is mapped. Negative amounts are expenses. The default category is used only when no mapped category value is present.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func mappingSection(_ document: GeneralSpreadsheetDocument) -> some View {
        Section("Field Mapping") {
            ForEach(TransactionImportField.allCases) { field in
                Picker(field.rawValue + (field.isRequired ? " *" : ""), selection: mappingBinding(field)) {
                    Text("Not mapped").tag(nil as Int?)
                    ForEach(Array(document.headers.enumerated()), id: \.offset) { index, header in
                        Text(header).tag(index as Int?)
                    }
                }
            }
            Text("Map Date and either one Amount column or separate Income Amount and Expense Amount columns. Each source column can be used once. An asterisk marks a required field.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func previewSections(_ document: GeneralSpreadsheetDocument, preview: GeneralSpreadsheetPreview?) -> some View {
        if let preview {
            Section("Dry-Run Preview") {
                LabeledContent("Source rows", value: String(document.rows.count))
                LabeledContent("Ready to import", value: String(preview.validRows.count))
                LabeledContent("Exceptions", value: String(preview.invalidRows.count))
                LabeledContent("Income", value: Money.currency(cents: preview.totalIncomeCents))
                LabeledContent("Expenses", value: Money.currency(cents: preview.totalExpenseCents))
                Text("No database records have been changed. Reconciled dates are checked against the selected account and cannot be imported.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !preview.mappingIssues.isEmpty {
                Section("Mapping Issues") {
                    ForEach(preview.mappingIssues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if !preview.validRows.isEmpty {
                Section("Ready Sample") {
                    ForEach(preview.validRows.prefix(5)) { row in
                        if let draft = row.draft {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(draft.payee.isEmpty ? draft.category : draft.payee).font(.headline)
                                    Spacer()
                                    MoneyText(cents: draft.direction == .income ? draft.amountCents : -draft.amountCents, colorBySign: true)
                                }
                                Text("Row \(draft.sourceRow) • \(draft.date.formatted(date: .abbreviated, time: .omitted)) • \(draft.category)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !preview.invalidRows.isEmpty && preview.mappingIssues.isEmpty {
                Section("Exceptions") {
                    ForEach(preview.invalidRows.prefix(100)) { row in
                        Label("Row \(row.sourceRow): \(row.issues.joined(separator: "; "))", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if preview.invalidRows.count > 100 {
                        Text("\(preview.invalidRows.count - 100) additional exceptions are retained in the import preview.")
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Import valid rows and skip these exceptions", isOn: $skipExceptions)
                    Text("Adjust the mapping or defaults to resolve exceptions. If the remaining rows should not be imported, explicitly enable skipping; the total and first 200 row-level reasons will be retained in import history.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Import") {
                Button("Import Ready Transactions", systemImage: "square.and.arrow.down") {
                    showingConfirmation = true
                }
                .disabled(!canImport(preview))
                if alreadyImported {
                    Text("Duplicate protection prevents importing this exact file again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func mappingBinding(_ field: TransactionImportField) -> Binding<Int?> {
        Binding(
            get: { mapping[field] },
            set: { newValue in
                mapping[field] = newValue
                skipExceptions = false
            }
        )
    }

    private func handleFileResult(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try ImportedFileReader.read(url, maximumBytes: GeneralSpreadsheetImporter.maximumFileBytes, tooLargeError: GeneralSpreadsheetImportError.fileTooLarge)
            let parsed = try GeneralSpreadsheetImporter.parse(data: data, sourceName: url.lastPathComponent)
            document = parsed
            mapping = TransactionColumnMapping.detected(from: parsed.headers)
            skipExceptions = false
            if accountID == nil { accountID = AccountSelectionPolicy.defaultOperatingAccount(in: accounts)?.id ?? accounts.first?.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performImport() {
        guard let document else { return }
        do {
            let result = try GeneralSpreadsheetImporter.importDocument(
                document,
                mapping: mapping,
                accountID: accountID,
                defaultDirection: defaultDirection,
                defaultCategory: defaultCategory,
                reconciliations: reconciliations,
                skipExceptions: skipExceptions,
                into: modelContext
            )
            statusMessage = "Import complete: \(result.inserted) transactions added and \(result.skipped) exceptions skipped."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
