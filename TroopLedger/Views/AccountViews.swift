import SwiftUI
import SwiftData

struct AccountListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query private var transactions: [LedgerTransaction]
    @Query private var reconciliations: [ReconciliationRecord]
    @Query private var depositBatches: [DepositBatchRecord]
    @Query private var spreadsheetImports: [GeneralSpreadsheetImportRecord]
    @State private var showingNewAccount = false
    @State private var accountToEdit: AccountRecord?
    @State private var accountMessage: String?

    var body: some View {
        Group {
            if accounts.isEmpty {
                VStack(spacing: 16) {
                    EmptyMessage(title: "No accounts", message: "Add the troop checking account, Cash on Hand, or Undeposited Funds to begin.", systemImage: "building.columns")
                    Button("Create Undeposited Funds Account", systemImage: "tray.full") {
                        createUndepositedFundsAccount()
                    }
                }
            } else {
                List {
                    ForEach(accounts) { account in
                        Button {
                            accountToEdit = account
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(account.name).font(.headline)
                                        if account.kind == .undepositedFunds {
                                            Label("Awaiting deposit", systemImage: "tray.full")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Text([account.kind.rawValue, account.institution].filter { !$0.isEmpty }.joined(separator: " • "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                MoneyText(cents: FinanceEngine.bookBalance(account: account, transactions: transactions))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteAccounts)
                    if UndepositedFundsService.existingAccount(in: accounts) == nil {
                        Section("Funds Awaiting Deposit") {
                            Button("Create Undeposited Funds Account", systemImage: "tray.full") {
                                createUndepositedFundsAccount()
                            }
                            Text("Use this holding account for cash and checks received but not yet included in a bank deposit. It remains separate from Cash on Hand.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .pageToolbar(title: "Accounts") {
            Button("Add Account", systemImage: "plus") { showingNewAccount = true }
        }
        .sheet(isPresented: $showingNewAccount) { AccountFormView() }
        .sheet(item: $accountToEdit) { AccountFormView(account: $0) }
        .alert("Accounts", isPresented: Binding(
            get: { accountMessage != nil }, set: { if !$0 { accountMessage = nil } }
        )) { Button("OK") { accountMessage = nil } } message: { Text(accountMessage ?? "") }
    }

    private func createUndepositedFundsAccount() {
        do {
            _ = try UndepositedFundsService.createAccount(in: modelContext)
        } catch {
            accountMessage = error.localizedDescription
        }
    }

    private func deleteAccounts(at offsets: IndexSet) {
        for index in offsets {
            let account = accounts[index]
            guard RecordDeletionPolicy.canDeleteAccount(
                account.id,
                transactions: transactions,
                reconciliations: reconciliations,
                depositBatches: depositBatches,
                spreadsheetImports: spreadsheetImports
            ) else {
                accountMessage = "This account is referenced by transactions, reconciliations, deposit batches, or import history and cannot be deleted. Mark it inactive instead."
                continue
            }
            AuditLogger.record(
                .delete,
                recordType: "Account",
                recordID: account.id,
                summary: "Deleted account \(account.name)",
                details: AuditLogger.details([
                    ("Type", account.kind.rawValue),
                    ("Institution", account.institution),
                    ("Opening balance", Money.currency(cents: account.openingBalanceCents)),
                ]),
                in: modelContext
            )
            modelContext.delete(account)
        }
    }
}

struct AccountFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query private var reconciliations: [ReconciliationRecord]
    private let account: AccountRecord?
    @State private var name: String
    @State private var institution: String
    @State private var kind: AccountKind
    @State private var openingBalance: String
    @State private var isActive: Bool
    @State private var notes: String
    @State private var errorMessage: String?

    init(account: AccountRecord? = nil) {
        self.account = account
        _name = State(initialValue: account?.name ?? "")
        _institution = State(initialValue: account?.institution ?? "")
        _kind = State(initialValue: account?.kind ?? .checking)
        _openingBalance = State(initialValue: Money.editableString(cents: account?.openingBalanceCents ?? 0))
        _isActive = State(initialValue: account?.isActive ?? true)
        _notes = State(initialValue: account?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Name", text: $name)
                    TextField("Bank or institution", text: $institution)
                    Picker("Type", selection: $kind) {
                        ForEach(AccountKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if kind == .undepositedFunds {
                        Text("This holding account is for cash and checks awaiting a bank deposit. TroopLedger permits one Undeposited Funds account and reports it separately from Cash on Hand.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    AmountField(title: "Opening balance", text: $openingBalance)
                        .disabled(openingBalanceIsLocked)
                    if openingBalanceIsLocked {
                        Text("The opening balance is fixed because this account has completed reconciliations. Record a future-dated adjustment instead of rewriting locked history.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Active", isOn: $isActive)
                }
                Section("Notes") { TextField("Optional notes", text: $notes, axis: .vertical) }
            }
            .formStyle(.grouped)
            .navigationTitle(account == nil ? "New Account" : "Edit Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
        }
        .frame(minWidth: 420, minHeight: 420)
        .alert("Account", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Money.cents(from: openingBalance) != nil }
    private var openingBalanceIsLocked: Bool {
        guard let account else { return false }
        return !ReconciliationPolicy.canEditOpeningBalance(account, reconciliations: reconciliations)
    }

    private func save() {
        guard let cents = Money.cents(from: openingBalance) else { return }
        do {
            try UndepositedFundsService.validateUnique(kind: kind, editingAccountID: account?.id, accounts: accounts)
            let record = account ?? AccountRecord(name: name)
            record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            record.institution = institution.trimmingCharacters(in: .whitespacesAndNewlines)
            record.kind = kind
            if !openingBalanceIsLocked {
                record.openingBalanceCents = cents
            }
            record.isActive = isActive
            record.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let isNew = account == nil
            if isNew { modelContext.insert(record) }
            AuditLogger.record(
                isNew ? .create : .edit,
                recordType: "Account",
                recordID: record.id,
                summary: "\(isNew ? "Created" : "Edited") account \(record.name)",
                details: AuditLogger.details([
                    ("Type", record.kind.rawValue),
                    ("Institution", record.institution),
                    ("Opening balance", Money.currency(cents: record.openingBalanceCents)),
                    ("Active", record.isActive ? "Yes" : "No"),
                ]),
                in: modelContext
            )
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
