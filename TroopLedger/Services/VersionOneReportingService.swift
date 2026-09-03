import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let troopLedgerCommitteePackage = UTType(exportedAs: "com.bettnet.troopledger.committee-report", conformingTo: .package)
    static let troopLedgerAuditPackage = UTType(exportedAs: "com.bettnet.troopledger.audit-package", conformingTo: .package)
}

struct TroopLedgerPackageDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.troopLedgerCommitteePackage, .troopLedgerAuditPackage] }
    let files: [String: Data]

    init(files: [String: Data]) { self.files = files }

    init(configuration: ReadConfiguration) throws {
        guard configuration.file.isDirectory else { throw CocoaError(.fileReadCorruptFile) }
        files = [:]
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        PlaintextBackupDocument(files: files).makeFileWrapper()
    }
}

struct ReconciliationReportStatus: Identifiable, Equatable {
    let accountID: UUID
    let accountName: String
    let statementDate: Date?
    let statementBalanceCents: Int64?
    let differenceCents: Int64?
    var id: UUID { accountID }
}

struct TreasurerReportSnapshot: Equatable {
    let troop: TroopReportIdentity
    let title: String
    let periodStart: Date
    let periodEnd: Date
    let generatedAt: Date
    let openingCashCents: Int64
    let endingBankAndCashCents: Int64
    let endingUndepositedCents: Int64
    let endingCashCents: Int64
    let income: [CategoryTotal]
    let expenses: [CategoryTotal]
    let outstandingMemberCents: Int64
    let memberCreditCents: Int64
    let budgetVariance: BudgetVarianceReport?
    let budgetLabel: String
    let reconciliationStatus: [ReconciliationReportStatus]

    var totalIncomeCents: Int64 { income.reduce(0) { $0 + $1.amountCents } }
    var totalExpenseCents: Int64 { expenses.reduce(0) { $0 + $1.amountCents } }
    var netCents: Int64 { totalIncomeCents - totalExpenseCents }
}

enum TreasurerReportService {
    static func makeSnapshot(
        title: String,
        periodStart: Date,
        periodEnd: Date,
        profile: TroopProfileRecord?,
        accounts: [AccountRecord],
        transactions: [LedgerTransaction],
        people: [PersonRecord],
        memberEntries: [MemberLedgerEntry],
        reconciliations: [ReconciliationRecord],
        budget: OperatingBudgetRecord? = nil,
        budgetLines: [BudgetLineRecord] = [],
        generatedAt: Date = Date(),
        calendar: Calendar = .current
    ) -> TreasurerReportSnapshot {
        let start = calendar.startOfDay(for: periodStart)
        let end = calendar.startOfDay(for: periodEnd)
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: end) ?? end.addingTimeInterval(86_400)
        let periodTransactions = transactions.filter { $0.date >= start && $0.date < endExclusive && !$0.isTransfer }
        let annual = annualReport(for: periodTransactions)
        let opening = cashPosition(accounts: accounts, transactions: transactions.filter { $0.date < start })
        let endingTransactions = transactions.filter { $0.date < endExclusive }
        let ending = cashPosition(accounts: accounts, transactions: endingTransactions)
        let balances = Dictionary(grouping: memberEntries.filter { $0.date < endExclusive }, by: \.personID)
        let outstanding = people.reduce(Int64(0)) { total, person in
            total + max(0, balances[person.id]?.reduce(Int64(0)) { $0 + $1.balanceEffectCents } ?? 0)
        }
        let credits = people.reduce(Int64(0)) { total, person in
            total + min(0, balances[person.id]?.reduce(Int64(0)) { $0 + $1.balanceEffectCents } ?? 0)
        }
        let reportPeriod = ReportingPeriod.containing(end, basis: .schoolYear, calendar: calendar)
        let variance = budget.map { _ in
            BudgetEngine.varianceReport(
                period: reportPeriod,
                transactions: transactions.filter { $0.date < endExclusive },
                budgetLines: budgetLines
            )
        }
        let budgetLabel = budget.map {
            "\($0.status == .approved ? "Approved Revision \($0.revision)" : "Working Budget") • \(reportPeriod.label) year to date"
        } ?? ""
        let reportAccounts = accounts.filter { account in
            (account.isActive || FinanceEngine.bookBalance(account: account, transactions: endingTransactions) != 0)
                && account.kind != .cash
                && account.kind != .undepositedFunds
        }
        var statuses: [ReconciliationReportStatus] = []
        for account in reportAccounts {
            let latest = reconciliations
                .filter { $0.accountID == account.id && $0.statementDate < endExclusive }
                .max { $0.statementDate < $1.statementDate }
            statuses.append(ReconciliationReportStatus(
                accountID: account.id,
                accountName: account.name,
                statementDate: latest?.statementDate,
                statementBalanceCents: latest?.statementEndingBalanceCents,
                differenceCents: latest.map { $0.clearedBalanceCents - $0.statementEndingBalanceCents }
            ))
        }
        statuses.sort { $0.accountName.localizedStandardCompare($1.accountName) == .orderedAscending }

