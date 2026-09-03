import SwiftData
import SwiftUI

struct BatchDepositListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DepositBatchRecord.depositDate, order: .reverse) private var batches: [DepositBatchRecord]
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query private var allocations: [DepositAllocationRecord]
    @Query private var transactions: [LedgerTransaction]
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
                    ForEach(batches) { batch in
                    NavigationLink {
                        BatchDepositDetailView(batch: batch)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tray.and.arrow.up.fill").foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(destinationName(batch.destinationAccountID)).font(.headline)
                                Text("\(batch.depositDate.formatted(date: .abbreviated, time: .omitted)) • \(allocationCount(batch.id)) allocation\(allocationCount(batch.id) == 1 ? "" : "s")")
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

    private func allocationCount(_ batchID: UUID) -> Int {
        allocations.filter { $0.batchID == batchID }.count
    }

    private func createUndepositedAccount() {
        do { _ = try UndepositedFundsService.createAccount(in: modelContext) }
        catch { message = error.localizedDescription }
    }
}

private struct BatchDepositBuilderView: View {
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

    private var selectedTotal: Int64 {
        eligibleTransactions.filter { selectedTransactionIDs.contains($0.id) }.reduce(0) { $0 + $1.amountCents }
            + eligibleCashReceipts.filter { selectedCashReceiptIDs.contains($0.id) }.reduce(0) { $0 + $1.amountCents }
    }

    private var selectedCount: Int { selectedTransactionIDs.count + selectedCashReceiptIDs.count }

    var body: some View {
        NavigationStack {
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
                                amount: transaction.amountCents
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
                                amount: receipt.amountCents
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
        amount: Int64
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
                }
                Spacer()
                MoneyText(cents: amount)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    @Query private var allAllocations: [DepositAllocationRecord]
    @Query private var transactions: [LedgerTransaction]
    @Query private var people: [PersonRecord]
    @Query private var events: [EventRecord]
    let batch: DepositBatchRecord

    private var allocations: [DepositAllocationRecord] {
        allAllocations.filter { $0.batchID == batch.id }.sorted { $0.receivedAt < $1.receivedAt }
    }

    var body: some View {
        List {
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
                        if let personID = allocation.personID, let person = people.first(where: { $0.id == personID }) {
                            Text("Person: \(person.displayName)").font(.caption2).foregroundStyle(.secondary)
                        }
                        if let eventID = allocation.eventID, let event = events.first(where: { $0.id == eventID }) {
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
