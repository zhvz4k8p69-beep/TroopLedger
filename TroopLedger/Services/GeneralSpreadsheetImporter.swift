import CryptoKit
import Foundation
import SwiftData

enum TransactionImportField: String, CaseIterable, Identifiable, Hashable {
    case date = "Date"
    case direction = "Income / Expense Type"
    case amount = "Signed or Unsigned Amount"
    case incomeAmount = "Income Amount"
    case expenseAmount = "Expense Amount"
    case payee = "Payee / Received From"
    case category = "Category"
    case memo = "Memo"
    case reference = "Check / Reference Number"
    case cleared = "Cleared Status"

    var id: String { rawValue }

    var isRequired: Bool { self == .date }
}

struct TransactionColumnMapping: Equatable {
    var columns: [TransactionImportField: Int] = [:]

    subscript(field: TransactionImportField) -> Int? {
        get { columns[field] }
        set {
            if let newValue { columns[field] = newValue }
            else { columns.removeValue(forKey: field) }
        }
    }

    static func detected(from headers: [String]) -> TransactionColumnMapping {
        var mapping = TransactionColumnMapping()
        let aliases: [TransactionImportField: [String]] = [
            .date: ["date", "transaction date", "posted date", "entry date"],
            .direction: ["type", "transaction type", "income expense", "direction", "debit credit"],
            .amount: ["amount", "transaction amount", "value", "signed amount"],
            .incomeAmount: ["income", "income amount", "deposit", "deposit amount", "credit"],
            .expenseAmount: ["expense", "expense amount", "withdrawal", "withdrawal amount", "debit"],
            .payee: ["payee", "received from", "name", "vendor", "description"],
            .category: ["category", "account category", "purpose"],
            .memo: ["memo", "notes", "note", "details", "comment"],
            .reference: ["check number", "check", "reference", "reference number", "transaction id"],
            .cleared: ["cleared", "cleared status", "reconciled", "status"],
        ]
        let normalized = headers.map(normalizeHeader)
        for field in TransactionImportField.allCases {
            let candidates = aliases[field, default: []].map(normalizeHeader)
            if let index = normalized.firstIndex(where: candidates.contains) { mapping[field] = index }
        }

        // Prefer a single amount column when present; separate income/expense columns remain an alternate mapping mode.
        if mapping[.amount] != nil {
            mapping[.incomeAmount] = nil
            mapping[.expenseAmount] = nil
        }
        return mapping
    }

    func summary(headers: [String]) -> String {
        TransactionImportField.allCases.compactMap { field in
            guard let index = self[field], headers.indices.contains(index) else { return nil }
            return "\(field.rawValue): \(headers[index])"
        }
        .joined(separator: "\n")
    }
}

struct GeneralSpreadsheetRow: Identifiable, Equatable {
    let id: Int
    let cells: [String]