        return TreasurerReportSnapshot(
            troop: TroopReportIdentity(profile: profile),
            title: title,
            periodStart: start,
            periodEnd: end,
            generatedAt: generatedAt,
            openingCashCents: opening.totalCents,
            endingBankAndCashCents: ending.bankAndCashOnHandCents,
            endingUndepositedCents: ending.undepositedFundsCents,
            endingCashCents: ending.totalCents,
            income: annual.income,
            expenses: annual.expenses,
            outstandingMemberCents: outstanding,
            memberCreditCents: credits,
            budgetVariance: variance,
            budgetLabel: budgetLabel,
            reconciliationStatus: statuses
        )
    }

    static func monthInterval(containing date: Date, calendar: Calendar = .current) -> (Date, Date) {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        let next = calendar.date(byAdding: .month, value: 1, to: start) ?? date
        return (start, calendar.date(byAdding: .day, value: -1, to: next) ?? next)
    }

    static func summaryCSV(_ report: TreasurerReportSnapshot) -> String {
        let rows: [[String]] = [
            ["metric", "value_cents", "detail"],
            ["opening_cash", String(report.openingCashCents), ""],
            ["income", String(report.totalIncomeCents), ""],
            ["expenses", String(report.totalExpenseCents), ""],
            ["net", String(report.netCents), ""],
            ["ending_bank_and_cash", String(report.endingBankAndCashCents), ""],
            ["undeposited_funds", String(report.endingUndepositedCents), ""],
            ["ending_total_cash", String(report.endingCashCents), ""],
            ["member_balances_due", String(report.outstandingMemberCents), ""],
            ["member_credits", String(report.memberCreditCents), ""],
        ]
        return csv(rows)
    }

    static func registerCSV(transactions: [LedgerTransaction], start: Date, end: Date, calendar: Calendar = .current) -> String {
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end.addingTimeInterval(86_400)
        let rows = transactions.filter { $0.date >= calendar.startOfDay(for: start) && $0.date < endExclusive }
            .sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
            .map { transaction in
                [transaction.id.uuidString.lowercased(), iso(transaction.date), transaction.direction.rawValue, String(transaction.amountCents), transaction.payee, transaction.category, transaction.checkNumber, transaction.memo, transaction.accountID?.uuidString.lowercased() ?? "", transaction.eventID?.uuidString.lowercased() ?? "", String(transaction.isCleared), String(transaction.isTransfer)]
            }
        return csv([["id", "date", "direction", "amount_cents", "payee", "category", "reference", "memo", "account_id", "event_id", "cleared", "transfer"]] + rows)
    }

    static func budgetVarianceCSV(_ report: TreasurerReportSnapshot) -> String {
        guard let variance = report.budgetVariance else { return csv([["direction", "category", "budget_cents", "actual_cents", "variance_cents"]]) }
        let income = variance.income.map { ["Income", $0.categoryName, String($0.budgetCents), String($0.actualCents), String($0.varianceCents)] }
        let expense = variance.expenses.map { ["Expense", $0.categoryName, String($0.budgetCents), String($0.actualCents), String($0.varianceCents)] }
        return csv([["direction", "category", "budget_cents", "actual_cents", "variance_cents"]] + income + expense)
    }

    static func defaultMonthlyFilename(for report: TreasurerReportSnapshot, calendar: Calendar = .current) -> String {
        // periodEnd is a local-midnight date; formatting it in UTC names the file for the previous day east of Greenwich.
        let components = calendar.dateComponents([.year, .month], from: report.periodEnd)
        return String(format: "TroopLedger Treasurer Report %04d-%02d.pdf", components.year ?? 0, components.month ?? 0)
    }

    fileprivate static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    fileprivate static func csvField(_ value: String) -> String {
        CSVFormatting.field(value)
    }

    fileprivate static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private static func cashPosition(accounts: [AccountRecord], transactions: [LedgerTransaction]) -> CashPosition {
        FinanceEngine.cashPosition(accounts: accounts, transactions: transactions)
    }

    private static func annualReport(for transactions: [LedgerTransaction]) -> AnnualReport {
        func totals(_ direction: TransactionDirection) -> [CategoryTotal] {
            Dictionary(grouping: transactions.filter { $0.direction == direction }, by: { $0.category.isEmpty ? "Uncategorized" : $0.category })
                .map { CategoryTotal(category: $0.key, amountCents: $0.value.reduce(Int64(0)) { $0 + $1.amountCents }) }
                .sorted { $0.category.localizedStandardCompare($1.category) == .orderedAscending }
        }
        return AnnualReport(income: totals(.income), expenses: totals(.expense))
    }
}

