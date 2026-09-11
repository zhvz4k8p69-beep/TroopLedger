import CloudKit
import Security
import SwiftUI
import SwiftData

/// Every figure the dashboard shows, computed once per render. The computed properties this replaces were
/// each read up to eight times per render (the attention panel, the close checklist, the milestone check and
/// the balance panel all asked the same questions), and most of them walked the entire register to answer.
struct DashboardMetrics {
    static let staleUndepositedDays = 14

    let primaryAccount: AccountRecord?
    let cashPosition: CashPosition
    let outstandingMemberBalancesCents: Int64
    let activeMemberCount: Int
    let unclearedBankTransactionCount: Int
    let oldestUnclearedDate: Date?
    let oldestUndepositedAgeDays: Int?
    let missingReceiptCount: Int
    let currentBudgetRemainingCents: Int64?
    let latestReconciliation: ReconciliationRecord?
    let reconciliationIsCurrent: Bool
    let upcomingEvents: [EventRecord]

    var undepositedIsStale: Bool { (oldestUndepositedAgeDays ?? 0) >= Self.staleUndepositedDays }

    var closeTasksComplete: Int {
        [
            cashPosition.undepositedFundsCents == 0,
            missingReceiptCount == 0,
            unclearedBankTransactionCount == 0,
            reconciliationIsCurrent,
        ].filter { $0 }.count
    }

    var attentionCount: Int {
        [unclearedBankTransactionCount > 0, undepositedIsStale, outstandingMemberBalancesCents > 0, missingReceiptCount > 0, !reconciliationIsCurrent]
            .filter { $0 }.count
    }

    init(
        accounts: [AccountRecord],
        transactions: [LedgerTransaction],
        people: [PersonRecord],
        memberEntries: [MemberLedgerEntry],
        events: [EventRecord],
        reconciliations: [ReconciliationRecord],
        reimbursements: [ReimbursementRequest],
        attachments: [ReimbursementAttachment],
        depositAllocations: [DepositAllocationRecord],
        budgets: [OperatingBudgetRecord],
        budgetLines: [BudgetLineRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let activeAccounts = accounts.filter(\.isActive)
        primaryAccount = activeAccounts.first(where: { $0.kind == .checking }) ?? activeAccounts.first
        cashPosition = FinanceEngine.cashPosition(accounts: accounts, transactions: transactions)

        let balances = FinanceEngine.memberBalances(entries: memberEntries)
        outstandingMemberBalancesCents = people.reduce(0) { $0 + max(0, balances[$1.id] ?? 0) }
        activeMemberCount = people.filter(\.isActive).count

        // Only bank-type accounts clear against a statement. Cash on Hand and Undeposited Funds entries
        // (including every deposit batch's holding leg) never "clear", so counting them made the monthly
        // close impossible to finish.
        let bankAccountIDs = Set(accounts.filter { $0.kind != .cash && $0.kind != .undepositedFunds }.map(\.id))
        let holdingIDs = Set(accounts.filter { $0.kind == .undepositedFunds }.map(\.id))
        let allocated = Set(depositAllocations.compactMap(\.sourceTransactionID))
        let period = ReportingPeriod.containing(now)
        let today = calendar.startOfDay(for: now)

        var unclearedCount = 0
        var oldestUncleared: Date?
        var oldestWaiting: Date?
        var spentThisPeriod: Int64 = 0
        // One pass over the register for the three ledger-derived figures.
        for transaction in transactions {
            guard let accountID = transaction.accountID else { continue }
            if !transaction.isCleared, bankAccountIDs.contains(accountID) {
                unclearedCount += 1
                if oldestUncleared.map({ transaction.date < $0 }) ?? true { oldestUncleared = transaction.date }
            }
            if holdingIDs.contains(accountID), transaction.direction == .income, !transaction.isTransfer, !allocated.contains(transaction.id),
               oldestWaiting.map({ transaction.date < $0 }) ?? true {
                oldestWaiting = transaction.date
            }
            if transaction.direction == .expense, !transaction.isTransfer, period.contains(transaction.date) {
                spentThisPeriod += transaction.amountCents
            }
        }
        unclearedBankTransactionCount = unclearedCount
        oldestUnclearedDate = oldestUncleared
        oldestUndepositedAgeDays = oldestWaiting.flatMap {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: $0), to: today).day
        }

