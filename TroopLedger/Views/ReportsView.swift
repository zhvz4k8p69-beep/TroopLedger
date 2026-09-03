import SwiftUI
import SwiftData

struct ReportsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TroopProfileRecord.modifiedAt, order: .reverse) private var troopProfiles: [TroopProfileRecord]
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query private var transactions: [LedgerTransaction]
    @Query private var people: [PersonRecord]
    @Query private var memberEntries: [MemberLedgerEntry]
    @Query private var budgets: [OperatingBudgetRecord]
    @Query private var budgetLines: [BudgetLineRecord]
    @AppStorage("reports.reportingYearBasis") private var reportingYearBasisRaw = ReportingYearBasis.schoolYear.rawValue
    @State private var selectedYear = ReportingYearBasis.schoolYear.startingYear(containing: Date())
    @State private var initializedReportingYear = false
    @State private var backupDocument: PlaintextBackupDocument?
    @State private var backupFilename = PlaintextBackupService.defaultFilename()
    @State private var backupRecordCount = 0
    @State private var showingBackupExporter = false
    @State private var backupMessage: String?
    @State private var backupError: String?

    private var reportingYearBasis: ReportingYearBasis {
        ReportingYearBasis(rawValue: reportingYearBasisRaw) ?? .schoolYear
    }
    private var reportingYearBasisSelection: Binding<ReportingYearBasis> {
        Binding(
            get: { reportingYearBasis },
            set: { newValue in
                reportingYearBasisRaw = newValue.rawValue
                selectedYear = newValue.startingYear(containing: Date())
            }
        )
    }
    private var reportingPeriod: ReportingPeriod {
        ReportingPeriod(basis: reportingYearBasis, startingYear: selectedYear)
    }
    private var years: [Int] {
        let currentYear = reportingYearBasis.startingYear(containing: Date())
        let transactionYears = transactions.map { reportingYearBasis.startingYear(containing: $0.date) }
        let budgetYears = reportingYearBasis == .schoolYear ? budgets.map(\.reportingYearStart) : []
        let values = Set(transactionYears + budgetYears + [currentYear, selectedYear])
        return values.sorted(by: >)
    }
    private var annual: AnnualReport { FinanceEngine.annualReport(period: reportingPeriod, transactions: transactions) }
    private var reportBudget: OperatingBudgetRecord? {
        guard reportingYearBasis == .schoolYear else { return nil }
        let matching = budgets.filter { $0.reportingYearStart == selectedYear }
        let approved = matching.filter { $0.status == .approved }.max {
            ($0.approvedAt ?? $0.modifiedAt) < ($1.approvedAt ?? $1.modifiedAt)
        }
        return approved ?? matching.filter { $0.status == .working }.max { $0.modifiedAt < $1.modifiedAt }
    }
    private var reportBudgetLines: [BudgetLineRecord] {
        guard let reportBudget else { return [] }
        return budgetLines.filter { $0.budgetID == reportBudget.id }
    }
    private var budgetVariance: BudgetVarianceReport? {
        guard reportBudget != nil else { return nil }
        return BudgetEngine.varianceReport(period: reportingPeriod, transactions: transactions, budgetLines: reportBudgetLines)
    }
    private var budgetSourceLabel: String {
        guard let reportBudget else { return "" }
        return reportBudget.status == .approved ? "Approved Revision \(reportBudget.revision)" : "Working Budget"
    }
    private var cashPosition: CashPosition { FinanceEngine.cashPosition(accounts: accounts, transactions: transactions) }
    private var reportableAccounts: [AccountRecord] {
        accounts.filter { $0.isActive || FinanceEngine.bookBalance(account: $0, transactions: transactions) != 0 }
    }
    private var dueToTroop: Int64 {
        people.reduce(0) { $0 + max(0, FinanceEngine.memberBalance(personID: $1.id, entries: memberEntries)) }
    }
    private var memberCredits: Int64 {
        people.reduce(0) { $0 + min(0, FinanceEngine.memberBalance(personID: $1.id, entries: memberEntries)) }
    }

    var body: some View {
        List {
            Section {
                TroopReportHeader(
                    profile: troopProfiles.first,
                    reportTitle: "Treasurer Reports",
                    subtitle: reportingPeriod.dateRangeLabel()
                )
            }

            Section("Reporting Period") {
                Picker("Report type", selection: reportingYearBasisSelection) {
                    ForEach(ReportingYearBasis.allCases) { basis in
                        Text(basis.rawValue).tag(basis)
                    }
                }
                .pickerStyle(.segmented)

                Picker(reportingYearBasis.yearPickerLabel, selection: $selectedYear) {
                    ForEach(years, id: \.self) { year in
                        Text(ReportingPeriod(basis: reportingYearBasis, startingYear: year).pickerLabel).tag(year)
                    }
                }
                LabeledContent("Dates", value: reportingPeriod.dateRangeLabel())
            }

            Section("Income — \(reportingPeriod.label)") {
                ForEach(annual.income) { total in reportRow(total.category, total.amountCents) }
                if annual.income.isEmpty { Text("No income in \(reportingPeriod.label)").foregroundStyle(.secondary) }
                reportRow("Total income", annual.totalIncomeCents, emphasized: true)
            }

            Section("Expenses — \(reportingPeriod.label)") {
                ForEach(annual.expenses) { total in reportRow(total.category, total.amountCents) }
                if annual.expenses.isEmpty { Text("No expenses in \(reportingPeriod.label)").foregroundStyle(.secondary) }
                reportRow("Total expenses", annual.totalExpenseCents, emphasized: true)
                reportRow("Net income / (loss)", annual.netCents, emphasized: true, colorBySign: true)
            }

            if reportingYearBasis == .schoolYear {
                Section("Budget to Actual — \(budgetSourceLabel.isEmpty ? reportingPeriod.label : budgetSourceLabel)") {
                    if let budgetVariance {
                        budgetVarianceRows("Income", lines: budgetVariance.income)
                        budgetVarianceRows("Expenses", lines: budgetVariance.expenses)
                        Divider()
                        varianceSummaryRow(
                            "Planned surplus / (deficit)",
                            budget: budgetVariance.budgetNetCents,
                            actual: budgetVariance.actualNetCents,
                            variance: budgetVariance.netVarianceCents,
                            emphasized: true
                        )
                        Text("Positive variance is favorable: income above plan or expenses below plan. Reports use the newest approved revision, falling back to the working budget when none is approved.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No budget exists for \(reportingPeriod.label). Create a working budget in Budget to compare planned and actual activity.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Balance Report as of Today") {
                ForEach(reportableAccounts) { account in
                    reportRow(account.name, FinanceEngine.bookBalance(account: account, transactions: transactions))
                }
                Divider()
                reportRow("Bank and cash on hand", cashPosition.bankAndCashOnHandCents)
                reportRow("Undeposited funds awaiting deposit", cashPosition.undepositedFundsCents, colorBySign: true)
                reportRow("Total cash", cashPosition.totalCents, emphasized: true)
                reportRow("Member balances due to troop", dueToTroop)
                reportRow("Member credits owed", memberCredits, colorBySign: true)
                reportRow("Available after member credits", cashPosition.totalCents + memberCredits, emphasized: true, colorBySign: true)
            }

            Section("Reimbursement Oversight") {
                NavigationLink {
                    ReimbursementApprovalReportView()
                } label: {
                    Label("Approval Exceptions & Audit Report", systemImage: "checklist.checked")
                }
                Text("Review missing receipts, approval evidence, configured signer controls, and payment links. Export a complete approval and audit CSV for every reimbursement request.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Family Statements") {
                NavigationLink {
                    FamilyStatementListView()
                } label: {
                    Label("Create & Export Family Statements", systemImage: "doc.text")
                }
                Text("Group existing people into families, review their combined charges, payments, credits, current balance, and upcoming due items, then export a private PDF through the system sheet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Treasurer Operations") {
                NavigationLink {
                    TreasurerReportCenterView()
                } label: {
                    Label("Monthly & Committee Reports", systemImage: "doc.richtext")
                }
                NavigationLink {
                    RecharterForecastView()
                } label: {
                    Label("Recharter Cash Forecast", systemImage: "calendar.badge.clock")
                }
                NavigationLink {
                    AnnualAuditExportView()
                } label: {
                    Label("Annual Audit & Turnover Package", systemImage: "shippingbox")
                }
            }

            Section("Data Portability") {
                Button("Export Full Plaintext Backup", systemImage: "externaldrive.badge.plus") {
                    prepareBackup()
                }
                Text("Creates a self-contained package with complete JSON, normalized CSV files, the audit log, import history, and an attachment manifest. It includes private financial, contact, and calendar-subscription data; store it securely.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Report Basis") {
                Text("School-year reports cover September 1 through August 31. Calendar-year reports remain available for January through December. Income and expenses use transaction dates and categories. Balance reports use account opening balances plus all entered transactions. Undeposited Funds is shown separately from bank accounts and Cash on Hand while remaining part of total cash. Member balances are shown separately so Scout credits are not confused with troop cash.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .pageHeader(title: "Reports")
        .onAppear {
            guard !initializedReportingYear else { return }
            selectedYear = reportingYearBasis.startingYear(containing: Date())
            initializedReportingYear = true
        }
        .fileExporter(
            isPresented: $showingBackupExporter,
            document: backupDocument,
            contentType: .troopLedgerBackup,
            defaultFilename: backupFilename
        ) { result in
            completeBackupExport(result)
        }
        .alert("Plaintext Backup", isPresented: Binding(
            get: { backupMessage != nil || backupError != nil },
            set: { if !$0 { backupMessage = nil; backupError = nil } }
        )) {
            Button("OK") { backupMessage = nil; backupError = nil }
        } message: {
            Text(backupError ?? backupMessage ?? "")
        }
    }

    private func prepareBackup() {
        do {
            try modelContext.save()
            let exportedAt = Date()
            let archive = try PlaintextBackupService.makeArchive(from: modelContext, exportedAt: exportedAt)
            backupDocument = PlaintextBackupDocument(files: archive.files)
            backupFilename = PlaintextBackupService.defaultFilename(at: exportedAt)
            backupRecordCount = archive.recordCounts.values.reduce(0, +)
            showingBackupExporter = true
        } catch {
            backupError = "The backup could not be prepared: \(error.localizedDescription)"
        }
    }

    private func completeBackupExport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            AuditLogger.record(
                .export,
                recordType: "Plaintext Backup",
                recordID: nil,
                summary: "Exported full plaintext backup",
                details: AuditLogger.details([
                    ("File", url.lastPathComponent),
                    ("Records", String(backupRecordCount)),
                    ("Format version", String(PlaintextBackupService.formatVersion)),
                ]),
                in: modelContext
            )
            do {
                try modelContext.save()
                backupMessage = "Backup exported successfully with \(backupRecordCount) records."
            } catch {
                backupError = "The backup was exported, but its audit entry could not be saved: \(error.localizedDescription)"
            }
        case .failure(let error):
            let nsError = error as NSError
            guard !(error is CancellationError), nsError.code != NSUserCancelledError else { return }
            backupError = "The backup could not be exported: \(error.localizedDescription)"
        }
    }

    private func reportRow(_ label: String, _ cents: Int64, emphasized: Bool = false, colorBySign: Bool = false) -> some View {
        HStack {
            Text(label).fontWeight(emphasized ? .semibold : .regular)
            Spacer()
            MoneyText(cents: cents, colorBySign: colorBySign).fontWeight(emphasized ? .semibold : .regular)
        }
    }

    @ViewBuilder
    private func budgetVarianceRows(_ title: String, lines: [BudgetVarianceLine]) -> some View {
        if !lines.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(lines) { line in
                varianceSummaryRow(
                    line.categoryName,
                    budget: line.budgetCents,
                    actual: line.actualCents,
                    variance: line.varianceCents
                )
            }
        }
    }

    private func varianceSummaryRow(
        _ label: String,
        budget: Int64,
        actual: Int64,
        variance: Int64,
        emphasized: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).fontWeight(emphasized ? .semibold : .regular)
                Spacer()
                MoneyText(cents: variance, colorBySign: true)
                    .fontWeight(emphasized ? .semibold : .regular)
            }
            Text("Budget \(Money.currency(cents: budget)) • Actual \(Money.currency(cents: actual))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