    func value(at index: Int?) -> String {
        guard let index, cells.indices.contains(index) else { return "" }
        return cells[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct GeneralSpreadsheetDocument: Equatable {
    let sourceName: String
    let fingerprint: String
    let headers: [String]
    let rows: [GeneralSpreadsheetRow]
}

struct SpreadsheetTransactionDraft: Equatable {
    let sourceRow: Int
    let date: Date
    let direction: TransactionDirection
    let amountCents: Int64
    let payee: String
    let category: String
    let memo: String
    let reference: String
    let isCleared: Bool
}

struct GeneralSpreadsheetPreviewRow: Identifiable, Equatable {
    var id: Int { sourceRow }
    let sourceRow: Int
    let draft: SpreadsheetTransactionDraft?
    let issues: [String]

    var isValid: Bool { draft != nil && issues.isEmpty }
}

struct GeneralSpreadsheetPreview: Equatable {
    let mappingIssues: [String]
    let rows: [GeneralSpreadsheetPreviewRow]

    var validRows: [GeneralSpreadsheetPreviewRow] { rows.filter(\.isValid) }
    var invalidRows: [GeneralSpreadsheetPreviewRow] { rows.filter { !$0.isValid } }
    var totalIncomeCents: Int64 {
        validRows.compactMap(\.draft).filter { $0.direction == .income }.reduce(0) { $0 + $1.amountCents }
    }
    var totalExpenseCents: Int64 {
        validRows.compactMap(\.draft).filter { $0.direction == .expense }.reduce(0) { $0 + $1.amountCents }
    }
}

struct GeneralSpreadsheetImportResult: Equatable {
    let inserted: Int
    let skipped: Int
}

enum GeneralSpreadsheetImportError: LocalizedError, Equatable {
    case fileTooLarge
    case unreadableText
    case emptyFile
    case tooManyRows
    case alreadyImported
    case invalidMapping
    case unresolvedExceptions
    case noImportableRows
    case accountNotFound
    case inactiveAccount

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: "The selected file is larger than the 5 MB import limit. Split it into smaller CSV or TSV files."
        case .unreadableText: "The selected file could not be decoded as CSV or TSV text."
        case .emptyFile: "The selected file does not contain a header and at least one data row."
        case .tooManyRows: "The selected file contains more than 25,000 data rows. Split it into smaller files."
        case .alreadyImported: "This exact spreadsheet file has already been imported."
        case .invalidMapping: "The field mapping is incomplete or maps one source column more than once."
        case .unresolvedExceptions: "Some rows still have exceptions. Resolve them through the mapping and defaults, or explicitly allow valid rows to import while exceptions are skipped."
        case .noImportableRows: "No rows passed the import validation."
        case .accountNotFound: "Choose an existing account for these transactions."
        case .inactiveAccount: "The destination account is inactive. Reactivate it or choose an active account."
        }
    }
}

enum GeneralSpreadsheetImporter {
    static let maximumFileBytes = 5 * 1_024 * 1_024
    static let maximumRows = 25_000

    static func parse(data: Data, sourceName: String) throws -> GeneralSpreadsheetDocument {
        guard data.count <= maximumFileBytes else { throw GeneralSpreadsheetImportError.fileTooLarge }
        guard let text = decode(data) else { throw GeneralSpreadsheetImportError.unreadableText }
        let delimiter = detectedDelimiter(in: text)
        let table = parseTable(text, delimiter: delimiter)
        guard let rawHeaders = table.first, !rawHeaders.isEmpty else { throw GeneralSpreadsheetImportError.emptyFile }

        let headers = disambiguatedHeaders(rawHeaders)
        let rows = table.dropFirst().enumerated().compactMap { offset, cells -> GeneralSpreadsheetRow? in
            guard cells.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
            return GeneralSpreadsheetRow(id: offset + 2, cells: cells)
        }
        guard !rows.isEmpty else { throw GeneralSpreadsheetImportError.emptyFile }
        guard rows.count <= maximumRows else { throw GeneralSpreadsheetImportError.tooManyRows }
        return GeneralSpreadsheetDocument(
            sourceName: sourceName,
            fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            headers: headers,
            rows: rows
        )
    }

    static func preview(
        document: GeneralSpreadsheetDocument,
        mapping: TransactionColumnMapping,
        accountID: UUID?,
        defaultDirection: TransactionDirection,
        defaultCategory: String,
        reconciliations: [ReconciliationRecord],
        calendar: Calendar = .current
    ) -> GeneralSpreadsheetPreview {
        let mappingIssues = validate(mapping: mapping, headers: document.headers, accountID: accountID)
        guard mappingIssues.isEmpty else {
            return GeneralSpreadsheetPreview(
                mappingIssues: mappingIssues,
                rows: document.rows.map { .init(sourceRow: $0.id, draft: nil, issues: ["Complete the field mapping above."]) }
            )
        }
        let rows = document.rows.map { row in
            previewRow(
                row,
                mapping: mapping,
                accountID: accountID,
                defaultDirection: defaultDirection,
                defaultCategory: defaultCategory,
                reconciliations: reconciliations,
                calendar: calendar
            )
        }
        return GeneralSpreadsheetPreview(mappingIssues: [], rows: rows)
    }