        let attachedRequestIDs = Set(attachments.compactMap(\.requestID))
        missingReceiptCount = reimbursements.filter { $0.status == .submitted && !attachedRequestIDs.contains($0.id) }.count

        if let budget = budgets.first(where: { $0.reportingYearStart == period.startingYear && $0.status == .approved }) {
            let budgetedExpenses = budgetLines
                .filter { $0.budgetID == budget.id && $0.direction == .expense }
                .reduce(0) { $0 + $1.amountCents }
            currentBudgetRemainingCents = budgetedExpenses - spentThisPeriod
        } else {
            currentBudgetRemainingCents = nil
        }

        let primaryID = primaryAccount?.id
        latestReconciliation = primaryID.flatMap { id in reconciliations.first { $0.accountID == id } }
        if let statementDate = latestReconciliation?.statementDate,
           let previousMonth = calendar.date(byAdding: .month, value: -1, to: now),
           let expected = calendar.dateInterval(of: .month, for: previousMonth)?.start {
            reconciliationIsCurrent = statementDate >= expected
        } else {
            reconciliationIsCurrent = false
        }

        upcomingEvents = Array(events.filter { $0.endDate >= today && $0.status != .cancelled }.prefix(4))
    }
}

struct DashboardView: View {
    @Query(sort: \TroopProfileRecord.modifiedAt, order: .reverse) private var troopProfiles: [TroopProfileRecord]
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query(sort: \LedgerTransaction.date, order: .reverse) private var transactions: [LedgerTransaction]
    @Query private var people: [PersonRecord]
    @Query private var memberEntries: [MemberLedgerEntry]
    @Query(sort: \EventRecord.startDate) private var events: [EventRecord]
    @Query(sort: \ReconciliationRecord.statementDate, order: .reverse) private var reconciliations: [ReconciliationRecord]
    @Query private var reimbursements: [ReimbursementRequest]
    @Query private var reimbursementAttachments: [ReimbursementAttachment]
    @Query private var depositAllocations: [DepositAllocationRecord]
    @Query(sort: \OperatingBudgetRecord.modifiedAt, order: .reverse) private var budgets: [OperatingBudgetRecord]
    @Query private var budgetLines: [BudgetLineRecord]
    @State private var showingNewTransaction = false
    @State private var previousCloseTasksComplete: Int?
    @State private var showingCloseMilestone = false
    @State private var cloudAccountMessage: String?

    private let onOpenSection: (AppSection) -> Void

    init(onOpenSection: @escaping (AppSection) -> Void = { _ in }) {
        self.onOpenSection = onOpenSection
    }

    private var metrics: DashboardMetrics {
        DashboardMetrics(
            accounts: accounts,
            transactions: transactions,
            people: people,
            memberEntries: memberEntries,
            events: events,
            reconciliations: reconciliations,
            reimbursements: reimbursements,
            attachments: reimbursementAttachments,
            depositAllocations: depositAllocations,
            budgets: budgets,
            budgetLines: budgetLines
        )
    }

