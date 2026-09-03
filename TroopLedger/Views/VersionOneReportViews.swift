import SwiftData
import SwiftUI

struct TreasurerReportCenterView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TroopProfileRecord.modifiedAt, order: .reverse) private var profiles: [TroopProfileRecord]
    @Query private var accounts: [AccountRecord]
    @Query private var transactions: [LedgerTransaction]
    @Query private var people: [PersonRecord]
    @Query private var memberEntries: [MemberLedgerEntry]
    @Query private var reconciliations: [ReconciliationRecord]
    @Query private var budgets: [OperatingBudgetRecord]
    @Query private var budgetLines: [BudgetLineRecord]
    // The current month is still open; the report that gets presented is last month's.
    @State private var selectedMonth = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var pdfDocument: TreasurerReportPDFDocument?
    @State private var packageDocument: TroopLedgerPackageDocument?
    @State private var pdfFilename = "Treasurer Report.pdf"
    @State private var packageFilename = "Committee Snapshot.troopledgercommittee"
    @State private var packageFingerprint = ""
    @State private var showingPDFExporter = false
    @State private var showingPackageExporter = false
    @State private var message: String?

    private var month: (Date, Date) { TreasurerReportService.monthInterval(containing: selectedMonth) }
    private var reportingPeriod: ReportingPeriod { .containing(month.1) }
    private var budget: OperatingBudgetRecord? {
        let matching = budgets.filter { $0.reportingYearStart == reportingPeriod.startingYear }
        return matching.filter { $0.status == .approved }.max { ($0.approvedAt ?? $0.modifiedAt) < ($1.approvedAt ?? $1.modifiedAt) }
            ?? matching.filter { $0.status == .working }.max { $0.modifiedAt < $1.modifiedAt }
    }
    private var report: TreasurerReportSnapshot {
        TreasurerReportService.makeSnapshot(
            title: "Monthly Treasurer Report",
            periodStart: month.0,
            periodEnd: month.1,
            profile: profiles.first,
            accounts: accounts,
            transactions: transactions,
            people: people,
            memberEntries: memberEntries,
            reconciliations: reconciliations,
            budget: budget,
            budgetLines: budget.map { selected in budgetLines.filter { $0.budgetID == selected.id } } ?? []
        )
    }

    var body: some View {
        List {
            Section {
                TroopReportHeader(profile: profiles.first, reportTitle: "Monthly Treasurer Report", subtitle: month.0.formatted(.dateTime.month(.wide).year()))
            }
            Section("Report Month") {
                DatePicker("Month", selection: $selectedMonth, displayedComponents: [.date])
                LabeledContent("Coverage", value: "\(month.0.formatted(date: .abbreviated, time: .omitted)) – \(month.1.formatted(date: .abbreviated, time: .omitted))")
            }
            Section("Cash Summary") {
                row("Opening cash", report.openingCashCents)
                row("Income", report.totalIncomeCents)
                row("Expenses", -report.totalExpenseCents)
                row("Net activity", report.netCents)
                row("Ending total cash", report.endingCashCents, emphasized: true)
                row("Undeposited Funds", report.endingUndepositedCents)
            }
            Section("Member Balances") {
                row("Due to troop", report.outstandingMemberCents)
                row("Family credits", report.memberCreditCents)
            }
            Section("Reconciliation") {
                if report.reconciliationStatus.isEmpty { Text("No active bank accounts").foregroundStyle(.secondary) }
                ForEach(report.reconciliationStatus) { status in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.accountName).fontWeight(.medium)
                        if let date = status.statementDate {
                            Text("Completed through \(date.formatted(date: .abbreviated, time: .omitted)) • difference \(Money.currency(cents: status.differenceCents ?? 0))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("No completed reconciliation through this month").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            Section("Export") {
                Button("Export Monthly PDF", systemImage: "doc.richtext") { preparePDF() }
                Button("Export Fingerprinted Committee Snapshot", systemImage: "shippingbox") { preparePackage() }
                Text("The committee package contains the dated PDF, CSV register and budget detail, plus a SHA-256 manifest. It is a read-only handoff, not shared database access.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .pageHeader(title: "Monthly Reports")
        .fileExporter(isPresented: $showingPDFExporter, document: pdfDocument, contentType: .pdf, defaultFilename: pdfFilename) { complete($0, kind: "monthly treasurer PDF") }
        .fileExporter(isPresented: $showingPackageExporter, document: packageDocument, contentType: .troopLedgerCommitteePackage, defaultFilename: packageFilename) { complete($0, kind: "committee snapshot") }
        .alert("Report Export", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func preparePDF() {
        guard let data = TreasurerReportPDFRenderer.render(report) else { message = "The report PDF could not be created."; return }
        pdfDocument = TreasurerReportPDFDocument(data: data)
        pdfFilename = TreasurerReportService.defaultMonthlyFilename(for: report)
        showingPDFExporter = true
    }

    private func preparePackage() {
        do {
            let files = try CommitteeReportPackageService.makeFiles(report: report, transactions: transactions)
            packageDocument = TroopLedgerPackageDocument(files: files)
            packageFilename = CommitteeReportPackageService.defaultFilename(for: report)
            packageFingerprint = CommitteeReportPackageService.fingerprint(of: files)
            showingPackageExporter = true
        } catch { message = "The committee snapshot could not be created: \(error.localizedDescription)" }
    }

    private func complete(_ result: Result<URL, Error>, kind: String) {
        switch result {
        case .success(let url):
            AuditLogger.record(.export, recordType: "Treasurer Report", recordID: nil, summary: "Exported \(kind)", details: AuditLogger.details([("File", url.lastPathComponent), ("Period", "\(month.0.formatted(date: .numeric, time: .omitted)) through \(month.1.formatted(date: .numeric, time: .omitted))"), ("Manifest SHA-256", kind == "committee snapshot" ? packageFingerprint : nil)]), in: modelContext)
            do {
                try modelContext.save()
                message = "Exported \(url.lastPathComponent)."
            } catch {
                message = "Exported \(url.lastPathComponent), but its audit entry could not be saved: \(error.localizedDescription)"
            }
        case .failure(let error):
            let nsError = error as NSError
            if !(error is CancellationError), nsError.code != NSUserCancelledError { message = "The export failed: \(error.localizedDescription)" }
        }
    }

    private func row(_ label: String, _ cents: Int64, emphasized: Bool = false) -> some View {
        HStack { Text(label).fontWeight(emphasized ? .semibold : .regular); Spacer(); MoneyText(cents: cents, colorBySign: true).fontWeight(emphasized ? .semibold : .regular) }
    }
}

struct AnnualAuditExportView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var transactions: [LedgerTransaction]
    // An audit package covers a completed school year, not the one in progress.
    @State private var selectedYear = ReportingYearBasis.schoolYear.startingYear(containing: Date()) - 1
    @State private var document: TroopLedgerPackageDocument?
    @State private var filename = "Annual Audit.troopledgeraudit"
    @State private var fingerprint = ""
    @State private var showingExporter = false
    @State private var message: String?

    private var years: [Int] {
        Array(Set(transactions.map { ReportingYearBasis.schoolYear.startingYear(containing: $0.date) } + [selectedYear])).sorted(by: >)
    }
    private var period: ReportingPeriod { ReportingPeriod(basis: .schoolYear, startingYear: selectedYear) }

    var body: some View {
        List {
            Section("School Year") {
                Picker("Year", selection: $selectedYear) { ForEach(years, id: \.self) { Text("\($0)–\($0 + 1)").tag($0) } }
                LabeledContent("Dates", value: period.dateRangeLabel())
            }
            Section("Package Contents") {
                Label("Annual PDF and summary CSV", systemImage: "doc.richtext")
                Label("Register, reconciliations, and member ledgers", systemImage: "tablecells")
                Label("Budget variance, event close-outs, and approval exceptions", systemImage: "checklist")
                Label("Receipts, attachment manifest, and append-only audit log", systemImage: "paperclip")
                Label("Complete plaintext handoff backup", systemImage: "externaldrive")
                Label("SHA-256 file manifest", systemImage: "checkmark.shield")
            }
            Section {
                Button("Export Annual Audit & Turnover Package", systemImage: "shippingbox.and.arrow.backward") { prepare() }
                Text("This self-contained package contains private financial, family, and contact information. Transfer and store it securely.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .pageHeader(title: "Annual Audit & Turnover")
        .fileExporter(isPresented: $showingExporter, document: document, contentType: .troopLedgerAuditPackage, defaultFilename: filename) { complete($0) }
        .alert("Annual Audit Export", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func prepare() {
        do {
            try modelContext.save()
            let files = try AnnualAuditPackageService.makeFiles(from: modelContext, period: period)
            document = TroopLedgerPackageDocument(files: files)
            filename = AnnualAuditPackageService.defaultFilename(for: period)
            fingerprint = CommitteeReportPackageService.fingerprint(of: files)
            showingExporter = true
        } catch { message = "The audit package could not be prepared: \(error.localizedDescription)" }
    }

    private func complete(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            AuditLogger.record(.export, recordType: "Annual Audit Package", recordID: nil, summary: "Exported annual audit and treasurer-turnover package", details: AuditLogger.details([("File", url.lastPathComponent), ("School year", period.label), ("Manifest SHA-256", fingerprint)]), in: modelContext)
            do {
                try modelContext.save()
                message = "Exported \(url.lastPathComponent)."
            } catch {
                message = "Exported \(url.lastPathComponent), but its audit entry could not be saved: \(error.localizedDescription)"
            }
        case .failure(let error):
            let nsError = error as NSError
            if !(error is CancellationError), nsError.code != NSUserCancelledError { message = "The export failed: \(error.localizedDescription)" }
        }
    }
}

struct RecharterForecastView: View {
    @Query(sort: [SortDescriptor(\PersonRecord.lastName), SortDescriptor(\PersonRecord.firstName)]) private var people: [PersonRecord]
    @Query private var registrations: [RegistrationRecord]
    @Query private var accounts: [AccountRecord]
    @Query private var transactions: [LedgerTransaction]
    @State private var programYear = String(Calendar.current.component(.year, from: Date()) + 1)
    @State private var perPersonCost = "0.00"
    @State private var unitCharterCost = "0.00"
    @State private var otherCost = "0.00"
    @State private var expectedCollections = "0.00"

    /// Program years are free text on registrations; typing a year that matches none of them silently zeroes
    /// the assessed-dues reference, so offer the years that exist.
    private var programYears: [String] {
        Array(Set(registrations.map { $0.programYear.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted(by: >)
    }

    private var snapshot: RecharterForecastSnapshot? {
        guard let per = Money.cents(from: perPersonCost), let unit = Money.cents(from: unitCharterCost), let other = Money.cents(from: otherCost), let collections = Money.cents(from: expectedCollections) else { return nil }
        return RecharterForecastService.makeSnapshot(programYear: programYear, people: people, registrations: registrations, accounts: accounts, transactions: transactions, perPersonCostCents: per, unitCharterCostCents: unit, otherCostCents: other, expectedCollectionsCents: collections)
    }

    var body: some View {
        Form {
            Section("Visible Assumptions") {
                TextField("Program year", text: $programYear)
                if !programYears.isEmpty {
                    Menu("Use a registration year on file") {
                        ForEach(programYears, id: \.self) { year in Button(year) { programYear = year } }
                    }
                }
                LabeledContent("Active Scouts and leaders included", value: "\(people.filter { $0.isActive && ($0.role == .scout || $0.role == .leader) }.count)")
                AmountField(title: "Registration cost per person", text: $perPersonCost)
                AmountField(title: "Unit charter cost", text: $unitCharterCost)
                AmountField(title: "Other known recharter costs", text: $otherCost)
                AmountField(title: "Expected collections before payment", text: $expectedCollections)
                Text("The forecast counts active Scouts and registered leaders; parents, guardians, and other contacts do not recharter. The assessed-registration total below is a reference from matching registration records; it does not silently replace your cost assumptions.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let snapshot {
                Section("Forecast") {
                    money("Current troop cash", snapshot.currentCashCents)
                    money("Expected collections", snapshot.expectedCollectionsCents)
                    money("Per-person registration costs", -snapshot.projectedRegistrationCostCents)
                    money("Unit charter and other costs", -(snapshot.unitCharterCostCents + snapshot.otherCostCents))
                    money("Projected cash after recharter", snapshot.projectedEndingCashCents, emphasized: true)
                    money("Matching assessed dues reference", snapshot.assessedRegistrationCents)
                }
                if snapshot.projectedEndingCashCents < 0 {
                    Section { Label("Projected cash is short by \(Money.currency(cents: -snapshot.projectedEndingCashCents)).", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            } else {
                Section { Text("Enter valid amounts to calculate the forecast.").foregroundStyle(.secondary) }
            }
        }
        .pageHeader(title: "Recharter Cash Forecast")
        .onAppear {
            if !programYears.isEmpty, !programYears.contains(programYear), let newest = programYears.first { programYear = newest }
        }
    }

    private func money(_ label: String, _ cents: Int64, emphasized: Bool = false) -> some View {
        HStack { Text(label).fontWeight(emphasized ? .semibold : .regular); Spacer(); MoneyText(cents: cents, colorBySign: true).fontWeight(emphasized ? .semibold : .regular) }
    }
}
