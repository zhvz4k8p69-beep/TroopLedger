import SwiftUI
import SwiftData

struct ReconciliationView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query(sort: \LedgerTransaction.date) private var transactions: [LedgerTransaction]
    @Query(sort: \ReconciliationRecord.statementDate, order: .reverse) private var reconciliations: [ReconciliationRecord]
    @State private var accountID: UUID?
    @State private var statementDate = Date()
    @State private var endingBalance = "0.00"
    @State private var selected = Set<UUID>()
    @State private var notes = ""
    @State private var errorMessage: String?
    @State private var showingReconciliationMilestone = false

    private var account: AccountRecord? { accounts.first { $0.id == accountID } }
    private var eligible: [LedgerTransaction] {
        transactions.filter {
            ReconciliationPolicy.isEligible($0, accountID: accountID, statementDate: statementDate)
        }
    }
    private var clearedBalance: Int64 {
        guard let account else { return 0 }
        return FinanceEngine.clearedBalance(
            account: account,
            transactions: transactions,
            additionallyCleared: selected,
            through: statementDate
        )
    }
    private var statementCents: Int64? { Money.cents(from: endingBalance) }
    private var difference: Int64? { statementCents.map { $0 - clearedBalance } }
    private var lockedThrough: Date? {
        PeriodLocking.latestLockDate(for: accountID, reconciliations: reconciliations)
    }
    private var statementDateIsAfterLock: Bool {
        guard let lockedThrough else { return true }
        return Calendar.current.startOfDay(for: statementDate) > lockedThrough
    }
    private var statementDateIsInFuture: Bool {
        Calendar.current.startOfDay(for: statementDate) > Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        content
        .pageToolbar(title: "Reconcile") {
            Button("Finish Reconciliation", systemImage: "checkmark.seal", action: finish)
                .disabled(account == nil || statementCents == nil || difference != 0 || !statementDateIsAfterLock || statementDateIsInFuture)
        }
        .onAppear {
            if accountID == nil { accountID = accounts.first(where: \.isActive)?.id }
            moveStatementDatePastLock()
        }
        .onChange(of: accountID) { _, _ in
            selected.removeAll()
            moveStatementDatePastLock()
        }
        .onChange(of: statementDate) { _, _ in selected.formIntersection(Set(eligible.map(\.id))) }
        .alert("Reconciliation", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .scoutMilestoneOverlay(
            isPresented: $showingReconciliationMilestone,
            title: "Books Reconciled",
            subtitle: "The compass is true and this period is locked.",
            systemImage: "checkmark.seal.fill",
            badgeSystemImage: "lock.fill"
        )
    }

    @ViewBuilder
    private var content: some View {
        if accounts.isEmpty {
            EmptyMessage(title: "No account to reconcile", message: "Add the checking account before starting a reconciliation.", systemImage: "checkmark.seal")
        } else {
            List {
                statementSection
                progressSection
                outstandingSection
                recentSection
            }
        }
    }

    private var statementSection: some View {
        Section("Statement") {
            Picker("Account", selection: $accountID) {
                Text("Choose an account").tag(nil as UUID?)
                ForEach(accounts.filter(\.isActive)) { Text($0.name).tag($0.id as UUID?) }
            }
            DatePicker("Statement ending date", selection: $statementDate, in: ...Date(), displayedComponents: .date)
            AmountField(title: "Statement ending balance", text: $endingBalance)
            TextField("Notes", text: $notes)
            if let lockedThrough {
                Label("Transactions are locked through \(lockedThrough.formatted(date: .long, time: .omitted)).", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var progressSection: some View {
        Section("Progress") {
            LabeledContent("Cleared balance") { MoneyText(cents: clearedBalance) }
            LabeledContent("Difference") { MoneyText(cents: difference ?? 0, colorBySign: true) }
            HStack(spacing: 10) {
                ReconciliationCompass(
                    differenceCents: difference,
                    isReady: statementDateIsAfterLock && difference == 0
                )
                if !statementDateIsAfterLock {
                    Text("Choose a statement date after the current lock.").foregroundStyle(.orange)
                } else if statementDateIsInFuture {
                    Text("The statement date cannot be in the future.").foregroundStyle(.orange)
                } else if difference == 0 {
                    Text("Ready to reconcile").foregroundStyle(Color.fieldbookPositive)
                } else {
                    Text("Difference must be $0.00").foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var outstandingSection: some View {
        Section("Outstanding Transactions") {
            if eligible.isEmpty {
                Text("No uncleared transactions through this date.").foregroundStyle(.secondary)
            } else {
                ForEach(eligible) { transaction in
                    transactionButton(transaction)
                }
            }
        }
    }

    private func transactionButton(_ transaction: LedgerTransaction) -> some View {
        Button { toggle(transaction.id) } label: {
            HStack {
                Image(systemName: selected.contains(transaction.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected.contains(transaction.id) ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading) {
                    Text(transaction.payee.isEmpty ? transaction.category : transaction.payee)
                    Text(transaction.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                MoneyText(cents: transaction.signedAmountCents, colorBySign: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var recentSection: some View {
        if !reconciliations.isEmpty {
            Section("Recent Reconciliations") {
                ForEach(Array(reconciliations.prefix(5))) { reconciliation in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(reconciliation.statementDate.formatted(date: .long, time: .omitted))
                            Label(accountName(reconciliation.accountID), systemImage: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        MoneyText(cents: reconciliation.statementEndingBalanceCents)
                    }
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func accountName(_ id: UUID?) -> String { accounts.first(where: { $0.id == id })?.name ?? "Unknown account" }

    private func moveStatementDatePastLock() {
        statementDate = PeriodLocking.firstUnlockedDate(
            for: accountID,
            reconciliations: reconciliations,
            relativeTo: statementDate
        )
    }

    private func finish() {
        do {
            guard let statementCents else { throw ReconciliationCompletionError.outOfBalance }
            try ReconciliationCompletionPolicy.validate(
                account: account,
                statementDate: statementDate,
                statementBalanceCents: statementCents,
                clearedBalanceCents: clearedBalance,
                selectedTransactionIDs: selected,
                transactions: transactions,
                reconciliations: reconciliations
            )
            let record = ReconciliationRecord(accountID: account?.id, statementDate: statementDate, statementEndingBalanceCents: statementCents, clearedBalanceCents: clearedBalance)
            record.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            modelContext.insert(record)
            for transaction in transactions where selected.contains(transaction.id) {
                transaction.isCleared = true
                transaction.reconciledAt = Date()
                transaction.reconciliationID = record.id
            }
            let accountLabel = account?.name ?? "account"
            AuditLogger.record(
                .reconcile,
                recordType: "Reconciliation",
                recordID: record.id,
                summary: "Reconciled \(accountLabel) through \(statementDate.formatted(date: .long, time: .omitted))",
                details: AuditLogger.details([
                    ("Statement ending balance", Money.currency(cents: record.statementEndingBalanceCents)),
                    ("Cleared balance", Money.currency(cents: record.clearedBalanceCents)),
                    ("Transactions cleared", String(selected.count)),
                    ("Notes", record.notes),
                ]),
                in: modelContext
            )
            AuditLogger.record(
                .lockPeriod,
                recordType: "Account",
                recordID: account?.id,
                summary: "Locked \(accountLabel) through \(statementDate.formatted(date: .long, time: .omitted))",
                details: "Established by reconciliation \(record.id.uuidString)",
                in: modelContext
            )
            try modelContext.save()
            selected.removeAll()
            notes = ""
            showingReconciliationMilestone = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
