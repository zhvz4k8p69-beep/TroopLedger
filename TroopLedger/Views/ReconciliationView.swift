import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ReconciliationView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query(sort: \LedgerTransaction.date) private var transactions: [LedgerTransaction]
    @Query(sort: \ReconciliationRecord.statementDate, order: .reverse) private var reconciliations: [ReconciliationRecord]
    @State private var accountID: UUID?
    @State private var statementDate = ReconciliationView.endOfPreviousMonth()
    @State private var endingBalance = "0.00"
    @State private var selected = Set<UUID>()
    @State private var notes = ""
    @State private var errorMessage: String?
    @State private var showingReconciliationMilestone = false
    @State private var showingPlanImporter = false
    @State private var planPreview: ReconciliationPlanPreview?

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
        // `eligible` and `clearedBalance` each walk the whole register; they were evaluated up to five times
        // per render (progress rows, difference, the toolbar button, and the outstanding list) on every keystroke.
        let eligible = self.eligible
        let clearedBalance = self.clearedBalance
        let difference = statementCents.map { $0 - clearedBalance }
        return content(eligible: eligible, clearedBalance: clearedBalance, difference: difference)
        .pageToolbar(title: "Reconcile") {
            Button("Import Plan…", systemImage: "square.and.arrow.down") { showingPlanImporter = true }
                .disabled(accounts.isEmpty)
            Button("Finish Reconciliation", systemImage: "checkmark.seal", action: finish)
                .disabled(account == nil || statementCents == nil || difference != 0 || !statementDateIsAfterLock || statementDateIsInFuture)
        }
        .fileImporter(isPresented: $showingPlanImporter, allowedContentTypes: [.json], onCompletion: handlePlanFile)
        .sheet(item: $planPreview) { preview in
            ReconciliationPlanImportView(preview: preview, onApplied: didComplete)
        }
        .onAppear {
            if accountID == nil { accountID = AccountSelectionPolicy.defaultOperatingAccount(in: accounts)?.id }
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
    private func content(eligible: [LedgerTransaction], clearedBalance: Int64, difference: Int64?) -> some View {
        if accounts.isEmpty {
            EmptyMessage(title: "No account to reconcile", message: "Add the checking account before starting a reconciliation.", systemImage: "checkmark.seal")
        } else {
            List {
                statementSection
                progressSection(clearedBalance: clearedBalance, difference: difference)
                outstandingSection(eligible: eligible)
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

    private func progressSection(clearedBalance: Int64, difference: Int64?) -> some View {
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
    private func outstandingSection(eligible: [LedgerTransaction]) -> some View {
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

    /// Statements arrive after the month closes; defaulting to today produced partial-month reconciliations.
    static func endOfPreviousMonth(relativeTo date: Date = Date(), calendar: Calendar = .current) -> Date {
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        return calendar.date(byAdding: .day, value: -1, to: monthStart) ?? date
    }

    /// After a statement is finished the next one to reconcile ends a month later. Leaving the date on the
    /// just-locked statement left the screen saying "Choose a statement date after the current lock" with the
    /// Finish button disabled, as if the reconciliation had failed.
    static func nextStatementDate(after statementDate: Date, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: statementDate),
              let followingMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: nextMonth)),
              let monthAfterNext = calendar.date(byAdding: .month, value: 1, to: followingMonthStart),
              let endOfNextMonth = calendar.date(byAdding: .day, value: -1, to: monthAfterNext) else {
            return today
        }
        return min(endOfNextMonth, today)
    }

    private func moveStatementDatePastLock() {
        statementDate = PeriodLocking.firstUnlockedDate(
            for: accountID,
            reconciliations: reconciliations,
            relativeTo: statementDate
        )
    }

    private func finish() {
        do {
            guard let account, let statementCents else { throw ReconciliationCompletionError.outOfBalance }
            let record = try ReconciliationCompletionService.complete(
                account: account,
                statementDate: statementDate,
                statementBalanceCents: statementCents,
                selectedTransactionIDs: selected,
                notes: notes,
                transactions: transactions,
                reconciliations: reconciliations,
                in: modelContext
            )
            didComplete(record)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func didComplete(_ record: ReconciliationRecord) {
        accountID = record.accountID
        selected.removeAll()
        notes = ""
        endingBalance = "0.00"
        statementDate = Self.nextStatementDate(after: record.statementDate)
        showingReconciliationMilestone = true
    }

    // MARK: - Plan import

    private func handlePlanFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try ImportedFileReader.read(url, maximumBytes: ReconciliationPlanImporter.maximumFileBytes, tooLargeError: ReconciliationPlanError.fileTooLarge)
            let plan = try ReconciliationPlanImporter.decode(data)
            planPreview = try ReconciliationPlanImporter.preview(plan, accounts: accounts, transactions: transactions, reconciliations: reconciliations)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Review of a plan written by the `troopledger` MCP server before it is applied. Every ID in the plan was checked
/// against the live ledger when the preview was built; problems block applying, warnings do not.
struct ReconciliationPlanImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LedgerTransaction.date) private var transactions: [LedgerTransaction]
    @Query(sort: \ReconciliationRecord.statementDate, order: .reverse) private var reconciliations: [ReconciliationRecord]
    let preview: ReconciliationPlanPreview
    let onApplied: (ReconciliationRecord) -> Void
    @State private var errorMessage: String?
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            List {
                summarySection
                if !preview.problems.isEmpty {
                    Section("Problems") {
                        ForEach(preview.problems, id: \.self) { problem in
                            Label(problem, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                    }
                }
                if !preview.warnings.isEmpty {
                    Section("Check before applying") {
                        ForEach(preview.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                if !preview.additions.isEmpty {
                    Section("Transactions to add (\(preview.additions.count))") {
                        ForEach(preview.additions) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.payee.isEmpty ? item.category : item.payee)
                                    Text("\(item.date.formatted(date: .abbreviated, time: .omitted)) · \(item.category)\(item.adjustsTransactionID == nil ? "" : " · adjustment")\(item.memo.isEmpty ? "" : " · \(item.memo)")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                MoneyText(cents: item.signedAmountCents, colorBySign: true)
                            }
                        }
                    }
                }
                Section("Transactions to clear (\(preview.clearItems.count))") {
                    if preview.clearItems.isEmpty {
                        Text("None.").foregroundStyle(.secondary)
                    }
                    ForEach(preview.clearItems) { item in
                        HStack {
                            Image(systemName: item.isTentative ? "questionmark.square" : "checkmark.square")
                                .foregroundStyle(item.isTentative ? Color.orange : Color.accentColor)
                            VStack(alignment: .leading) {
                                Text(item.transaction.payee.isEmpty ? item.transaction.category : item.transaction.payee)
                                Text("\(item.transaction.date.formatted(date: .abbreviated, time: .omitted))\(item.transaction.checkNumber.isEmpty ? "" : " · #\(item.transaction.checkNumber)")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            MoneyText(cents: item.transaction.signedAmountCents, colorBySign: true)
                        }
                    }
                }
            }
            .navigationTitle("Import Reconciliation Plan")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply Plan", action: apply).disabled(!preview.canApply || isApplying)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 560)
        .alert("Reconciliation Plan", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var summarySection: some View {
        Section("Statement") {
            LabeledContent("Account", value: preview.account.name)
            LabeledContent("Statement ending date", value: preview.statementDate.formatted(date: .long, time: .omitted))
            LabeledContent("Statement ending balance") { MoneyText(cents: preview.plan.statementEndingBalanceCents) }
            LabeledContent("Ledger cleared balance before") { MoneyText(cents: preview.clearedBeforeCents) }
            LabeledContent("Items to clear (\(preview.clearItems.count))") { MoneyText(cents: preview.clearNetCents, colorBySign: true) }
            LabeledContent("Transactions to add (\(preview.additions.count))") { MoneyText(cents: preview.additionsNetCents, colorBySign: true) }
            LabeledContent("Ledger cleared balance after") { MoneyText(cents: preview.clearedAfterCents) }
            LabeledContent("Difference") { MoneyText(cents: preview.differenceCents, colorBySign: true) }
            if preview.canApply {
                Label("Ties to the statement. Applying will add the transactions, clear the items, and lock the period.", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(Color.fieldbookPositive)
            } else if preview.problems.isEmpty {
                Label("The difference must be $0.00 before the plan can be applied.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let generated = preview.plan.generatedAt, !generated.isEmpty {
                Text("Plan written \(generated)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func apply() {
        isApplying = true
        defer { isApplying = false }
        do {
            let record = try ReconciliationPlanImporter.apply(preview, transactions: transactions, reconciliations: reconciliations, in: modelContext)
            dismiss()
            onApplied(record)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
