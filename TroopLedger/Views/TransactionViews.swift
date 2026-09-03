import SwiftUI
import SwiftData

struct TransactionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LedgerTransaction.date, order: .reverse) private var transactions: [LedgerTransaction]
    @Query(sort: \CashReceiptRecord.date, order: .reverse) private var cashReceipts: [CashReceiptRecord]
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query(sort: \ReconciliationRecord.statementDate, order: .reverse) private var reconciliations: [ReconciliationRecord]
    @Query private var depositAllocations: [DepositAllocationRecord]
    @Query private var depositBatches: [DepositBatchRecord]
    @Query private var reimbursements: [ReimbursementRequest]
    @Query private var memberEntries: [MemberLedgerEntry]
    @State private var searchText = ""
    @State private var showingNewTransaction = false
    @State private var transactionToEdit: LedgerTransaction?
    @State private var presentation = TransactionPresentation.bankRegister
    @State private var selectedTransactionID: UUID?
    @State private var deletionMessage: String?
    @State private var pendingDeletion: LedgerTransaction?
    @State private var showingTransfer = false

    private var filtered: [LedgerTransaction] {
        guard !searchText.isEmpty else { return transactions }
        return transactions.filter {
            $0.payee.localizedCaseInsensitiveContains(searchText) ||
            $0.memo.localizedCaseInsensitiveContains(searchText) ||
            $0.category.localizedCaseInsensitiveContains(searchText) ||
            $0.checkNumber.localizedCaseInsensitiveContains(searchText) ||
            $0.adjustmentReason.localizedCaseInsensitiveContains(searchText) ||
            Money.editableString(cents: $0.amountCents).contains(searchText) ||
            Money.currency(cents: $0.amountCents).contains(searchText)
        }
    }

    private var filteredCashReceipts: [CashReceiptRecord] {
        guard !searchText.isEmpty else { return cashReceipts }
        return cashReceipts.filter {
            $0.personName.localizedCaseInsensitiveContains(searchText) ||
            $0.purpose.localizedCaseInsensitiveContains(searchText) ||
            $0.paymentKind.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var selectedTransaction: LedgerTransaction? {
        guard let selectedTransactionID else { return nil }
        return transactions.first { $0.id == selectedTransactionID }
    }

    private var reportableAccounts: [AccountRecord] {
        accounts.filter { $0.isActive || FinanceEngine.bookBalance(account: $0, transactions: transactions) != 0 }
    }

    private var bookBalance: Int64 {
        reportableAccounts.reduce(0) {
            $0 + FinanceEngine.bookBalance(account: $1, transactions: transactions)
        }
    }

    private var clearedBalance: Int64 {
        reportableAccounts.reduce(0) {
            $0 + FinanceEngine.clearedBalance(account: $1, transactions: transactions)
        }
    }

    /// Only bank-type accounts clear against statements; cash and Undeposited Funds entries never do.
    private var bankAccountIDs: Set<UUID> {
        Set(accounts.filter { $0.kind != .cash && $0.kind != .undepositedFunds }.map(\.id))
    }
    private var unclearedBankTransactions: [LedgerTransaction] {
        transactions.filter { !$0.isCleared && $0.accountID.map(bankAccountIDs.contains) == true }
    }
    private var unclearedTotal: Int64 {
        unclearedBankTransactions.reduce(0) { $0 + $1.signedAmountCents }
    }

    var body: some View {
        content
        .pageToolbar(title: "Transactions") {
            Button("Transfer", systemImage: "arrow.left.arrow.right") { showingTransfer = true }
                .disabled(accounts.filter(\.isActive).count < 2 || presentation != .bankRegister)
            Button("Add Transaction", systemImage: "plus") { showingNewTransaction = true }
                .buttonStyle(.fieldbookProminent)
                .disabled(accounts.isEmpty || presentation != .bankRegister)
        }
        .sheet(isPresented: $showingNewTransaction) { TransactionFormView() }
        .sheet(isPresented: $showingTransfer) { AccountTransferFormView() }
        .sheet(item: $transactionToEdit) { TransactionFormView(transaction: $0) }
        .confirmationDialog(
            "Delete this transaction?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { transaction in
            Button("Delete \(Money.currency(cents: transaction.amountCents)) \(transaction.direction.rawValue.lowercased())", role: .destructive) {
                deleteTransaction(transaction)
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { transaction in
            Text("\(transaction.payee.isEmpty ? transaction.category : transaction.payee) on \(transaction.date.formatted(date: .long, time: .omitted)) will be removed from the register. This cannot be undone; only the audit log will record it.")
        }
        .alert("Transactions", isPresented: Binding(
            get: { deletionMessage != nil },
            set: { if !$0 { deletionMessage = nil } }
        )) {
            Button("OK") { deletionMessage = nil }
        } message: {
            Text(deletionMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
#if os(macOS)
        macWorkspace
#else
        standardContent
#endif
    }

    private var standardContent: some View {
        VStack(spacing: 0) {
            Picker("Register view", selection: $presentation) {
                ForEach(TransactionPresentation.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            if presentation == .cashReceipts {
                if cashReceipts.isEmpty {
                    EmptyMessage(title: "No cash receipts", message: "Imported cash-register rows will appear here without duplicating checking-account deposits.", systemImage: "banknote")
                } else {
                    List {
                        Section {
                            Text("Cash receipts preserve the workbook’s Cash Register detail. They are not added again to the checking-account balance.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(filteredCashReceipts) { receipt in
                            CashReceiptRow(receipt: receipt)
                        }
                    }
                    .searchable(text: $searchText, prompt: "Person, purpose, or payment type")
                }
            } else if transactions.isEmpty {
                EmptyMessage(title: "No transactions", message: accounts.isEmpty ? "Add an account first, then enter deposits and expenses." : "Enter the first deposit or expense.", systemImage: "list.bullet.rectangle")
            } else {
                List {
                    ForEach(filtered) { transaction in
                        let isLocked = PeriodLocking.isLocked(transaction, reconciliations: reconciliations)
                        let isBatchProtected = transaction.isTransfer || depositAllocations.contains { $0.sourceTransactionID == transaction.id }
                        Button { transactionToEdit = transaction } label: {
                            TransactionRow(
                                transaction: transaction,
                                accountName: accountName(transaction.accountID),
                                isLocked: isLocked
                            )
                        }
                        .buttonStyle(.plain)
                        .deleteDisabled(isLocked || isBatchProtected)
                    }
                    .onDelete(perform: deleteTransactions)
                }
                .searchable(text: $searchText, prompt: "Payee, category, memo, check, or adjustment reason")
            }
        }
    }

#if os(macOS)
    private var macWorkspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Register view", selection: $presentation) {
                    ForEach(TransactionPresentation.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)

                Spacer()

                TextField(
                    presentation == .bankRegister ? "Search payee, category, or memo" : "Search receipts",
                    text: $searchText
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.regularMaterial)

            Divider()

            if presentation == .cashReceipts {
                macCashReceipts
            } else if transactions.isEmpty {
                EmptyMessage(
                    title: "No transactions",
                    message: accounts.isEmpty ? "Add an account first, then enter deposits and expenses." : "Enter the first deposit or expense.",
                    systemImage: "list.bullet.rectangle"
                )
            } else {
                VStack(spacing: 0) {
                    transactionSummary
                    Divider()
                    GeometryReader { proxy in
                        HStack(spacing: 0) {
                            transactionRegister
                            if proxy.size.width >= 830 {
                                Divider()
                                transactionInspector
                                    .frame(width: 300)
                            }
                        }
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.018))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if selectedTransactionID == nil { selectedTransactionID = filtered.first?.id }
        }
        .onChange(of: searchText) { _, _ in
            if !filtered.contains(where: { $0.id == selectedTransactionID }) {
                selectedTransactionID = filtered.first?.id
            }
        }
    }

    private var transactionSummary: some View {
        HStack(spacing: 0) {
            registerSummaryValue("Ledger balance", cents: bookBalance)
            Divider().frame(height: 34).padding(.horizontal, 14)
            registerSummaryValue("Cleared", cents: clearedBalance)
            Divider().frame(height: 34).padding(.horizontal, 14)
            VStack(alignment: .leading, spacing: 3) {
                Text("Uncleared").font(.caption).foregroundStyle(.secondary)
                Text("\(unclearedBankTransactions.count)").font(.headline).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider().frame(height: 34).padding(.horizontal, 14)
            registerSummaryValue("Uncleared total", cents: unclearedTotal)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.045))
    }

    private func registerSummaryValue(_ title: String, cents: Int64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            MoneyText(cents: cents, colorBySign: title == "Uncleared total")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transactionRegister: some View {
        VStack(spacing: 0) {
            registerHeader
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { transaction in
                        registerRow(transaction)
                        Divider()
                    }
                }
            }
        }
        .frame(minWidth: 500, maxWidth: .infinity)
    }

    private var registerHeader: some View {
        HStack(spacing: 10) {
            Text("DATE").frame(width: 76, alignment: .leading)
            Text("PAYEE / MEMO").frame(maxWidth: .infinity, alignment: .leading)
            Text("CATEGORY").frame(width: 120, alignment: .leading)
            Text("STATUS").frame(width: 82, alignment: .leading)
            Text("AMOUNT").frame(width: 90, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.regularMaterial)
    }

    private func registerRow(_ transaction: LedgerTransaction) -> some View {
        let isSelected = selectedTransactionID == transaction.id
        let isLocked = PeriodLocking.isLocked(transaction, reconciliations: reconciliations)
        return Button {
            selectedTransactionID = transaction.id
        } label: {
            HStack(spacing: 10) {
                Text(transaction.date.formatted(.dateTime.month(.abbreviated).day()))
                    .frame(width: 76, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(transaction.payee.isEmpty ? transaction.category : transaction.payee)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if isLocked {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !transaction.memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(transaction.memo)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(transaction.category)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
                    .frame(width: 120, alignment: .leading)

                Label(transaction.isCleared ? "Cleared" : "Uncleared", systemImage: transaction.isCleared ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(transaction.isCleared ? Color.green : Color.secondary)
                    .labelStyle(.titleAndIcon)
                    .frame(width: 82, alignment: .leading)

                MoneyText(cents: transaction.signedAmountCents, colorBySign: true)
                    .fontWeight(.semibold)
                    .frame(width: 90, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { transactionToEdit = transaction })
        .contextMenu {
            Button("Edit Transaction", systemImage: "pencil") { transactionToEdit = transaction }
            Button("Delete Transaction", systemImage: "trash", role: .destructive) { requestDeletion(transaction) }
                .disabled(transactionIsProtected(transaction))
        }
    }

    @ViewBuilder
    private var transactionInspector: some View {
        if let transaction = selectedTransaction {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("SELECTED TRANSACTION")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Text(transaction.payee.isEmpty ? transaction.category : transaction.payee)
                        .font(.title3.bold())
                        .padding(.top, 5)
                    Text("\(transaction.date.formatted(date: .long, time: .omitted)) • \(accountName(transaction.accountID))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    MoneyText(cents: transaction.signedAmountCents, colorBySign: true)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .padding(.vertical, 18)

                    inspectorField("Status", transaction.isCleared ? "Cleared" : "Uncleared")
                    inspectorField("Category", transaction.category)
                    if !transaction.checkNumber.isEmpty { inspectorField("Check number", transaction.checkNumber) }
                    if !transaction.memo.isEmpty { inspectorField("Memo", transaction.memo) }
                    inspectorField("Audit status", transactionIsProtected(transaction) ? "Locked or batch-protected" : "Editable")

                    HStack {
                        Button("Delete", systemImage: "trash", role: .destructive) { requestDeletion(transaction) }
                            .disabled(transactionIsProtected(transaction))
                        Spacer()
                        Button("Edit", systemImage: "pencil") { transactionToEdit = transaction }
                            .buttonStyle(.fieldbookProminent)
                    }
                    .padding(.top, 18)
                }
                .padding(17)
            }
            .background(Color.secondary.opacity(0.035))
        } else {
            ContentUnavailableView("Select a Transaction", systemImage: "cursorarrow.click")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.035))
        }
    }

    private func inspectorField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var macCashReceipts: some View {
        Group {
            if cashReceipts.isEmpty {
                EmptyMessage(title: "No cash receipts", message: "Imported cash-register rows will appear here without duplicating checking-account deposits.", systemImage: "banknote")
            } else {
                List {
                    Section {
                        Label("Cash receipts preserve imported detail and do not post to checking a second time.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(filteredCashReceipts) { receipt in CashReceiptRow(receipt: receipt) }
                }
            }
        }
    }
#endif

    private func accountName(_ id: UUID?) -> String {
        accounts.first(where: { $0.id == id })?.name ?? "No account"
    }

    private func deleteTransactions(at offsets: IndexSet) {
        // Swipe-to-delete on a financial record needs a confirmation step; queue the first item.
        guard let index = offsets.first else { return }
        requestDeletion(filtered[index])
    }

    private func requestDeletion(_ transaction: LedgerTransaction) {
        guard !transactionIsProtected(transaction) else {
            deletionMessage = "This transaction is locked or referenced by a deposit, reimbursement, member-ledger entry, or adjustment and cannot be deleted."
            return
        }
        pendingDeletion = transaction
    }

    private func transactionIsProtected(_ transaction: LedgerTransaction) -> Bool {
        transaction.isTransfer ||
        !RecordDeletionPolicy.canDeleteTransaction(
            transaction.id,
            transactions: transactions,
            depositAllocations: depositAllocations,
            depositBatches: depositBatches,
            reimbursements: reimbursements,
            memberEntries: memberEntries
        ) ||
        PeriodLocking.isLocked(transaction, reconciliations: reconciliations)
    }

    private func deleteTransaction(_ transaction: LedgerTransaction) {
        guard !transactionIsProtected(transaction) else {
            deletionMessage = "This transaction is locked or referenced by a deposit, reimbursement, member-ledger entry, or adjustment and cannot be deleted."
            return
        }
        AuditLogger.record(
            .delete,
            recordType: "Transaction",
            recordID: transaction.id,
            summary: "Deleted transaction \(transaction.payee.isEmpty ? transaction.category : transaction.payee)",
            details: AuditLogger.details([
                ("Account", accountName(transaction.accountID)),
                ("Date", transaction.date.formatted(date: .numeric, time: .omitted)),
                ("Type", transaction.direction.rawValue),
                ("Amount", Money.currency(cents: transaction.signedAmountCents)),
                ("Payee", transaction.payee),
                ("Category", transaction.category),
                ("Check / reference", transaction.checkNumber),
                ("Memo", transaction.memo),
                ("Cleared", transaction.isCleared ? "Yes" : "No"),
                ("Person ID", transaction.personID?.uuidString),
                ("Event ID", transaction.eventID?.uuidString),
            ]),
            in: modelContext
        )
        if selectedTransactionID == transaction.id {
            selectedTransactionID = filtered.first(where: { $0.id != transaction.id })?.id
        }
        modelContext.delete(transaction)
        pendingDeletion = nil
        do {
            try modelContext.save()
        } catch {
            deletionMessage = "The transaction could not be deleted: \(error.localizedDescription)"
        }
    }
}

private enum TransactionPresentation: String, CaseIterable, Identifiable {
    case bankRegister
    case cashReceipts

    var id: String { rawValue }
    var title: String { self == .bankRegister ? "Bank Register" : "Cash Receipts" }
}

private struct CashReceiptRow: View {
    let receipt: CashReceiptRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "banknote")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(receipt.personName.isEmpty ? receipt.purpose : receipt.personName)
                    .font(.headline)
                Text([receipt.date.formatted(date: .abbreviated, time: .omitted), receipt.purpose, receipt.paymentKind]
                    .filter { !$0.isEmpty }
                    .joined(separator: " • "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(cents: receipt.amountCents)
        }
    }
}

private struct TransactionRow: View {
    let transaction: LedgerTransaction
    let accountName: String
    let isLocked: Bool

    private var displayMemo: String {
        transaction.memo.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 3) {
                Image(systemName: transaction.isCleared ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(transaction.isCleared ? .green : .secondary)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(transaction.payee.isEmpty ? transaction.category : transaction.payee).font(.headline)
                    if transaction.isTransfer {
                        Text(transaction.depositBatchID == nil ? "Transfer" : "Batch Transfer")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.16), in: Capsule())
                    }
                    if transaction.isAdjustment {
                        Text("Adjustment")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.16), in: Capsule())
                    }
                }
                Text("\(transaction.date.formatted(date: .abbreviated, time: .omitted)) • \(transaction.category) • \(accountName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !displayMemo.isEmpty {
                    Text(displayMemo)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Memo: \(displayMemo)")
                }
            }
            Spacer()
            MoneyText(cents: transaction.signedAmountCents, colorBySign: true)
        }
        .contentShape(Rectangle())
        .accessibilityValue(isLocked ? "Locked transaction" : "Editable transaction")
    }
}

struct TransactionFormView: View {
    @Query(sort: \ReconciliationRecord.statementDate, order: .reverse) private var reconciliations: [ReconciliationRecord]
    @Query private var depositAllocations: [DepositAllocationRecord]
    let transaction: LedgerTransaction?

    init(transaction: LedgerTransaction? = nil) {
        self.transaction = transaction
    }

    var body: some View {
        if let transaction, transaction.isTransfer || depositAllocations.contains(where: { $0.sourceTransactionID == transaction.id }) {
            BatchProtectedTransactionView(transaction: transaction)
        } else if let transaction, PeriodLocking.isLocked(transaction, reconciliations: reconciliations) {
            LockedTransactionView(transaction: transaction)
        } else {
            TransactionEditorView(transaction: transaction)
        }
    }
}

private struct BatchProtectedTransactionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query(sort: \ReconciliationRecord.statementDate, order: .reverse) private var reconciliations: [ReconciliationRecord]
    let transaction: LedgerTransaction
    @State private var confirmingDeletion = false
    @State private var errorMessage: String?

    private var isManualTransfer: Bool { transaction.isTransfer && transaction.depositBatchID == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Batch-Protected Transaction") {
                    LabeledContent("Account", value: accounts.first { $0.id == transaction.accountID }?.name ?? "Unknown account")
                    LabeledContent("Date", value: transaction.date.formatted(date: .long, time: .omitted))
                    LabeledContent("Type", value: transaction.direction.rawValue)
                    LabeledContent("Amount", value: Money.currency(cents: transaction.amountCents))
                    LabeledContent("Payee", value: transaction.payee)
                    LabeledContent("Category", value: transaction.category)
                    if !transaction.memo.isEmpty { LabeledContent("Memo", value: transaction.memo) }
                }
                Section {
                    Label(
                        transaction.isTransfer
                            ? (transaction.depositBatchID == nil
                                ? "This is one side of a matched transfer between troop accounts. Transfers are excluded from income and expense reports."
                                : "This matched account-transfer entry is controlled by its deposit batch.")
                            : "This receipt is an immutable allocation in a posted deposit batch.",
                        systemImage: "lock.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if isManualTransfer {
                    Section {
                        Button("Delete Both Sides of This Transfer", systemImage: "trash", role: .destructive) { confirmingDeletion = true }
                        Text("A transfer entered by mistake is removed from both accounts together. Transfers in a reconciled period cannot be deleted.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isManualTransfer ? "Account Transfer" : "Deposit Transaction")
            .toolbar { Button("Done") { dismiss() } }
        }
        .frame(minWidth: 460, minHeight: 420)
        .confirmationDialog("Delete this transfer from both accounts?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Delete Transfer", role: .destructive) { deleteTransfer() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Transfer", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func deleteTransfer() {
        guard let groupID = transaction.transferGroupID else { return }
        do {
            try AccountTransferService.delete(transferGroupID: groupID, reconciliations: reconciliations, in: modelContext)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct TransactionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query(sort: \PersonRecord.lastName) private var people: [PersonRecord]
    @Query(sort: \EventRecord.startDate, order: .reverse) private var events: [EventRecord]
    @Query(sort: \ReconciliationRecord.statementDate, order: .reverse) private var reconciliations: [ReconciliationRecord]
    @Query(sort: \LedgerCategoryRecord.sortOrder) private var categoryDefinitions: [LedgerCategoryRecord]
    @Query private var allTransactions: [LedgerTransaction]
    @Query private var reimbursements: [ReimbursementRequest]
    @Query private var memberEntries: [MemberLedgerEntry]
    private let transaction: LedgerTransaction?
    private let adjustedTransaction: LedgerTransaction?
    @State private var accountID: UUID?
    @State private var date: Date
    @State private var direction: TransactionDirection
    @State private var amount: String
    @State private var checkNumber: String
    @State private var payee: String
    @State private var category: String
    @State private var memo: String
    @State private var personID: UUID?
    @State private var eventID: UUID?
    @State private var isCleared: Bool
    @State private var adjustmentReason: String
    @State private var preparedAdjustmentDate = false
    @State private var errorMessage: String?

    /// True when another money record (a paid reimbursement or a member payment) points at this entry.
    private var isLinkedMoneyRecord: Bool {
        guard let transaction else { return false }
        return reimbursements.contains { $0.linkedTransactionID == transaction.id }
            || memberEntries.contains { $0.accountTransactionID == transaction.id }
    }

    /// Archived accounts stay out of the picker unless the record being edited already lives there.
    private var selectableAccounts: [AccountRecord] {
        accounts.filter { $0.isActive || $0.id == transaction?.accountID || $0.id == adjustedTransaction?.accountID }
    }

    init(transaction: LedgerTransaction? = nil, adjusting adjustedTransaction: LedgerTransaction? = nil) {
        self.transaction = transaction
        self.adjustedTransaction = adjustedTransaction
        let source = transaction ?? adjustedTransaction
        _accountID = State(initialValue: source?.accountID)
        _date = State(initialValue: transaction?.date ?? Date())
        _direction = State(initialValue: transaction?.direction ?? adjustedTransaction?.direction.opposite ?? .expense)
        _amount = State(initialValue: Money.editableString(cents: source?.amountCents ?? 0))
        _checkNumber = State(initialValue: transaction?.checkNumber ?? "")
        _payee = State(initialValue: source?.payee ?? "")
        _category = State(initialValue: source?.category ?? "")
        _memo = State(initialValue: transaction?.memo ?? "")
        _personID = State(initialValue: source?.personID)
        _eventID = State(initialValue: source?.eventID)
        _isCleared = State(initialValue: transaction?.isCleared ?? false)
        _adjustmentReason = State(initialValue: transaction?.adjustmentReason ?? "")
    }

    private var isAdjustment: Bool {
        adjustedTransaction != nil || transaction?.isAdjustment == true
    }

    private var adjustmentTargetID: UUID? {
        adjustedTransaction?.id ?? transaction?.adjustsTransactionID
    }

    private var availableCategories: [LedgerCategoryRecord] {
        categoryDefinitions
            .filter { $0.isActive && $0.direction == direction }
            .sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private var categoryDefinitionSelection: Binding<UUID?> {
        Binding(
            get: {
                availableCategories.first {
                    CategoryCatalog.key(name: $0.name, direction: $0.direction) == CategoryCatalog.key(name: category, direction: direction)
                }?.id
            },
            set: { selectedID in
                guard let selectedID, let selected = availableCategories.first(where: { $0.id == selectedID }) else { return }
                category = selected.name
            }
        )
    }

    private var postingValidation: LedgerPostingValidation {
        PeriodLocking.validatePosting(
            accountID: accountID,
            date: date,
            isAdjustment: isAdjustment,
            adjustsTransactionID: adjustmentTargetID,
            adjustmentReason: adjustmentReason,
            reconciliations: reconciliations,
            activeAccountIDs: Set(selectableAccounts.map(\.id))
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if isAdjustment {
                    Section("Adjustment") {
                        Label("This entry corrects a locked transaction without rewriting reconciled history.", systemImage: "arrow.uturn.left.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let adjustedTransaction {
                            LabeledContent("Corrects") {
                                Text(adjustedTransaction.payee.isEmpty ? adjustedTransaction.category : adjustedTransaction.payee)
                            }
                            LabeledContent("Original date") {
                                Text(adjustedTransaction.date.formatted(date: .abbreviated, time: .omitted))
                            }
                        }
                        TextField("Required explanation", text: $adjustmentReason, axis: .vertical)
                    }
                }

                if isLinkedMoneyRecord {
                    Section {
                        Label("This entry backs a reimbursement payment or a member-ledger payment. Its account, type, and amount are fixed; memo, category, and links can still change.", systemImage: "link")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Transaction") {
                    Picker("Account", selection: $accountID) {
                        Text("Choose an account").tag(nil as UUID?)
                        ForEach(selectableAccounts) { Text($0.isActive ? $0.name : "\($0.name) (inactive)").tag($0.id as UUID?) }
                    }
                    .disabled(isAdjustment)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Type", selection: $direction) {
                        ForEach(TransactionDirection.allCases) { Text($0.rawValue).tag($0) }
                    }
                    AmountField(title: "Amount", text: $amount)
                    TextField("Check / reference number", text: $checkNumber)
                    TextField(direction == .income ? "Received from" : "Payee", text: $payee)
                    Picker("Saved category", selection: categoryDefinitionSelection) {
                        Text("Custom or existing category").tag(nil as UUID?)
                        ForEach(availableCategories) { definition in
                            Text(definition.name).tag(definition.id as UUID?)
                        }
                    }
                    TextField("Category name", text: $category)
                    Toggle("Cleared bank", isOn: $isCleared)
                }
                Section("Links") {
                    Picker("Person", selection: $personID) {
                        Text("None").tag(nil as UUID?)
                        ForEach(people) { Text($0.displayName).tag($0.id as UUID?) }
                    }
                    Picker("Event", selection: $eventID) {
                        Text("None").tag(nil as UUID?)
                        ForEach(events) { Text($0.name).tag($0.id as UUID?) }
                    }
                }
                Section("Memo") { TextField("Notes or receipt reference", text: $memo, axis: .vertical) }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .onAppear(perform: prepareDefaults)
        }
        .frame(minWidth: 470, minHeight: 620)
        .alert("Transaction", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private var navigationTitle: String {
        if adjustedTransaction != nil { return "New Adjustment" }
        if transaction != nil { return isAdjustment ? "Edit Adjustment" : "Edit Transaction" }
        return "New Transaction"
    }

    private var validationMessage: String? {
        switch postingValidation {
        case .valid:
            return nil
        case .accountRequired:
            return "Choose an account."
        case .inactiveAccount:
            return "That account is inactive. Reactivate it in Accounts or choose an active account."
        case .locked(let lockDate):
            return "This account is locked through \(lockDate.formatted(date: .long, time: .omitted)). Use a later date."
        case .adjustmentTargetRequired:
            return "An adjustment must link to the transaction it corrects."
        case .adjustmentReasonRequired:
            return "Explain why this adjustment is needed."
        }
    }

    private var canSave: Bool {
        postingValidation == .valid &&
        Money.cents(from: amount).map { $0 > 0 } == true &&
        !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func prepareDefaults() {
        _ = try? CategoryCatalog.seedMissingDefinitions(in: modelContext)
        if accountID == nil { accountID = accounts.first(where: { $0.isActive && $0.kind == .checking })?.id ?? accounts.first(where: \.isActive)?.id }
        guard adjustedTransaction != nil, !preparedAdjustmentDate else { return }
        date = PeriodLocking.firstUnlockedDate(
            for: accountID,
            reconciliations: reconciliations,
            relativeTo: date
        )
        preparedAdjustmentDate = true
    }

    /// Fields captured before an edit so the audit entry can show what changed, not only the final values.
    private struct TransactionSnapshot {
        let values: [(String, String)]

        init(_ record: LedgerTransaction, accountName: (UUID?) -> String) {
            values = [
                ("Account", accountName(record.accountID)),
                ("Date", record.date.formatted(date: .numeric, time: .omitted)),
                ("Type", record.direction.rawValue),
                ("Amount", Money.currency(cents: record.amountCents)),
                ("Check / reference", record.checkNumber),
                ("Payee", record.payee),
                ("Category", record.category),
                ("Memo", record.memo),
                ("Person ID", record.personID?.uuidString ?? ""),
                ("Event ID", record.eventID?.uuidString ?? ""),
                ("Cleared", record.isCleared ? "Yes" : "No"),
                ("Adjustment reason", record.adjustmentReason),
            ]
        }

        func changes(to other: TransactionSnapshot) -> [(String, String?)] {
            zip(values, other.values).compactMap { before, after in
                before.1 == after.1 ? nil : ("Changed \(before.0)", "\(before.1.isEmpty ? "(empty)" : before.1) → \(after.1.isEmpty ? "(empty)" : after.1)")
            }
        }
    }

    private func save() {
        guard canSave, let cents = Money.cents(from: amount), cents > 0 else { return }
        if let account = accounts.first(where: { $0.id == accountID }) {
            do {
                try HoldingAccountPolicy.validate(account: account, transactions: allTransactions, editing: transaction?.id, direction: direction, amountCents: cents)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        if let transaction {
            do {
                try LinkedTransactionPolicy.validateEdit(of: transaction, newAccountID: accountID, newDirection: direction, newAmountCents: cents, reimbursements: reimbursements, memberEntries: memberEntries)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        let accountName: (UUID?) -> String = { id in accounts.first { $0.id == id }?.name ?? "No account" }
        let before = transaction.map { TransactionSnapshot($0, accountName: accountName) }
        let record = transaction ?? LedgerTransaction(accountID: accountID, date: date, direction: direction, amountCents: cents, payee: payee, category: category)
        record.accountID = accountID
        record.date = date
        record.direction = direction
        record.amountCents = cents
        record.checkNumber = checkNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        record.payee = payee.trimmingCharacters(in: .whitespacesAndNewlines)
        record.category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        record.memo = memo
        record.personID = personID
        record.eventID = eventID
        record.isCleared = isCleared
        record.isAdjustment = isAdjustment
        record.adjustsTransactionID = isAdjustment ? adjustmentTargetID : nil
        record.adjustmentReason = isAdjustment ? adjustmentReason.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        record.modifiedAt = Date()
        let isNew = transaction == nil
        if isNew { modelContext.insert(record) }
        let action: AuditAction = isNew && isAdjustment ? .adjustment : (isNew ? .create : .edit)
        let displayName = record.payee.isEmpty ? record.category : record.payee
        // An edit entry that lists only the final values cannot show what was changed; include a
        // field-by-field before → after diff so the audit trail is reviewable.
        let changes = before?.changes(to: TransactionSnapshot(record, accountName: accountName)) ?? []
        AuditLogger.record(
            action,
            recordType: "Transaction",
            recordID: record.id,
            summary: isAdjustment
                ? "\(isNew ? "Created" : "Edited") adjustment for \(displayName)"
                : "\(isNew ? "Created" : "Edited") transaction \(displayName)",
            details: AuditLogger.details([
                ("Date", record.date.formatted(date: .numeric, time: .omitted)),
                ("Amount", Money.currency(cents: record.signedAmountCents)),
                ("Category", record.category),
                ("Corrects transaction ID", record.adjustsTransactionID?.uuidString),
                ("Adjustment reason", record.adjustmentReason),
            ] + changes),
            in: modelContext
        )
        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = "The transaction could not be saved: \(error.localizedDescription)"
        }
    }
}

private struct LockedTransactionView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query(sort: \LedgerTransaction.date, order: .reverse) private var transactions: [LedgerTransaction]
    @Query(sort: \ReconciliationRecord.statementDate, order: .reverse) private var reconciliations: [ReconciliationRecord]
    let transaction: LedgerTransaction
    @State private var showingAdjustment = false

    private var lockDate: Date? {
        PeriodLocking.latestLockDate(for: transaction.accountID, reconciliations: reconciliations)
    }

    private var adjustedTransaction: LedgerTransaction? {
        guard let id = transaction.adjustsTransactionID else { return nil }
        return transactions.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Locked through \(lockDate?.formatted(date: .long, time: .omitted) ?? "a reconciled period")", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                    Text("This transaction is read-only because its period has been reconciled. Create a dated adjustment to correct it without changing history.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("Transaction") {
                    LabeledContent("Account", value: accounts.first(where: { $0.id == transaction.accountID })?.name ?? "No account")
                    LabeledContent("Date", value: transaction.date.formatted(date: .long, time: .omitted))
                    LabeledContent("Type", value: transaction.direction.rawValue)
                    LabeledContent("Amount") { MoneyText(cents: transaction.amountCents) }
                    LabeledContent(transaction.direction == .income ? "Received from" : "Payee", value: transaction.payee)
                    LabeledContent("Category", value: transaction.category)
                    LabeledContent("Cleared", value: transaction.isCleared ? "Yes" : "No")
                    if !transaction.checkNumber.isEmpty {
                        LabeledContent("Check / reference", value: transaction.checkNumber)
                    }
                }
                if transaction.isAdjustment {
                    Section("Adjustment") {
                        if let adjustedTransaction {
                            LabeledContent("Corrects", value: adjustedTransaction.payee.isEmpty ? adjustedTransaction.category : adjustedTransaction.payee)
                        }
                        LabeledContent("Explanation", value: transaction.adjustmentReason)
                    }
                }
                if !transaction.memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Memo") { Text(transaction.memo) }
                }
                Section {
                    Button("Create Adjustment", systemImage: "arrow.uturn.left.circle") {
                        showingAdjustment = true
                    }
                } footer: {
                    Text("The adjustment will be linked to this record and must use a date after the locked period.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Locked Transaction")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .frame(minWidth: 470, minHeight: 620)
        .sheet(isPresented: $showingAdjustment) {
            TransactionEditorView(adjusting: transaction)
        }
    }
}

private extension TransactionDirection {
    var opposite: TransactionDirection {
        self == .income ? .expense : .income
    }
}

/// Records a move between two troop accounts as a matched transfer pair instead of an expense and an income.
struct AccountTransferFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query(sort: \ReconciliationRecord.statementDate, order: .reverse) private var reconciliations: [ReconciliationRecord]
    @State private var fromAccountID: UUID?
    @State private var toAccountID: UUID?
    @State private var date = Date()
    @State private var amount = ""
    @State private var reference = ""
    @State private var memo = ""
    @State private var errorMessage: String?

    /// Undeposited Funds moves only through deposit batches, which preserve receipt allocations.
    private var activeAccounts: [AccountRecord] { accounts.filter { $0.isActive && $0.kind != .undepositedFunds } }
    private var canSave: Bool {
        fromAccountID != nil && toAccountID != nil && fromAccountID != toAccountID && (Money.cents(from: amount) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Transfer") {
                    Picker("From", selection: $fromAccountID) {
                        Text("Choose an account").tag(nil as UUID?)
                        ForEach(activeAccounts) { Text($0.name).tag($0.id as UUID?) }
                    }
                    Picker("To", selection: $toAccountID) {
                        Text("Choose an account").tag(nil as UUID?)
                        ForEach(activeAccounts) { Text($0.name).tag($0.id as UUID?) }
                    }
                    DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                    AmountField(title: "Amount", text: $amount)
                    TextField("Confirmation or check number", text: $reference)
                }
                Section("Memo") { TextField("Purpose of the transfer", text: $memo, axis: .vertical) }
                Section {
                    Text("Both sides are recorded as matched transfer entries. They change account balances but are excluded from income, expense, and budget reports.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Transfer Between Accounts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Post Transfer", action: save).disabled(!canSave) }
            }
            .onAppear {
                if fromAccountID == nil { fromAccountID = activeAccounts.first(where: { $0.kind == .checking })?.id ?? activeAccounts.first?.id }
                if toAccountID == nil { toAccountID = activeAccounts.first(where: { $0.id != fromAccountID })?.id }
            }
        }
        .frame(minWidth: 460, minHeight: 480)
        .alert("Transfer", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func save() {
        do {
            guard let cents = Money.cents(from: amount) else { throw AccountTransferError.invalidAmount }
            _ = try AccountTransferService.post(
                fromAccountID: fromAccountID,
                toAccountID: toAccountID,
                date: date,
                amountCents: cents,
                reference: reference,
                memo: memo,
                reconciliations: reconciliations,
                in: modelContext
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