struct TreasurerReportPDFDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

enum TreasurerReportPDFRenderer {
    static func render(_ report: TreasurerReportSnapshot) -> Data? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        var writer = PDFTextWriter(context: context, box: box)
        writer.beginPage()
        writer.heading(report.troop.formalName, size: 18)
        if !report.troop.organizationLine.isEmpty { writer.line(report.troop.organizationLine, color: 0.35) }
        writer.heading(report.title, size: 15)
        writer.line("\(report.periodStart.formatted(date: .long, time: .omitted)) through \(report.periodEnd.formatted(date: .long, time: .omitted))")
        writer.line("Generated \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))", color: 0.4)
        writer.space(10)
        writer.section("Cash Summary")
        writer.money("Opening cash", report.openingCashCents)
        writer.money("Income", report.totalIncomeCents)
        writer.money("Expenses", -report.totalExpenseCents)
        writer.money("Net activity", report.netCents)
        writer.money("Bank and Cash on Hand", report.endingBankAndCashCents)
        writer.money("Undeposited Funds", report.endingUndepositedCents)
        writer.money("Ending total cash", report.endingCashCents, bold: true)
        writer.section("Activity by Category")
        if report.income.isEmpty { writer.line("No income in this period.", color: 0.4) }
        for row in report.income { writer.money("Income — \(row.category)", row.amountCents) }
        if report.expenses.isEmpty { writer.line("No expenses in this period.", color: 0.4) }
        for row in report.expenses { writer.money("Expense — \(row.category)", -row.amountCents) }
        writer.section("Member Balances")
        writer.money("Due to troop", report.outstandingMemberCents)
        writer.money("Credits owed to families", report.memberCreditCents)
        if let variance = report.budgetVariance {
            writer.section("Budget Variance")
            writer.line(report.budgetLabel, color: 0.35)
            for row in variance.income { writer.money("Income — \(row.categoryName)", row.varianceCents) }
            for row in variance.expenses { writer.money("Expense — \(row.categoryName)", row.varianceCents) }
            writer.money("Net favorable / (unfavorable)", variance.netVarianceCents, bold: true)
        }
        writer.section("Reconciliation Status")
        if report.reconciliationStatus.isEmpty { writer.line("No active bank accounts.", color: 0.4) }
        for status in report.reconciliationStatus {
            if let date = status.statementDate {
                writer.line("\(status.accountName): reconciled through \(date.formatted(date: .abbreviated, time: .omitted)); difference \(Money.currency(cents: status.differenceCents ?? 0))")
            } else {
                writer.line("\(status.accountName): no completed reconciliation through report date")
            }
        }
        if !report.troop.treasurerLine.isEmpty {
            writer.space(16)
            writer.line(report.troop.treasurerLine)
        }
        writer.finish()
        return data as Data
    }
}

enum CommitteeReportPackageService {
    static func makeFiles(report: TreasurerReportSnapshot, transactions: [LedgerTransaction]) throws -> [String: Data] {
        guard let pdf = TreasurerReportPDFRenderer.render(report) else { throw CocoaError(.fileWriteUnknown) }
        var files: [String: Data] = [
            "treasurer-report.pdf": pdf,
            "summary.csv": Data(TreasurerReportService.summaryCSV(report).utf8),
            "register.csv": Data(TreasurerReportService.registerCSV(transactions: transactions, start: report.periodStart, end: report.periodEnd).utf8),
            "budget-variance.csv": Data(TreasurerReportService.budgetVarianceCSV(report).utf8),
            "README.txt": Data("This dated read-only committee snapshot contains a rendered treasurer report and portable CSV detail. Verify every file against manifest-sha256.csv before review. It contains private troop financial data.\n".utf8),
        ]
        files["manifest-sha256.csv"] = manifest(for: files)
        return files
    }

