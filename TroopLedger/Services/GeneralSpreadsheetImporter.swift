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
            // Aliases are listed best-first; a file with both "Description" and "Payee" columns must map
            // the payee, not whichever column happens to come first.
            for alias in aliases[field, default: []].map(normalizeHeader) {
                if let index = normalized.firstIndex(of: alias) {
                    mapping[field] = index
                    break
                }
            }
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
        let headerIndex = headerRowIndex(in: table)
        guard headerIndex < table.count, !table[headerIndex].isEmpty else { throw GeneralSpreadsheetImportError.emptyFile }
        let rawHeaders = table[headerIndex]

        let headers = disambiguatedHeaders(rawHeaders)
        let rows = table.dropFirst(headerIndex + 1).enumerated().compactMap { offset, cells -> GeneralSpreadsheetRow? in
            guard cells.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
            return GeneralSpreadsheetRow(id: offset + headerIndex + 2, cells: cells)
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

    /// Fingerprints of transactions already in the destination account, so a re-exported bank file (whose
    /// bytes differ from the first export) does not post every transaction a second time.
    struct ExistingTransactionIndex {
        private var keys: Set<String> = []

        init(transactions: [LedgerTransaction], accountID: UUID?, calendar: Calendar = .current) {
            for transaction in transactions where transaction.accountID == accountID && !transaction.isTransfer {
                for key in Self.keys(day: calendar.startOfDay(for: transaction.date), direction: transaction.direction, amountCents: transaction.amountCents, payee: transaction.payee, reference: transaction.checkNumber) {
                    keys.insert(key)
                }
            }
        }

        func matches(day: Date, direction: TransactionDirection, amountCents: Int64, payee: String, reference: String) -> Bool {
            Self.keys(day: day, direction: direction, amountCents: amountCents, payee: payee, reference: reference).contains { keys.contains($0) }
        }

        private static func keys(day: Date, direction: TransactionDirection, amountCents: Int64, payee: String, reference: String) -> [String] {
            let base = "\(Int(day.timeIntervalSince1970))|\(direction.rawValue)|\(amountCents)"
            var result: [String] = []
            let normalizedPayee = normalizeHeader(payee)
            if !normalizedPayee.isEmpty { result.append("\(base)|payee:\(normalizedPayee)") }
            let normalizedReference = normalizeHeader(reference)
            if !normalizedReference.isEmpty { result.append("\(base)|ref:\(normalizedReference)") }
            return result
        }
    }

    static func preview(
        document: GeneralSpreadsheetDocument,
        mapping: TransactionColumnMapping,
        accountID: UUID?,
        defaultDirection: TransactionDirection,
        defaultCategory: String,
        reconciliations: [ReconciliationRecord],
        existingTransactions: [LedgerTransaction] = [],
        calendar: Calendar = .current
    ) -> GeneralSpreadsheetPreview {
        let mappingIssues = validate(mapping: mapping, headers: document.headers, accountID: accountID)
        guard mappingIssues.isEmpty else {
            return GeneralSpreadsheetPreview(
                mappingIssues: mappingIssues,
                rows: document.rows.map { .init(sourceRow: $0.id, draft: nil, issues: ["Complete the field mapping above."]) }
            )
        }
        let existing = ExistingTransactionIndex(transactions: existingTransactions, accountID: accountID, calendar: calendar)
        let rows = document.rows.map { row in
            previewRow(
                row,
                mapping: mapping,
                accountID: accountID,
                defaultDirection: defaultDirection,
                defaultCategory: defaultCategory,
                reconciliations: reconciliations,
                existing: existing,
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
            existingTransactions: try modelContext.fetch(FetchDescriptor<LedgerTransaction>()),
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
        existing: ExistingTransactionIndex,
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

        if existing.matches(
            day: calendar.startOfDay(for: date),
            direction: amount.direction,
            amountCents: amount.cents,
            payee: row.value(at: mapping[.payee]),
            reference: row.value(at: mapping[.reference])
        ) {
            issues.append("Matches a transaction already in this account on the same day with the same amount and payee or reference; likely a duplicate.")
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
        let income = ["income", "deposit", "credit", "receipt", "received", "in", "cr"]
        let expense = ["expense", "withdrawal", "debit", "check", "payment", "out", "dr"]
        if income.contains(normalized) { return .income }
        if expense.contains(normalized) { return .expense }
        // Bank "Type" columns rarely say just "debit": "ACH Debit", "POS Purchase", "Check Card Payment",
        // "Interest Paid", "Credit Card Payment". Expense words win so "credit card payment" is an expense.
        let lower = value.lowercased()
        let expenseWords = ["debit", "withdraw", "purchase", "pos ", "payment", "check", "fee", "charge", "bill pay", "transfer out"]
        let incomeWords = ["credit", "deposit", "interest", "refund", "dividend", "income", "received", "transfer in", "reversal"]
        if expenseWords.contains(where: lower.contains) { return .expense }
        if incomeWords.contains(where: lower.contains) { return .income }
        return nil
    }

    private static func parsedCleared(_ value: String) -> (value: Bool, issue: String?) {
        guard !value.isEmpty else { return (false, nil) }
        let normalized = normalizeHeader(value)
        // Bank exports label settled rows "Posted"; treat the common statement vocabulary as cleared/uncleared.
        if ["true", "yes", "y", "1", "x", "c", "r", "cleared", "reconciled", "posted", "settled", "complete", "completed"].contains(normalized) { return (true, nil) }
        if ["false", "no", "n", "0", "uncleared", "outstanding", "pending", "unposted", "hold", "processing"].contains(normalized) { return (false, nil) }
        return (false, "Unrecognized cleared status.")
    }

    private static func parsedDate(_ value: String, calendar: Calendar) -> Date? {
        guard !value.isEmpty else { return nil }
        // A `yyyy` pattern accepts a two-digit year ("1/15/24" becomes 15 January 0024) before the `yy`
        // patterns are ever tried, so each candidate must also land in a plausible year.
        // ICU matches punctuation loosely, so "01.09.2026" would satisfy "M/d/yyyy" as January 9. Dotted
        // values are day-first European dates and get only the dotted patterns.
        let dotted = value.contains(".") && !value.contains("/") && !value.contains("-")
        let formats = dotted ? ["dd.MM.yyyy", "d.M.yyyy", "dd.MM.yy"] : [
            "yyyy-MM-dd", "M/d/yyyy", "MM/dd/yyyy", "M/d/yy", "MM/dd/yy", "MMM d, yyyy", "MMMM d, yyyy",
            // Bank and card exports frequently carry a time of day.
            "M/d/yyyy H:mm:ss", "M/d/yyyy H:mm", "M/d/yyyy h:mm a", "M/d/yyyy h:mm:ss a", "M/d/yy H:mm",
            "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "MM-dd-yyyy", "M-d-yyyy",
        ]
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
        // Some statements write debits as "12.50-" or with a CR/DR suffix instead of a leading sign.
        let trailingMinus = cleaned.hasSuffix("-")
        let uppercased = cleaned.uppercased()
        let debitSuffix = uppercased.hasSuffix("DR") || uppercased.hasSuffix(" DB")
        cleaned = cleaned
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["CR", "DR", "DB", "cr", "dr", "db", "-"] where cleaned.hasSuffix(suffix) {
            cleaned = String(cleaned.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // "12,50" in a European export is twelve euros fifty, not twelve hundred and fifty: a comma followed by
        // exactly two digits with no later period is the decimal separator.
        if let lastComma = cleaned.lastIndex(of: ","),
           cleaned.distance(from: cleaned.index(after: lastComma), to: cleaned.endIndex) == 2,
           cleaned[cleaned.index(after: lastComma)...].allSatisfy(\.isNumber),
           cleaned.lastIndex(of: ".").map({ $0 < lastComma }) ?? true {
            cleaned = cleaned.replacingOccurrences(of: ".", with: "")
            cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
        }
        cleaned = cleaned.replacingOccurrences(of: ",", with: "")
        guard var decimal = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        if parenthesized || trailingMinus || debitSuffix { decimal = -abs(decimal) }
        var scaled = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded <= Decimal(Money.maximumCents), rounded >= Decimal(-Money.maximumCents) else { return nil }
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    private static func decode(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8.hasPrefix("\u{feff}") ? String(utf8.dropFirst()) : utf8
        }
        if let windows = String(data: data, encoding: .windowsCP1252) { return windows }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Bank exports often open with summary lines ("Beginning balance as of ...") before the real header.
    /// The header is the first row whose cells include a recognizable date column; otherwise the first row.
    static func headerRowIndex(in table: [[String]]) -> Int {
        let dateNames: Set<String> = ["date", "transactiondate", "posteddate", "postingdate", "entrydate", "datum"]
        for (index, row) in table.prefix(25).enumerated() {
            let cells = row.map(normalizeHeader)
            if cells.contains(where: dateNames.contains), cells.filter({ !$0.isEmpty }).count >= 2 { return index }
        }
        return table.firstIndex { row in row.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count >= 2 } ?? 0
    }

    /// Picks the separator (comma, tab, or semicolon) that appears most on any of the first lines, counted
    /// outside quoted fields, so title lines without separators and European semicolon files both work.
    private static func detectedDelimiter(in text: String) -> Character {
        var best: (Character, Int) = (",", 0)
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }).prefix(25) {
            var counts: [Character: Int] = [",": 0, "\t": 0, ";": 0]
            var quoted = false
            for character in line {
                if character == "\"" { quoted.toggle(); continue }
                guard !quoted, counts[character] != nil else { continue }
                counts[character, default: 0] += 1
            }
            for (delimiter, count) in counts where count > best.1 { best = (delimiter, count) }
        }
        return best.0
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

    /// Longest value kept for a single cell. A CloudKit record is limited to about 1 MB, so one multi-megabyte
    /// memo cell would make its transaction unsyncable; nothing legitimate in a register needs more than this.
    static let maximumCellLength = 10_000

    private static func parseTable(_ text: String, delimiter: Character) -> [[String]] {
        var result: [[String]] = []
        var row: [String] = []
        var field = ""
        var fieldLength = 0
        var quoted = false
        let characters = Array(text)
        var index = 0
        func append(_ character: Character) {
            if fieldLength < maximumCellLength { field.append(character) }
            fieldLength += 1
        }
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count && characters[index + 1] == "\"" {
                        append("\"")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    append(character)
                }
            } else if character == "\"" && field.isEmpty {
                quoted = true
            } else if character == delimiter {
                row.append(field)
                field = ""
                fieldLength = 0
            } else if character == "\n" || character == "\r" {
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
                row.append(field)
                result.append(row)
                row = []
                field = ""
                fieldLength = 0
            } else {
                append(character)
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
