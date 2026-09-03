import CloudKit
import Security
import SwiftUI
import SwiftData

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

    private var activeAccounts: [AccountRecord] { accounts.filter(\.isActive) }
    private var primaryAccount: AccountRecord? {
        activeAccounts.first(where: { $0.kind == .checking }) ?? activeAccounts.first
    }
    private var cashPosition: CashPosition { FinanceEngine.cashPosition(accounts: accounts, transactions: transactions) }
    private var outstandingMemberBalances: Int64 {
        people.reduce(0) { partial, person in
            max(0, FinanceEngine.memberBalance(personID: person.id, entries: memberEntries)) + partial
        }
    }
    /// Only bank-type accounts clear against a statement. Cash on Hand and Undeposited Funds entries
    /// (including every deposit batch's holding leg) never "clear", so counting them made the monthly
    /// close impossible to finish.
    private var bankAccountIDs: Set<UUID> {
        Set(accounts.filter { $0.kind != .cash && $0.kind != .undepositedFunds }.map(\.id))
    }
    private var unclearedTransactions: [LedgerTransaction] {
        transactions.filter { !$0.isCleared && $0.accountID.map(bankAccountIDs.contains) == true }
    }
    private var upcomingEvents: [EventRecord] {
        Array(events.filter { $0.endDate >= Calendar.current.startOfDay(for: Date()) && $0.status != .cancelled }.prefix(4))
    }
    private var latestReconciliation: ReconciliationRecord? {
        guard let accountID = primaryAccount?.id else { return nil }
        return reconciliations.first { $0.accountID == accountID }
    }
    private var submittedReimbursements: [ReimbursementRequest] {
        reimbursements.filter { $0.status == .submitted }
    }
    private var missingReceiptCount: Int {
        let attachedRequestIDs = Set(reimbursementAttachments.compactMap(\.requestID))
        return submittedReimbursements.filter { !attachedRequestIDs.contains($0.id) }.count
    }
    private var currentBudgetRemaining: Int64? {
        let period = ReportingPeriod.containing(Date())
        guard let budget = budgets.first(where: {
            $0.reportingYearStart == period.startingYear && $0.status == .approved
        }) else { return nil }
        let budgetedExpenses = budgetLines
            .filter { $0.budgetID == budget.id && $0.direction == .expense }
            .reduce(0) { $0 + $1.amountCents }
        let spent = transactions
            .filter { period.contains($0.date) && $0.direction == .expense && !$0.isTransfer }
            .reduce(0) { $0 + $1.amountCents }
        return budgetedExpenses - spent
    }
    private var closeTasksComplete: Int {
        [
            cashPosition.undepositedFundsCents == 0,
            missingReceiptCount == 0,
            unclearedTransactions.isEmpty,
            reconciliationIsCurrent,
        ].filter { $0 }.count
    }
    private var reconciliationIsCurrent: Bool {
        guard let statementDate = latestReconciliation?.statementDate,
              let previousMonth = Calendar.current.date(byAdding: .month, value: -1, to: Date()),
              let expected = Calendar.current.dateInterval(of: .month, for: previousMonth)?.start else { return false }
        return statementDate >= expected
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
        ScrollView {
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
                            balancePanel.frame(maxWidth: .infinity)
                            attentionPanel.frame(width: 330)
                        }
                        VStack(spacing: 14) {
                            balancePanel
                            attentionPanel
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            monthClosePanel.frame(maxWidth: .infinity)
                            recentActivityPanel.frame(maxWidth: .infinity)
                        }
                        VStack(spacing: 14) {
                            monthClosePanel
                            recentActivityPanel
                        }
                    }

                    upcomingEventsPanel
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
        .onAppear { previousCloseTasksComplete = closeTasksComplete }
        .onChange(of: closeTasksComplete) { _, newValue in
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

    private var balancePanel: some View {
        FieldbookPanel {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    FieldbookActivityEmblem(systemImage: "banknote.fill")
                    VStack(alignment: .leading, spacing: 6) {
                        Label(primaryAccount?.name ?? "Available cash", systemImage: "building.columns")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(Money.currency(cents: cashPosition.totalCents))
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    Spacer(minLength: 12)
                    reconciliationBadge
                }

                Divider()

                HStack(spacing: 0) {
                    summaryValue("Undeposited funds", Money.currency(cents: cashPosition.undepositedFundsCents))
                    Divider().frame(height: 40).padding(.horizontal, 16)
                    summaryValue("Member balances due", Money.currency(cents: outstandingMemberBalances))
                    Divider().frame(height: 40).padding(.horizontal, 16)
                    summaryValue(
                        currentBudgetRemaining == nil ? "Active members" : "Budget remaining",
                        currentBudgetRemaining.map { Money.currency(cents: $0) } ?? String(people.filter(\.isActive).count)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var reconciliationBadge: some View {
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

    private var attentionPanel: some View {
        FieldbookPanel {
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
                    if !unclearedTransactions.isEmpty {
                        attentionRow(title: "\(unclearedTransactions.count) uncleared transactions", detail: oldestUnclearedDescription, systemImage: "clock.arrow.circlepath", destination: .reconcile)
                    }
                    if outstandingMemberBalances > 0 {
                        attentionRow(title: "Member balances are outstanding", detail: Money.currency(cents: outstandingMemberBalances) + " total", systemImage: "person.crop.circle.badge.exclamationmark", destination: .people)
                    }
                    if missingReceiptCount > 0 {
                        attentionRow(title: "\(missingReceiptCount) reimbursement receipt\(missingReceiptCount == 1 ? "" : "s") missing", detail: "Complete the supporting record", systemImage: "doc.badge.plus", destination: .reimbursements)
                    }
                    if !reconciliationIsCurrent {
                        attentionRow(title: "Monthly reconciliation is due", detail: latestReconciliationDescription, systemImage: "checkmark.seal", destination: .reconcile)
                    }
                }
            }
        }
    }

    private var attentionCount: Int {
        [!unclearedTransactions.isEmpty, outstandingMemberBalances > 0, missingReceiptCount > 0, !reconciliationIsCurrent]
            .filter { $0 }.count
    }

    private var oldestUnclearedDescription: String {
        guard let date = unclearedTransactions.map(\.date).min() else { return "" }
        return "Oldest is \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private var latestReconciliationDescription: String {
        guard let latestReconciliation else { return "No completed reconciliation" }
        return "Last completed \(latestReconciliation.statementDate.formatted(date: .abbreviated, time: .omitted))"
    }

    private var monthClosePanel: some View {
        FieldbookPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Monthly close").font(.headline)
                    Spacer()
                    Text("\(closeTasksComplete) of 4 complete").font(.caption).foregroundStyle(.secondary)
                }
                ScoutTrailProgress(completed: closeTasksComplete, total: 4)
                closeTask("Deposit received funds", isComplete: cashPosition.undepositedFundsCents == 0, detail: cashPosition.undepositedFundsCents == 0 ? "Done" : Money.currency(cents: cashPosition.undepositedFundsCents), destination: .deposits)
                closeTask("Attach reimbursement receipts", isComplete: missingReceiptCount == 0, detail: missingReceiptCount == 0 ? "Done" : "\(missingReceiptCount) open", destination: .reimbursements)
                closeTask("Clear matched transactions", isComplete: unclearedTransactions.isEmpty, detail: unclearedTransactions.isEmpty ? "Done" : "\(unclearedTransactions.count) open", destination: .reconcile)
                closeTask("Finish reconciliation", isComplete: reconciliationIsCurrent, detail: reconciliationIsCurrent ? "Done" : "Next", destination: .reconcile)
            }
        }
    }

    private var recentActivityPanel: some View {
        FieldbookPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recent activity").font(.headline)
                    Spacer()
                    Button("View ledger") { onOpenSection(.transactions) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.fieldbookAccent)
                }
                .padding(.bottom, 7)

                if transactions.isEmpty {
                    Text("No transactions yet").foregroundStyle(.secondary).padding(.vertical, 18)
                } else {
                    ForEach(Array(transactions.prefix(5))) { transaction in
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
                        if transaction.id != transactions.prefix(5).last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var upcomingEventsPanel: some View {
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