    static func defaultFilename(for report: TreasurerReportSnapshot, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: report.periodEnd)
        return String(format: "TroopLedger Committee Snapshot %04d-%02d-%02d.troopledgercommittee", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    fileprivate static func manifest(for files: [String: Data]) -> Data {
        let rows = [["path", "byte_count", "sha256"]] + files.sorted { $0.key < $1.key }.map { path, data in
            [path, String(data.count), SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        }
        return Data(TreasurerReportService.csv(rows).utf8)
    }
}

@MainActor
enum AnnualAuditPackageService {
    static func makeFiles(
        from context: ModelContext,
        period: ReportingPeriod,
        generatedAt: Date = Date()
    ) throws -> [String: Data] {
        let profiles = try context.fetch(FetchDescriptor<TroopProfileRecord>()).sorted { $0.modifiedAt > $1.modifiedAt }
        let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())
        let people = try context.fetch(FetchDescriptor<PersonRecord>())
        let memberEntries = try context.fetch(FetchDescriptor<MemberLedgerEntry>())
        let reconciliations = try context.fetch(FetchDescriptor<ReconciliationRecord>())
        let budgets = try context.fetch(FetchDescriptor<OperatingBudgetRecord>())
        let budgetLines = try context.fetch(FetchDescriptor<BudgetLineRecord>())
        let requests = try context.fetch(FetchDescriptor<ReimbursementRequest>())
        let attachments = try context.fetch(FetchDescriptor<ReimbursementAttachment>())
        let settings = try context.fetch(FetchDescriptor<DisbursementControlSettings>()).first
        let audit = try context.fetch(FetchDescriptor<AuditLogEntry>())
        let inclusiveEnd = Calendar.current.date(byAdding: .day, value: -1, to: period.endDateExclusive) ?? period.endDateExclusive
        let matchingBudgets = budgets.filter { $0.reportingYearStart == period.startingYear }
        let budget = matchingBudgets.filter { $0.status == .approved }.max { ($0.approvedAt ?? $0.modifiedAt) < ($1.approvedAt ?? $1.modifiedAt) }
            ?? matchingBudgets.filter { $0.status == .working }.max { $0.modifiedAt < $1.modifiedAt }
        let report = TreasurerReportService.makeSnapshot(
            title: "Annual Treasurer and Audit Report",
            periodStart: period.startDate,
            periodEnd: inclusiveEnd,
            profile: profiles.first,
            accounts: accounts,
            transactions: transactions,
            people: people,
            memberEntries: memberEntries,
            reconciliations: reconciliations,
            budget: budget,
            budgetLines: budget.map { selected in budgetLines.filter { $0.budgetID == selected.id } } ?? [],
            generatedAt: generatedAt
        )
        guard let pdf = TreasurerReportPDFRenderer.render(report) else { throw CocoaError(.fileWriteUnknown) }
        let approvalReport = ReimbursementApprovalReportService.makeReport(
            requests: requests,
            attachments: attachments,
            transactions: transactions,
            people: people,
            auditEntries: audit,
            policy: DisbursementControlPolicy(settings: settings),
            generatedAt: generatedAt
        )
        let backup = try PlaintextBackupService.makeArchive(from: context, exportedAt: generatedAt)
        var files = backup.files.reduce(into: [String: Data]()) { $0["complete-records/\($1.key)"] = $1.value }
        files["annual-treasurer-report.pdf"] = pdf
        files["annual-summary.csv"] = Data(TreasurerReportService.summaryCSV(report).utf8)
        files["annual-register.csv"] = Data(TreasurerReportService.registerCSV(transactions: transactions, start: period.startDate, end: inclusiveEnd).utf8)
        files["budget-to-actual.csv"] = Data(TreasurerReportService.budgetVarianceCSV(report).utf8)
        files["approval-exceptions.csv"] = Data(ReimbursementApprovalReportService.csv(for: approvalReport, troop: report.troop).utf8)
        files["README.txt"] = Data("TroopLedger annual audit and treasurer-turnover package for \(period.label). The complete-records directory is a full plaintext backup; the root contains period-focused reports. Verify every file against manifest-sha256.csv. This package contains private financial and contact data.\n".utf8)
        files["manifest-sha256.csv"] = CommitteeReportPackageService.manifest(for: files)
        return files
    }

    static func defaultFilename(for period: ReportingPeriod) -> String {
        "TroopLedger Audit \(period.startingYear)-\(period.startingYear + 1).troopledgeraudit"
    }
}

struct RecharterForecastSnapshot: Equatable {
    let programYear: String
    let activePersonCount: Int
    let assessedRegistrationCents: Int64
    let perPersonCostCents: Int64
    let unitCharterCostCents: Int64
    let otherCostCents: Int64
    let currentCashCents: Int64
    let expectedCollectionsCents: Int64
    var projectedRegistrationCostCents: Int64 { Int64(activePersonCount) * perPersonCostCents }
    var totalCostCents: Int64 { projectedRegistrationCostCents + unitCharterCostCents + otherCostCents }
    var projectedEndingCashCents: Int64 { currentCashCents + expectedCollectionsCents - totalCostCents }
}

enum RecharterForecastService {
    static func makeSnapshot(
        programYear: String,
        people: [PersonRecord],
        registrations: [RegistrationRecord],
        accounts: [AccountRecord],
        transactions: [LedgerTransaction],
        perPersonCostCents: Int64,
        unitCharterCostCents: Int64,
        otherCostCents: Int64,
        expectedCollectionsCents: Int64
    ) -> RecharterForecastSnapshot {
        let active = people.filter(\.isActive)
        let activeIDs = Set(active.map(\.id))
        let wantedYear = programYear.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = registrations.filter {
            $0.programYear.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wantedYear) == .orderedSame
                && $0.personID.map(activeIDs.contains) == true
        }
        return RecharterForecastSnapshot(
            programYear: programYear,
            activePersonCount: active.count,
            assessedRegistrationCents: matching.reduce(Int64(0)) { $0 + max(0, $1.duesAssessedCents) },
            perPersonCostCents: perPersonCostCents,
            unitCharterCostCents: unitCharterCostCents,
            otherCostCents: otherCostCents,
            currentCashCents: FinanceEngine.cashPosition(accounts: accounts, transactions: transactions).totalCents,
            expectedCollectionsCents: expectedCollectionsCents
        )
    }
}