    private var troopProfile: TroopProfileRecord? { troopProfiles.first }
    private var greeting: String {
        let salutation: String
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: salutation = "Good morning"
        case 12..<18: salutation = "Good afternoon"
        default: salutation = "Good evening"
        }
        guard let name = troopProfile?.greetingName, !name.isEmpty else { return salutation }
        return "\(salutation), \(name)"
    }

    var body: some View {
        let metrics = self.metrics
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if let troopProfile, TroopReportIdentity(profile: troopProfile).hasProfile {
                        Text(troopProfile.formalName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                        if !troopProfile.organizationLine.isEmpty {
                            Text(troopProfile.organizationLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(greeting)
                        .font(.largeTitle.bold())
                    Text("A calm view of the troop’s books—and the next trail marker.")
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(Color.fieldbookMutedInk)
                }
                .padding(.bottom, 2)

                if let cloudAccountMessage {
                    Label(cloudAccountMessage, systemImage: "icloud.slash")
                        .font(.footnote)
                        .foregroundStyle(Color.fieldbookWarning)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.fieldbookWarning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }

                if accounts.isEmpty {
                    EmptyMessage(
                        title: "Set up the ledger",
                        message: "Start by adding the troop checking account in Accounts.",
                        systemImage: "building.columns"
                    )
                    .frame(minHeight: 300)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            balancePanel(metrics).frame(maxWidth: .infinity)
                            attentionPanel(metrics).frame(width: 330)
                        }
                        VStack(spacing: 14) {
                            balancePanel(metrics)
                            attentionPanel(metrics)
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            monthClosePanel(metrics).frame(maxWidth: .infinity)
                            recentActivityPanel.frame(maxWidth: .infinity)
                        }
                        VStack(spacing: 14) {
                            monthClosePanel(metrics)
                            recentActivityPanel
                        }
                    }

                    upcomingEventsPanel(metrics.upcomingEvents)
                }
            }
            .padding(20)
            .frame(maxWidth: 1400, alignment: .leading)
        }
        .background { FieldbookPageBackground() }
        .pageToolbar(title: "Dashboard") {
            Button("New Transaction", systemImage: "plus") { showingNewTransaction = true }
                .buttonStyle(.fieldbookProminent)
                .disabled(accounts.isEmpty)
        }
        .sheet(isPresented: $showingNewTransaction) { TransactionFormView() }
        .task { await checkCloudAccount() }
        .onAppear { previousCloseTasksComplete = metrics.closeTasksComplete }
        .onChange(of: metrics.closeTasksComplete) { _, newValue in
            if ScoutMotion.shouldCelebrateTransition(
                previous: previousCloseTasksComplete,
                current: newValue,
                target: 4
            ) {
                showingCloseMilestone = true
            }
            previousCloseTasksComplete = newValue
        }
        .scoutMilestoneOverlay(
            isPresented: $showingCloseMilestone,
            title: "Trail Complete",
            subtitle: "The monthly close is caught up.",
            systemImage: "flag.fill"
        )
    }

    private func balancePanel(_ metrics: DashboardMetrics) -> some View {
        FieldbookPanel {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    FieldbookActivityEmblem(systemImage: "banknote.fill")
                    VStack(alignment: .leading, spacing: 6) {
                        Label(metrics.primaryAccount?.name ?? "Available cash", systemImage: "building.columns")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(Money.currency(cents: metrics.cashPosition.totalCents))
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    Spacer(minLength: 12)
                    reconciliationBadge(metrics.latestReconciliation)
                }

                Divider()

                HStack(spacing: 0) {
                    summaryValue("Undeposited funds", Money.currency(cents: metrics.cashPosition.undepositedFundsCents))
                    Divider().frame(height: 40).padding(.horizontal, 16)
                    summaryValue("Member balances due", Money.currency(cents: metrics.outstandingMemberBalancesCents))
                    Divider().frame(height: 40).padding(.horizontal, 16)
                    summaryValue(
                        metrics.currentBudgetRemainingCents == nil ? "Active members" : "Budget remaining",
                        metrics.currentBudgetRemainingCents.map { Money.currency(cents: $0) } ?? String(metrics.activeMemberCount)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func reconciliationBadge(_ latestReconciliation: ReconciliationRecord?) -> some View {
        if let latestReconciliation {
            Label(
                "Reconciled through \(latestReconciliation.statementDate.formatted(date: .abbreviated, time: .omitted))",
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.fieldbookPositive)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.fieldbookPositive.opacity(0.12), in: Capsule())
        } else {
            Label("Not reconciled yet", systemImage: "exclamationmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.fieldbookWarning)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.fieldbookWarning.opacity(0.12), in: Capsule())
        }
    }

    private func attentionPanel(_ metrics: DashboardMetrics) -> some View {
        let attentionCount = metrics.attentionCount
        return FieldbookPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Needs attention")
                        .font(.headline)
                    Spacer()
                    Text("\(attentionCount)")
                        .font(.caption.bold())
                        .foregroundStyle(attentionCount == 0 ? Color.fieldbookPositive : Color.fieldbookWarning)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background((attentionCount == 0 ? Color.fieldbookPositive : Color.fieldbookWarning).opacity(0.12), in: Capsule())
                }
                .padding(.bottom, 8)

                if attentionCount == 0 {
                    Label("Everything is caught up", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.fieldbookPositive)
                        .padding(.vertical, 18)
                } else {
                    if metrics.unclearedBankTransactionCount > 0 {
                        attentionRow(
                            title: "\(metrics.unclearedBankTransactionCount) uncleared transactions",
                            detail: metrics.oldestUnclearedDate.map { "Oldest is \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "",
                            systemImage: "clock.arrow.circlepath",
                            destination: .reconcile
                        )
                    }
                    if metrics.undepositedIsStale, let days = metrics.oldestUndepositedAgeDays {
                        attentionRow(title: "Cash held undeposited for \(days) days", detail: Money.currency(cents: metrics.cashPosition.undepositedFundsCents) + " awaiting deposit", systemImage: "tray.full", destination: .deposits)
                    }
                    if metrics.outstandingMemberBalancesCents > 0 {
                        attentionRow(title: "Member balances are outstanding", detail: Money.currency(cents: metrics.outstandingMemberBalancesCents) + " total", systemImage: "person.crop.circle.badge.exclamationmark", destination: .people)
                    }
                    if metrics.missingReceiptCount > 0 {
                        attentionRow(title: "\(metrics.missingReceiptCount) reimbursement receipt\(metrics.missingReceiptCount == 1 ? "" : "s") missing", detail: "Complete the supporting record", systemImage: "doc.badge.plus", destination: .reimbursements)
                    }
                    if !metrics.reconciliationIsCurrent {
                        attentionRow(
                            title: "Monthly reconciliation is due",
                            detail: metrics.latestReconciliation.map { "Last completed \($0.statementDate.formatted(date: .abbreviated, time: .omitted))" } ?? "No completed reconciliation",
                            systemImage: "checkmark.seal",
                            destination: .reconcile
                        )
                    }
                }
            }
        }
    }

    private func monthClosePanel(_ metrics: DashboardMetrics) -> some View {
        let completed = metrics.closeTasksComplete
        let undeposited = metrics.cashPosition.undepositedFundsCents
        return FieldbookPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Monthly close").font(.headline)
                    Spacer()
                    Text("\(completed) of 4 complete").font(.caption).foregroundStyle(.secondary)
                }
                ScoutTrailProgress(completed: completed, total: 4)
                closeTask("Deposit received funds", isComplete: undeposited == 0, detail: undeposited == 0 ? "Done" : Money.currency(cents: undeposited), destination: .deposits)
                closeTask("Attach reimbursement receipts", isComplete: metrics.missingReceiptCount == 0, detail: metrics.missingReceiptCount == 0 ? "Done" : "\(metrics.missingReceiptCount) open", destination: .reimbursements)
                closeTask("Clear matched transactions", isComplete: metrics.unclearedBankTransactionCount == 0, detail: metrics.unclearedBankTransactionCount == 0 ? "Done" : "\(metrics.unclearedBankTransactionCount) open", destination: .reconcile)
                closeTask("Finish reconciliation", isComplete: metrics.reconciliationIsCurrent, detail: metrics.reconciliationIsCurrent ? "Done" : "Next", destination: .reconcile)
            }
        }
    }

    private var recentActivityPanel: some View {
        let recent = Array(transactions.prefix(5))
        return FieldbookPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recent activity").font(.headline)
                    Spacer()
                    Button("View ledger") { onOpenSection(.transactions) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.fieldbookAccent)
                }
                .padding(.bottom, 7)

                if recent.isEmpty {
                    Text("No transactions yet").foregroundStyle(.secondary).padding(.vertical, 18)
                } else {
                    ForEach(recent) { transaction in
                        Button { onOpenSection(.transactions) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: transaction.direction == .income ? "arrow.down.left" : "arrow.up.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(transaction.direction == .income ? Color.fieldbookPositive : Color.secondary)
                                    .frame(width: 28, height: 28)
                                    .background(Color.fieldbookRaisedSurface, in: RoundedRectangle(cornerRadius: 7))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(transaction.payee.isEmpty ? transaction.category : transaction.payee)
                                        .font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text("\(transaction.category) • \(transaction.date.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                MoneyText(cents: transaction.signedAmountCents, colorBySign: true)
                                    .font(.subheadline.weight(.semibold))
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if transaction.id != recent.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func upcomingEventsPanel(_ upcomingEvents: [EventRecord]) -> some View {
        FieldbookPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Upcoming events").font(.headline)
                    Spacer()
                    Button("Open event command center") { onOpenSection(.events) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.fieldbookAccent)
                }
                .padding(.bottom, 8)

                if upcomingEvents.isEmpty {
                    Text("No upcoming events").foregroundStyle(.secondary).padding(.vertical, 18)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 12)], spacing: 12) {
                        ForEach(upcomingEvents) { event in
                            Button { onOpenSection(.events) } label: {
                                HStack(spacing: 11) {
                                    FieldbookActivityEmblem(
                                        systemImage: FieldbookActivityIcon.systemImage(
                                            for: event.name,
                                            classification: event.classification
                                        ),
                                        size: 42
                                    )
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(event.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Text("\(event.startDate.formatted(date: .abbreviated, time: .omitted)) • \(event.status.rawValue)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                                .padding(10)
                                .background(Color.fieldbookRaisedSurface, in: RoundedRectangle(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.fieldbookBorder, lineWidth: 1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    /// Two devices silently diverge when iCloud is signed out or restricted; say so where the treasurer looks first.
    private func checkCloudAccount() async {
        // CloudKit raises an Objective-C exception when the container is not in the process entitlements
        // (unsigned developer builds, the unit-test host). Only ask when the entitlement is verifiably present.
        guard Self.hasCloudKitEntitlement else { return }
        do {
            let status = try await CKContainer(identifier: "iCloud.com.bettnet.TroopLedger").accountStatus()
            switch status {
            case .available: cloudAccountMessage = nil
            case .noAccount: cloudAccountMessage = "No iCloud account is signed in on this device. Changes stay here and will not reach your other devices until you sign in."
            case .restricted: cloudAccountMessage = "iCloud is restricted on this device, so changes will not sync to your other devices."
            case .temporarilyUnavailable: cloudAccountMessage = "iCloud is temporarily unavailable. Changes will sync once it returns; avoid editing the same records on another device meanwhile."
            case .couldNotDetermine: cloudAccountMessage = "iCloud status could not be determined. Check Settings before relying on sync between devices."
            @unknown default: cloudAccountMessage = nil
            }
        } catch {
            cloudAccountMessage = "iCloud status could not be checked: \(error.localizedDescription)"
        }
    }

    private static let hasCloudKitEntitlement: Bool = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
#if os(macOS)
        let task = SecTaskCreateFromSelf(nil)
        guard let task,
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String] else {
            return false
        }
        return value.contains("iCloud.com.bettnet.TroopLedger")
#else
        return true
#endif
    }()

    private func summaryValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attentionRow(title: String, detail: String, systemImage: String, destination: AppSection) -> some View {
        Button { onOpenSection(destination) } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage).foregroundStyle(Color.fieldbookWarning).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func closeTask(_ title: String, isComplete: Bool, detail: String, destination: AppSection) -> some View {
        Button { onOpenSection(destination) } label: {
            HStack(spacing: 10) {
                Image(systemName: isComplete ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isComplete ? Color.fieldbookPositive : Color.secondary)
                Text(title).font(.subheadline)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
