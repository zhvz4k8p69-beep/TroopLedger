import SwiftData
import SwiftUI

struct BatchDepositListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DepositBatchRecord.depositDate, order: .reverse) private var batches: [DepositBatchRecord]
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query private var allocations: [DepositAllocationRecord]
    @State private var showingBuilder = false
    @State private var message: String?

    private var undepositedAccount: AccountRecord? {
        accounts.first { $0.kind == .undepositedFunds }
    }

    var body: some View {
        Group {
            if undepositedAccount == nil {
                VStack(spacing: 16) {
                    EmptyMessage(
                        title: "Set up Undeposited Funds",
                        message: "Create the holding account before building a bank deposit.",
                        systemImage: "tray.full"
                    )
                    Button("Create Undeposited Funds Account", systemImage: "plus.circle") {
                        createUndepositedAccount()
                    }
                }
            } else if batches.isEmpty {
                if undepositedAccount?.isActive == false {
                    inactiveNotice
                } else {
                    EmptyMessage(
                        title: "No deposit batches",
                        message: "Record income in Undeposited Funds or use imported cash receipts, then build one bank deposit while preserving every allocation.",
                        systemImage: "tray.and.arrow.up"
                    )
                }
            } else {
                List {
                    if undepositedAccount?.isActive == false {
                        Section { inactiveNotice }
                    }
                    let allocationCounts = Dictionary(grouping: allocations, by: \.batchID).mapValues(\.count)
                    ForEach(batches) { batch in
                    let allocationCount = allocationCounts[batch.id] ?? 0
                    NavigationLink {
                        BatchDepositDetailView(batch: batch)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tray.and.arrow.up.fill").foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(destinationName(batch.destinationAccountID)).font(.headline)
                                Text("\(batch.depositDate.formatted(date: .abbreviated, time: .omitted)) • \(allocationCount) allocation\(allocationCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !batch.reference.isEmpty {
                                    Text("Reference \(batch.reference)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            MoneyText(cents: batch.totalCents)
                        }
                        .padding(.vertical, 3)
                    }
                    }
                }
            }
        }
        .pageToolbar(title: "Deposits") {
            Button("New Deposit", systemImage: "plus") { showingBuilder = true }
                .disabled(undepositedAccount?.isActive != true || destinationAccounts.isEmpty)
        }
        .sheet(isPresented: $showingBuilder) { BatchDepositBuilderView() }
        .alert("Deposits", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) { Button("OK") { message = nil } } message: { Text(message ?? "") }
    }

    private var destinationAccounts: [AccountRecord] {
        accounts.filter { $0.isActive && $0.kind != .cash && $0.kind != .undepositedFunds }
    }

    /// New Deposit was silently disabled whenever the holding account had been archived.
    private var inactiveNotice: some View {
        Label("The Undeposited Funds account is inactive. Reactivate it in Accounts to record new deposits.", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
    }

    private func destinationName(_ id: UUID?) -> String {
        accounts.first { $0.id == id }?.name ?? "Unknown destination"
    }

    private func createUndepositedAccount() {
        do { _ = try UndepositedFundsService.createAccount(in: modelContext) }
        catch { message = error.localizedDescription }
    }
}

struct BatchDepositBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query(sort: \LedgerTransaction.date) private var transactions: [LedgerTransaction]
    @Query(sort: \CashReceiptRecord.date) private var cashReceipts: [CashReceiptRecord]
    @Query private var allocations: [DepositAllocationRecord]
    @Query(sort: \ReconciliationRecord.statementDate, order: .reverse) private var reconciliations: [ReconciliationRecord]
    @State private var destinationAccountID: UUID?
    @State private var depositDate = Date()
    @State private var reference = ""
    @State private var notes = ""
    @State private var selectedTransactionIDs: Set<UUID> = []
    @State private var selectedCashReceiptIDs: Set<UUID> = []
    @State private var errorMessage: String?

    private var undeposited: AccountRecord? {
        accounts.first { $0.kind == .undepositedFunds && $0.isActive }
    }

    private var destinations: [AccountRecord] {
        accounts.filter { $0.isActive && $0.kind != .cash && $0.kind != .undepositedFunds }
    }

    private var eligibleTransactions: [LedgerTransaction] {
        BatchDepositService.eligibleTransactions(
            undepositedFundsAccountID: undeposited?.id,
            transactions: transactions,
            allocations: allocations
        )
    }

    private var eligibleCashReceipts: [CashReceiptRecord] {
        BatchDepositService.eligibleCashReceipts(receipts: cashReceipts, allocations: allocations)
    }

    private var selectedCount: Int { selectedTransactionIDs.count + selectedCashReceiptIDs.count }

    /// The service refuses a batch containing a receipt dated after the deposit; the builder used to offer such
    /// receipts anyway and reported the problem only after the treasurer had pressed Post.
    static func isReceivedAfterDeposit(received: Date, depositDate: Date, calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: received) > calendar.startOfDay(for: depositDate)
    }

    var body: some View {
        // Both eligibility lists rebuild a set of every allocation and filter their table; they were evaluated
        // three or four times per render (emptiness, the rows, the total, the Post button).
        let eligibleTransactions = self.eligibleTransactions
        let eligibleCashReceipts = self.eligibleCashReceipts
        let selectedTotal = eligibleTransactions.filter { selectedTransactionIDs.contains($0.id) }.reduce(0) { $0 + $1.amountCents }
            + eligibleCashReceipts.filter { selectedCashReceiptIDs.contains($0.id) }.reduce(0) { $0 + $1.amountCents }
        return NavigationStack {
            Form {
                Section("Bank Deposit") {
                    Picker("Deposit to", selection: $destinationAccountID) {
                        Text("Choose a bank account").tag(nil as UUID?)
                        ForEach(destinations) { Text($0.name).tag($0.id as UUID?) }
                    }
                    DatePicker("Deposit date", selection: $depositDate, in: ...Date(), displayedComponents: .date)
                    TextField("Deposit reference", text: $reference)
                    TextField("Notes", text: $notes, axis: .vertical)
                }

                Section("Undeposited Ledger Receipts") {
                    if eligibleTransactions.isEmpty {
                        Text("No unbatched income transactions are available in Undeposited Funds.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(eligibleTransactions) { transaction in
                            selectionButton(
                                id: transaction.id,
                                selected: $selectedTransactionIDs,
                                title: transaction.payee.isEmpty ? transaction.category : transaction.payee,
                                detail: "\(transaction.date.formatted(date: .abbreviated, time: .omitted)) • \(transaction.category)",
                                amount: transaction.amountCents,
                                receivedAfterDeposit: Self.isReceivedAfterDeposit(received: transaction.date, depositDate: depositDate)
                            )
                        }
                    }
                }

                Section("Imported Cash Receipts") {
                    if eligibleCashReceipts.isEmpty {
                        Text("No unbatched imported cash receipts are available.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(eligibleCashReceipts) { receipt in
                            selectionButton(
                                id: receipt.id,
                                selected: $selectedCashReceiptIDs,
                                title: receipt.personName.isEmpty ? receipt.purpose : receipt.personName,
                                detail: "\(receipt.date.formatted(date: .abbreviated, time: .omitted)) • \(receipt.purpose) • \(receipt.paymentKind)",
                                amount: receipt.amountCents,
                                receivedAfterDeposit: Self.isReceivedAfterDeposit(received: receipt.date, depositDate: depositDate)
                            )
                        }
                    }
                }

                Section("Deposit Total") {
                    LabeledContent("Selected allocations", value: String(selectedCount))
                    LabeledContent("Bank deposit", value: Money.currency(cents: selectedTotal))
                    if let undeposited {
                        LabeledContent(
                            "Currently awaiting deposit",
                            value: Money.currency(cents: FinanceEngine.bookBalance(account: undeposited, transactions: transactions))
                        )
                    }
                }

                Section {
                    Text("Posting creates one matched account transfer from Undeposited Funds to the selected bank account. Transfer entries do not change income or expense reports. Every selected payer, person, event, purpose, source record, and amount is retained as a read-only allocation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Deposit Batch")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post Deposit", action: post)
                        .disabled(selectedTotal <= 0 || destinationAccountID == nil)
                }
            }
            .onAppear { destinationAccountID = destinationAccountID ?? AccountSelectionPolicy.defaultOperatingAccount(in: destinations)?.id ?? destinations.first?.id }
            // Moving the deposit date earlier can strand already-ticked receipts on the wrong side of it.
            .onChange(of: depositDate) { _, newDate in
                let lateTransactions = eligibleTransactions.filter { Self.isReceivedAfterDeposit(received: $0.date, depositDate: newDate) }.map(\.id)
                let lateReceipts = eligibleCashReceipts.filter { Self.isReceivedAfterDeposit(received: $0.date, depositDate: newDate) }.map(\.id)
                selectedTransactionIDs.subtract(lateTransactions)
                selectedCashReceiptIDs.subtract(lateReceipts)
            }
        }
        .frame(minWidth: 560, minHeight: 700)
        .alert("Deposit Batch", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func selectionButton(
        id: UUID,
        selected: Binding<Set<UUID>>,
        title: String,
        detail: String,
        amount: Int64,
        receivedAfterDeposit: Bool
    ) -> some View {
        Button {
            if selected.wrappedValue.contains(id) { selected.wrappedValue.remove(id) }
            else { selected.wrappedValue.insert(id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected.wrappedValue.contains(id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.wrappedValue.contains(id) ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                    if receivedAfterDeposit {
                        Label("Received after the deposit date", systemImage: "calendar.badge.exclamationmark")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                MoneyText(cents: amount)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(receivedAfterDeposit)
    }

    private func post() {
        do {
            _ = try BatchDepositService.post(
                destinationAccountID: destinationAccountID,
                depositDate: depositDate,
                reference: reference,
                notes: notes,
                sourceTransactionIDs: selectedTransactionIDs,
                sourceCashReceiptIDs: selectedCashReceiptIDs,
                reconciliations: reconciliations,
                in: modelContext
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BatchDepositDetailView: View {
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    // Filtered in the store: this screen used to load every allocation of every batch and the entire register
    // to show one deposit and its two transfer legs.
    @Query private var allocations: [DepositAllocationRecord]
    @Query private var transactions: [LedgerTransaction]
    @Query private var people: [PersonRecord]
    @Query private var events: [EventRecord]
    let batch: DepositBatchRecord

    init(batch: DepositBatchRecord) {
        self.batch = batch
        let batchID: UUID? = batch.id
        _allocations = Query(filter: #Predicate<DepositAllocationRecord> { $0.batchID == batchID }, sort: \DepositAllocationRecord.receivedAt)
        let legIDs = [batch.holdingTransactionID, batch.bankTransactionID].compactMap { $0 }
        _transactions = Query(filter: #Predicate<LedgerTransaction> { legIDs.contains($0.id) })
    }

    var body: some View {
        let peopleByID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let eventsByID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return List {
            Section("Bank Deposit") {
                LabeledContent("Destination", value: accountName(batch.destinationAccountID))
                LabeledContent("Date", value: batch.depositDate.formatted(date: .long, time: .omitted))
                LabeledContent("Total", value: Money.currency(cents: batch.totalCents))
                LabeledContent("Reference", value: batch.reference.isEmpty ? "Not recorded" : batch.reference)
                if !batch.notes.isEmpty { LabeledContent("Notes", value: batch.notes) }
                LabeledContent("Posted", value: batch.postedAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section("Receipt Allocations") {
                ForEach(allocations) { allocation in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(allocation.payerNameSnapshot.isEmpty ? "Unnamed payer" : allocation.payerNameSnapshot)
                                .font(.headline)
                            Spacer()
                            MoneyText(cents: allocation.amountCents)
                        }
                        Text([allocation.receivedAt.formatted(date: .abbreviated, time: .omitted), allocation.purposeSnapshot, allocation.paymentKindSnapshot]
                            .filter { !$0.isEmpty }.joined(separator: " • "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let person = allocation.personID.flatMap({ peopleByID[$0] }) {
                            Text("Person: \(person.displayName)").font(.caption2).foregroundStyle(.secondary)
                        }
                        if let event = allocation.eventID.flatMap({ eventsByID[$0] }) {
                            Text("Event: \(event.name)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }

            Section("Linked Ledger Transfer") {
                transferRow("From Undeposited Funds", id: batch.holdingTransactionID)
                transferRow("Into bank account", id: batch.bankTransactionID)
                Text("These matched entries move cash between accounts and are excluded from income, expense, and budget-variance reports.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Deposit Batch")
    }

    private func accountName(_ id: UUID?) -> String {
        accounts.first { $0.id == id }?.name ?? "Unknown account"
    }

    @ViewBuilder
    private func transferRow(_ label: String, id: UUID?) -> some View {
        if let id, let transaction = transactions.first(where: { $0.id == id }) {
            LabeledContent(label, value: "\(accountName(transaction.accountID)) • \(Money.currency(cents: transaction.amountCents))")
        } else {
            Label("\(label) transaction is missing", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}