private struct PDFTextWriter {
    let context: CGContext
    let box: CGRect
    var y: CGFloat = 0
    var page = 0

    mutating func beginPage() {
        context.beginPDFPage(nil)
        page += 1
        y = box.height - 42
    }

    mutating func finish() {
        context.endPDFPage()
        context.closePDF()
    }

    mutating func heading(_ value: String, size: CGFloat) {
        ensure(30)
        draw(value, size: size, bold: true, color: 0.05, height: 24)
        y -= 4
    }

    mutating func section(_ value: String) {
        ensure(34)
        y -= 8
        draw(value, size: 12, bold: true, color: 0.1, height: 18)
        context.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
        context.move(to: CGPoint(x: 42, y: y + 2))
        context.addLine(to: CGPoint(x: box.width - 42, y: y + 2))
        context.strokePath()
        y -= 3
    }

    mutating func line(_ value: String, color: CGFloat = 0.1) {
        ensure(22)
        draw(value, size: 9.5, bold: false, color: color, height: 18)
    }

    mutating func money(_ label: String, _ cents: Int64, bold: Bool = false) {
        ensure(22)
        draw(Money.currency(cents: cents), x: 432, size: 9.5, bold: bold, color: cents < 0 ? 0.45 : 0.1, height: 18, width: 138, alignment: .right, advance: false)
        draw(label, size: 9.5, bold: bold, color: 0.1, height: 18, width: 390)
    }

    mutating func space(_ points: CGFloat) { y -= points }

    private mutating func ensure(_ height: CGFloat) {
        guard y - height < 48 else { return }
        context.endPDFPage()
        beginPage()
        draw("\(page)", x: 520, size: 8, bold: false, color: 0.5, height: 14, width: 50, alignment: .right)
    }

    private mutating func draw(_ value: String, x: CGFloat = 42, size: CGFloat, bold: Bool, color: CGFloat, height: CGFloat, width: CGFloat = 528, alignment: CTTextAlignment = .left, advance: Bool = true) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: color, alpha: 1)]
        let attributed = NSAttributedString(string: value, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let drawX = alignment == .right ? x + width - lineWidth : x
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: drawX, y: y - height + 4)
        CTLineDraw(line, context)
        context.restoreGState()
        if advance { y -= height }
    }
}