    @MainActor
    static func importDocument(
        _ document: GeneralSpreadsheetDocument,
        mapping: TransactionColumnMapping,
        accountID: UUID?,
        defaultDirection: TransactionDirection,
        defaultCategory: String,
        reconciliations: [ReconciliationRecord],
        skipExceptions: Bool,
        calendar: Calendar = .current,
        into modelContext: ModelContext
    ) throws -> GeneralSpreadsheetImportResult {
        guard let accountID,
              let account = try modelContext.fetch(FetchDescriptor<AccountRecord>()).first(where: { $0.id == accountID }) else {
            throw GeneralSpreadsheetImportError.accountNotFound
        }
        guard account.isActive else { throw GeneralSpreadsheetImportError.inactiveAccount }
        let history = try modelContext.fetch(FetchDescriptor<GeneralSpreadsheetImportRecord>())
        guard !history.contains(where: { $0.sourceFingerprint == document.fingerprint }) else {
            throw GeneralSpreadsheetImportError.alreadyImported
        }
        let preview = preview(
            document: document,
            mapping: mapping,
            accountID: accountID,
            defaultDirection: defaultDirection,
            defaultCategory: defaultCategory,
            reconciliations: reconciliations,
            calendar: calendar
        )
        guard preview.mappingIssues.isEmpty else { throw GeneralSpreadsheetImportError.invalidMapping }
        guard !preview.validRows.isEmpty else { throw GeneralSpreadsheetImportError.noImportableRows }
        guard skipExceptions || preview.invalidRows.isEmpty else { throw GeneralSpreadsheetImportError.unresolvedExceptions }

        // rollback() below discards every unsaved change in the shared context, so persist unrelated
        // pending edits first; a failed import must only undo the import itself.
        if modelContext.hasChanges { try modelContext.save() }

        do {
            let importedAt = Date()
            for previewRow in preview.validRows {
                guard let draft = previewRow.draft else { continue }
                let transaction = LedgerTransaction(
                    accountID: accountID,
                    date: draft.date,
                    direction: draft.direction,
                    amountCents: draft.amountCents,
                    payee: draft.payee,
                    category: draft.category
                )
                transaction.memo = draft.memo
                transaction.checkNumber = draft.reference
                transaction.isCleared = draft.isCleared
                transaction.sourceSheet = document.sourceName
                transaction.sourceRow = draft.sourceRow
                transaction.createdAt = importedAt
                transaction.modifiedAt = importedAt
                modelContext.insert(transaction)
            }

            let record = GeneralSpreadsheetImportRecord(
                sourceName: document.sourceName,
                sourceFingerprint: document.fingerprint,
                accountID: accountID
            )
            record.importedAt = importedAt
            record.sourceRowCount = document.rows.count
            record.importedCount = preview.validRows.count
            record.skippedCount = preview.invalidRows.count
            record.mappingSummary = mapping.summary(headers: document.headers)
            record.exceptionNotes = preview.invalidRows.prefix(200).map {
                "Row \($0.sourceRow): \($0.issues.joined(separator: "; "))"
            }.joined(separator: "\n")
            modelContext.insert(record)
            AuditLogger.record(
                .importData,
                recordType: "General Spreadsheet Import",
                recordID: record.id,
                summary: "Imported transactions from \(document.sourceName)",
                details: AuditLogger.details([
                    ("Fingerprint", document.fingerprint),
                    ("Account ID", accountID.uuidString),
                    ("Source rows", String(record.sourceRowCount)),
                    ("Imported", String(record.importedCount)),
                    ("Skipped exceptions", String(record.skippedCount)),
                    ("Mapping", record.mappingSummary),
                    ("Exceptions", record.exceptionNotes),
                ]),
                in: modelContext
            )
            try modelContext.save()
            return GeneralSpreadsheetImportResult(inserted: record.importedCount, skipped: record.skippedCount)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private static func validate(mapping: TransactionColumnMapping, headers: [String], accountID: UUID?) -> [String] {
        var issues: [String] = []
        if accountID == nil { issues.append("Choose the destination account.") }
        if mapping[.date] == nil { issues.append("Map a Date column.") }
        let hasAmount = mapping[.amount] != nil
        let hasSplitAmount = mapping[.incomeAmount] != nil || mapping[.expenseAmount] != nil
        if !hasAmount && !hasSplitAmount { issues.append("Map an Amount column or separate Income and Expense columns.") }
        if hasAmount && hasSplitAmount { issues.append("Use either one Amount column or separate Income and Expense columns, not both.") }
        let mapped = mapping.columns.values.filter { headers.indices.contains($0) }
        if Set(mapped).count != mapped.count { issues.append("Each source column can map to only one destination field.") }
        if mapping.columns.values.contains(where: { !headers.indices.contains($0) }) { issues.append("A mapped source column no longer exists.") }
        return issues
    }

    private static func previewRow(
        _ row: GeneralSpreadsheetRow,
        mapping: TransactionColumnMapping,
        accountID: UUID?,
        defaultDirection: TransactionDirection,
        defaultCategory: String,
        reconciliations: [ReconciliationRecord],
        calendar: Calendar
    ) -> GeneralSpreadsheetPreviewRow {
        var issues: [String] = []
        guard let date = parsedDate(row.value(at: mapping[.date]), calendar: calendar) else {
            return .init(sourceRow: row.id, draft: nil, issues: ["Unrecognized or missing date."])
        }

        let parsedAmount = transactionAmount(
            amountText: row.value(at: mapping[.amount]),
            incomeText: row.value(at: mapping[.incomeAmount]),
            expenseText: row.value(at: mapping[.expenseAmount]),
            directionText: row.value(at: mapping[.direction]),
            defaultDirection: defaultDirection
        )
        guard let amount = parsedAmount.value else {
            return .init(sourceRow: row.id, draft: nil, issues: [parsedAmount.issue ?? "Unrecognized amount."])
        }
        if PeriodLocking.isLocked(accountID: accountID, date: date, reconciliations: reconciliations, calendar: calendar) {
            issues.append("Date falls in a reconciled, locked period.")
        }

        let clearedResult = parsedCleared(row.value(at: mapping[.cleared]))
        if let issue = clearedResult.issue { issues.append(issue) }
        let categoryText = row.value(at: mapping[.category])
        let fallbackCategory = defaultCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = categoryText.isEmpty ? (fallbackCategory.isEmpty ? "Uncategorized" : fallbackCategory) : categoryText
        let draft = SpreadsheetTransactionDraft(
            sourceRow: row.id,
            date: date,
            direction: amount.direction,
            amountCents: amount.cents,
            payee: row.value(at: mapping[.payee]),
            category: category,
            memo: row.value(at: mapping[.memo]),
            reference: row.value(at: mapping[.reference]),
            isCleared: clearedResult.value
        )
        return .init(sourceRow: row.id, draft: issues.isEmpty ? draft : nil, issues: issues)
    }

    private static func transactionAmount(
        amountText: String,
        incomeText: String,
        expenseText: String,
        directionText: String,
        defaultDirection: TransactionDirection
    ) -> (value: (direction: TransactionDirection, cents: Int64)?, issue: String?) {
        if !amountText.isEmpty {
            guard let signed = parsedCents(amountText), signed != 0 else { return (nil, "Unrecognized, out-of-range, or zero amount.") }
            let direction: TransactionDirection
            if directionText.isEmpty {
                direction = signed < 0 ? .expense : defaultDirection
            } else if let parsed = parsedDirection(directionText) {
                direction = parsed
            } else {
                return (nil, "Unrecognized income/expense type.")
            }
            return ((direction, abs(signed)), nil)
        }

        let rawIncome = incomeText.isEmpty ? nil : parsedCents(incomeText)
        let rawExpense = expenseText.isEmpty ? nil : parsedCents(expenseText)
        if !incomeText.isEmpty && rawIncome == nil { return (nil, "Unrecognized or out-of-range income amount.") }
        if !expenseText.isEmpty && rawExpense == nil { return (nil, "Unrecognized or out-of-range expense amount.") }
        if let rawIncome, rawIncome < 0 { return (nil, "Income-column amounts cannot be negative.") }
        if let rawExpense, rawExpense < 0 { return (nil, "Expense-column amounts cannot be negative.") }
        let income = rawIncome
        let expense = rawExpense
        let positiveIncome = (income ?? 0) > 0
        let positiveExpense = (expense ?? 0) > 0
        if positiveIncome && positiveExpense { return (nil, "Both income and expense amounts are present.") }
        if positiveIncome { return ((.income, income ?? 0), nil) }
        if positiveExpense { return ((.expense, expense ?? 0), nil) }
        return (nil, "Missing or zero income/expense amount.")
    }

    private static func parsedDirection(_ value: String) -> TransactionDirection? {
        let normalized = normalizeHeader(value)
        let income = ["income", "deposit", "credit", "receipt", "received", "in"]
        let expense = ["expense", "withdrawal", "debit", "check", "payment", "out"]
        if income.contains(normalized) { return .income }
        if expense.contains(normalized) { return .expense }
        return nil
    }

    private static func parsedCleared(_ value: String) -> (value: Bool, issue: String?) {
        guard !value.isEmpty else { return (false, nil) }
        let normalized = normalizeHeader(value)
        if ["true", "yes", "y", "1", "x", "cleared", "reconciled"].contains(normalized) { return (true, nil) }
        if ["false", "no", "n", "0", "uncleared", "outstanding", "pending"].contains(normalized) { return (false, nil) }
        return (false, "Unrecognized cleared status.")
    }

    private static func parsedDate(_ value: String, calendar: Calendar) -> Date? {
        guard !value.isEmpty else { return nil }
        // A `yyyy` pattern accepts a two-digit year ("1/15/24" becomes 15 January 0024) before the `yy`
        // patterns are ever tried, so each candidate must also land in a plausible year.
        let formats = ["yyyy-MM-dd", "M/d/yyyy", "MM/dd/yyyy", "M/d/yy", "MM/dd/yy", "MMM d, yyyy", "MMMM d, yyyy"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: value), (1900...2200).contains(calendar.component(.year, from: date)) {
                return date
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: value)
    }

    private static func parsedCents(_ value: String) -> Int64? {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let parenthesized = cleaned.hasPrefix("(") && cleaned.hasSuffix(")")
        cleaned = cleaned
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard var decimal = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        if parenthesized { decimal *= -1 }
        var scaled = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded <= Decimal(Int64.max), rounded > Decimal(Int64.min) else { return nil }
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    private static func decode(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8.hasPrefix("\u{feff}") ? String(utf8.dropFirst()) : utf8
        }
        if let windows = String(data: data, encoding: .windowsCP1252) { return windows }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Counts separators in the first logical record, ignoring delimiters embedded in quoted fields.
    private static func detectedDelimiter(in text: String) -> Character {
        var commaCount = 0
        var tabCount = 0
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if quoted, next < text.endIndex, text[next] == "\"" {
                    index = next
                } else {
                    quoted.toggle()
                }
            } else if !quoted {
                if character == "," { commaCount += 1 }
                else if character == "\t" { tabCount += 1 }
                else if character == "\n" || character == "\r" { break }
            }
            index = text.index(after: index)
        }
        return tabCount > commaCount ? "\t" : ","
    }

    private static func disambiguatedHeaders(_ rawHeaders: [String]) -> [String] {
        var counts: [String: Int] = [:]
        return rawHeaders.enumerated().map { index, raw in
            let base = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Column \(index + 1)"
                : raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalizeHeader(base)
            counts[normalized, default: 0] += 1
            let count = counts[normalized, default: 1]
            return count == 1 ? base : "\(base) (\(count))"
        }
    }

    private static func parseTable(_ text: String, delimiter: Character) -> [[String]] {
        var result: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count && characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                quoted = true
            } else if character == delimiter {
                row.append(field)
                field = ""
            } else if character == "\n" || character == "\r" {
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
                row.append(field)
                result.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            result.append(row)
        }
        return result
    }
}

/// Reads a user-selected import file only after confirming it is a regular file within the caller's size
/// limit, so an oversized selection is rejected before any of its bytes are loaded into memory.
enum ImportedFileReader {
    static func read(_ url: URL, maximumBytes: Int, tooLargeError: Error) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if values.isRegularFile == false { throw CocoaError(.fileReadUnsupportedScheme) }
        if let size = values.fileSize, size > maximumBytes { throw tooLargeError }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw tooLargeError }
        return data
    }
}

private func normalizeHeader(_ value: String) -> String {
    String(
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    ).lowercased()
}
