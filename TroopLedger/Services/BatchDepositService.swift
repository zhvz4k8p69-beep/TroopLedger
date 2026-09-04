import Foundation
import SwiftData

enum BatchDepositError: LocalizedError, Equatable {
    case undepositedFundsAccountRequired
    case destinationAccountRequired
    case invalidDestinationAccount
    case noReceiptsSelected
    case receiptNoLongerAvailable
    case receiptAlreadyDeposited
    case invalidReceiptAmount
    case insufficientUndepositedFunds
    case importedReceiptDateLocked(Date)
    case undepositedPeriodLocked(Date)
    case destinationPeriodLocked(Date)
    case depositDateInFuture
    case receiptAfterDepositDate

    var errorDescription: String? {
        switch self {
        case .undepositedFundsAccountRequired: "Create or reactivate the Undeposited Funds account first."
        case .destinationAccountRequired: "Choose the bank account receiving this deposit."
        case .invalidDestinationAccount: "The deposit destination must be an active bank or other non-cash account."
        case .noReceiptsSelected: "Select at least one receipt for this deposit."
        case .receiptNoLongerAvailable: "One of the selected receipts no longer exists or is no longer held in Undeposited Funds."
        case .receiptAlreadyDeposited: "One of the selected receipts is already assigned to a deposit batch."
        case .invalidReceiptAmount: "Deposit receipts must have an amount greater than zero."
        case .insufficientUndepositedFunds: "The deposit would make Undeposited Funds negative. Review its opening balance and receipt transactions."
        case .importedReceiptDateLocked(let date): "An imported receipt falls in a period locked through \(date.formatted(date: .long, time: .omitted)). Exclude that receipt or record an authorized adjustment."
        case .undepositedPeriodLocked(let date): "Undeposited Funds is locked through \(date.formatted(date: .long, time: .omitted)). Choose a later deposit date."
        case .destinationPeriodLocked(let date): "The destination account is locked through \(date.formatted(date: .long, time: .omitted)). Choose a later deposit date."
        case .depositDateInFuture: "A deposit cannot be dated in the future. Record it on the day the bank received it."
        case .receiptAfterDepositDate: "One of the selected receipts is dated after the deposit date. Money cannot be deposited before it was received."
        }
    }
}

@MainActor
enum BatchDepositService {
    static func eligibleTransactions(
        undepositedFundsAccountID: UUID?,
        transactions: [LedgerTransaction],
        allocations: [DepositAllocationRecord]
    ) -> [LedgerTransaction] {
        // With no holding account, `nil == nil` matched every account-less receipt and offered rows that
        // `post` would then reject.
        guard let undepositedFundsAccountID else { return [] }
        let used = Set(allocations.compactMap(\.sourceTransactionID))
        return transactions.filter {
            $0.accountID == undepositedFundsAccountID
                && $0.direction == .income
                && $0.amountCents > 0
                && !$0.isTransfer
                && !used.contains($0.id)
        }
        .sorted { $0.date < $1.date }
    }

    static func eligibleCashReceipts(
        receipts: [CashReceiptRecord],
        allocations: [DepositAllocationRecord]
    ) -> [CashReceiptRecord] {
        let used = Set(allocations.compactMap(\.sourceCashReceiptID))
        return receipts.filter { $0.amountCents > 0 && !used.contains($0.id) }.sorted { $0.date < $1.date }
    }

    @discardableResult
    static func post(
        destinationAccountID: UUID?,
        depositDate: Date,
        reference: String,
        notes: String,
        sourceTransactionIDs: Set<UUID>,
        sourceCashReceiptIDs: Set<UUID>,
        reconciliations: [ReconciliationRecord],
        calendar: Calendar = .current,
        now: Date = Date(),
        in modelContext: ModelContext
    ) throws -> DepositBatchRecord {
        // A future-dated deposit books bank income that does not exist yet and skews every report until then.
        guard calendar.startOfDay(for: depositDate) <= calendar.startOfDay(for: now) else {
            throw BatchDepositError.depositDateInFuture
        }
        let accounts = try modelContext.fetch(FetchDescriptor<AccountRecord>())
        guard let undeposited = accounts.first(where: { $0.kind == .undepositedFunds && $0.isActive }) else {
            throw BatchDepositError.undepositedFundsAccountRequired
        }
        guard let destinationAccountID else { throw BatchDepositError.destinationAccountRequired }
        guard let destination = accounts.first(where: { $0.id == destinationAccountID && $0.isActive }),
              destination.id != undeposited.id,
              destination.kind != .cash,
              destination.kind != .undepositedFunds else {
            throw BatchDepositError.invalidDestinationAccount
        }
        guard !sourceTransactionIDs.isEmpty || !sourceCashReceiptIDs.isEmpty else {
            throw BatchDepositError.noReceiptsSelected
        }

        let transactions = try modelContext.fetch(FetchDescriptor<LedgerTransaction>())
        let receipts = try modelContext.fetch(FetchDescriptor<CashReceiptRecord>())
        let allocations = try modelContext.fetch(FetchDescriptor<DepositAllocationRecord>())
        let usedTransactions = Set(allocations.compactMap(\.sourceTransactionID))
        let usedReceipts = Set(allocations.compactMap(\.sourceCashReceiptID))
        guard sourceTransactionIDs.isDisjoint(with: usedTransactions), sourceCashReceiptIDs.isDisjoint(with: usedReceipts) else {
            throw BatchDepositError.receiptAlreadyDeposited
        }

        let selectedTransactions = transactions.filter { sourceTransactionIDs.contains($0.id) }
        let selectedReceipts = receipts.filter { sourceCashReceiptIDs.contains($0.id) }
        guard selectedTransactions.count == sourceTransactionIDs.count,
              selectedReceipts.count == sourceCashReceiptIDs.count,
              selectedTransactions.allSatisfy({
                  $0.accountID == undeposited.id && $0.direction == .income && !$0.isTransfer
              }) else {
            throw BatchDepositError.receiptNoLongerAvailable
        }
        guard selectedTransactions.allSatisfy({ $0.amountCents > 0 }),
              selectedReceipts.allSatisfy({ $0.amountCents > 0 }) else {
            throw BatchDepositError.invalidReceiptAmount
        }
        let depositDay = calendar.startOfDay(for: depositDate)
        guard selectedTransactions.allSatisfy({ calendar.startOfDay(for: $0.date) <= depositDay }),
              selectedReceipts.allSatisfy({ calendar.startOfDay(for: $0.date) <= depositDay }) else {
            throw BatchDepositError.receiptAfterDepositDate
        }

        for receipt in selectedReceipts {
            try validatePostingDate(
                accountID: undeposited.id,
                date: receipt.date,
                reconciliations: reconciliations,
                calendar: calendar,
                lockedError: BatchDepositError.importedReceiptDateLocked
            )
        }

        try validatePostingDate(
            accountID: undeposited.id,
            date: depositDate,
            reconciliations: reconciliations,
            calendar: calendar,
            lockedError: BatchDepositError.undepositedPeriodLocked
        )
        try validatePostingDate(
            accountID: destination.id,
            date: depositDate,
            reconciliations: reconciliations,
            calendar: calendar,
            lockedError: BatchDepositError.destinationPeriodLocked
        )

        let existingReceiptTotal = selectedTransactions.reduce(Int64(0)) { $0 + $1.amountCents }
        let importedReceiptTotal = selectedReceipts.reduce(Int64(0)) { $0 + $1.amountCents }
        let total = existingReceiptTotal + importedReceiptTotal
        guard total > 0 else { throw BatchDepositError.noReceiptsSelected }
        let projectedBalance = FinanceEngine.bookBalance(account: undeposited, transactions: transactions) + importedReceiptTotal - total
        guard projectedBalance >= 0 else { throw BatchDepositError.insufficientUndepositedFunds }

        let batch = DepositBatchRecord(
            undepositedFundsAccountID: undeposited.id,
            destinationAccountID: destination.id,
            depositDate: depositDate,
            totalCents: total
        )
        batch.reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        batch.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        modelContext.insert(batch)

        for transaction in selectedTransactions {
            let allocation = allocation(
                batchID: batch.id,
                transaction: transaction,
                paymentKind: "Ledger receipt"
            )
            modelContext.insert(allocation)
        }

        let peopleByNormalizedName = Dictionary(
            grouping: try modelContext.fetch(FetchDescriptor<PersonRecord>()),
            by: { normalized($0.displayName) }
        )
        for receipt in selectedReceipts {
            // A receipt is credited to a person only when exactly one roster record carries that name;
            // two families with the same name must not have money attributed to whichever sorts first.
            let matches = peopleByNormalizedName[normalized(receipt.personName)] ?? []
            let person = matches.count == 1 ? matches.first : nil
            let receiptTransaction = LedgerTransaction(
                accountID: undeposited.id,
                date: receipt.date,
                direction: .income,
                amountCents: receipt.amountCents,
                payee: receipt.personName,
                category: receipt.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Cash Receipt" : receipt.purpose
            )
            receiptTransaction.memo = "Imported cash receipt included in deposit batch \(batch.id.uuidString.lowercased())."
            receiptTransaction.personID = person?.id
            receiptTransaction.sourceSheet = receipt.sourceSheet
            receiptTransaction.sourceRow = receipt.sourceRow
            modelContext.insert(receiptTransaction)

            let allocation = allocation(
                batchID: batch.id,
                transaction: receiptTransaction,
                paymentKind: receipt.paymentKind.isEmpty ? "Imported cash receipt" : receipt.paymentKind
            )
            allocation.sourceCashReceiptID = receipt.id
            modelContext.insert(allocation)
        }

        let holdingTransfer = LedgerTransaction(
            accountID: undeposited.id,
            date: depositDate,
            direction: .expense,
            amountCents: total,
            payee: "Deposit to \(destination.name)",
            category: "Account Transfer"
        )
        holdingTransfer.memo = "Batch deposit \(batch.id.uuidString.lowercased())"
        holdingTransfer.isTransfer = true
        holdingTransfer.transferGroupID = batch.id
        holdingTransfer.depositBatchID = batch.id
        modelContext.insert(holdingTransfer)

        let bankTransfer = LedgerTransaction(
            accountID: destination.id,
            date: depositDate,
            direction: .income,
            amountCents: total,
            payee: "Deposit from Undeposited Funds",
            category: "Account Transfer"
        )
        bankTransfer.checkNumber = batch.reference
        bankTransfer.memo = "Batch deposit \(batch.id.uuidString.lowercased())"
        bankTransfer.isTransfer = true
        bankTransfer.transferGroupID = batch.id
        bankTransfer.depositBatchID = batch.id
        modelContext.insert(bankTransfer)

        batch.holdingTransactionID = holdingTransfer.id
        batch.bankTransactionID = bankTransfer.id
        AuditLogger.record(
            .create,
            recordType: "Deposit Batch",
            recordID: batch.id,
            summary: "Posted batch deposit to \(destination.name)",
            details: AuditLogger.details([
                ("Deposit date", depositDate.formatted(date: .numeric, time: .omitted)),
                ("Amount", Money.currency(cents: total)),
                ("Allocations", String(selectedTransactions.count + selectedReceipts.count)),
                ("Reference", batch.reference),
                ("Undeposited transaction", holdingTransfer.id.uuidString),
                ("Bank transaction", bankTransfer.id.uuidString),
            ]),
            in: modelContext
        )
        try modelContext.save()
        return batch
    }

    private static func allocation(
        batchID: UUID,
        transaction: LedgerTransaction,
        paymentKind: String
    ) -> DepositAllocationRecord {
        let allocation = DepositAllocationRecord(batchID: batchID, receivedAt: transaction.date, amountCents: transaction.amountCents)
        allocation.sourceTransactionID = transaction.id
        allocation.personID = transaction.personID
        allocation.eventID = transaction.eventID
        allocation.payerNameSnapshot = transaction.payee
        allocation.purposeSnapshot = transaction.category
        allocation.paymentKindSnapshot = paymentKind
        return allocation
    }

    private static func validatePostingDate(
        accountID: UUID,
        date: Date,
        reconciliations: [ReconciliationRecord],
        calendar: Calendar,
        lockedError: (Date) -> BatchDepositError
    ) throws {
        switch PeriodLocking.validatePosting(
            accountID: accountID,
            date: date,
            isAdjustment: false,
            adjustsTransactionID: nil,
            adjustmentReason: "",
            reconciliations: reconciliations,
            calendar: calendar
        ) {
        case .valid: break
        case .locked(let date): throw lockedError(date)
        default: throw BatchDepositError.invalidDestinationAccount
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

enum AccountTransferError: LocalizedError, Equatable {
    case sourceRequired
    case destinationRequired
    case sameAccount
    case inactiveAccount
    case invalidAmount
    case dateInFuture
    case sourceLocked(Date)
    case destinationLocked(Date)
    case undepositedFundsNotAllowed
    case wouldOverdraw(String)
    case notDeletable

    var errorDescription: String? {
        switch self {
        case .undepositedFundsNotAllowed: "Undeposited Funds only moves through deposit batches, which keep every receipt allocation. Use New Deposit instead of a transfer."
        case .wouldOverdraw(let message): message
        case .notDeletable: "This transfer is part of a deposit batch or a reconciled period and cannot be deleted."
        case .sourceRequired: "Choose the account the money leaves."
        case .destinationRequired: "Choose the account the money enters."
        case .sameAccount: "Choose two different accounts."
        case .inactiveAccount: "Both accounts must be active."
        case .invalidAmount: "Enter a transfer amount greater than zero."
        case .dateInFuture: "A transfer cannot be dated in the future."
        case .sourceLocked(let date): "The source account is locked through \(date.formatted(date: .long, time: .omitted)). Choose a later date."
        case .destinationLocked(let date): "The destination account is locked through \(date.formatted(date: .long, time: .omitted)). Choose a later date."
        }
    }
}

/// Moves money between two of the troop's own accounts (checking to savings, cash box to checking) as a
/// matched pair of transfer entries. Recording such a move as an ordinary expense plus income inflated both
/// sides of every income/expense report and budget variance.
@MainActor
enum AccountTransferService {
    @discardableResult
    static func post(
        fromAccountID: UUID?,
        toAccountID: UUID?,
        date: Date,
        amountCents: Int64,
        reference: String,
        memo: String,
        reconciliations: [ReconciliationRecord],
        calendar: Calendar = .current,
        now: Date = Date(),
        in modelContext: ModelContext
    ) throws -> (outgoing: LedgerTransaction, incoming: LedgerTransaction) {
        guard let fromAccountID else { throw AccountTransferError.sourceRequired }
        guard let toAccountID else { throw AccountTransferError.destinationRequired }
        guard fromAccountID != toAccountID else { throw AccountTransferError.sameAccount }
        guard amountCents > 0, Money.isWithinLimit(amountCents) else { throw AccountTransferError.invalidAmount }
        guard calendar.startOfDay(for: date) <= calendar.startOfDay(for: now) else { throw AccountTransferError.dateInFuture }
        let accounts = try modelContext.fetch(FetchDescriptor<AccountRecord>())
        guard let source = accounts.first(where: { $0.id == fromAccountID && $0.isActive }),
              let destination = accounts.first(where: { $0.id == toAccountID && $0.isActive }) else {
            throw AccountTransferError.inactiveAccount
        }
        guard source.kind != .undepositedFunds, destination.kind != .undepositedFunds else {
            throw AccountTransferError.undepositedFundsNotAllowed
        }
        // A cash box cannot send more than it holds.
        let existingTransactions = try modelContext.fetch(FetchDescriptor<LedgerTransaction>())
        do {
            try HoldingAccountPolicy.validate(account: source, transactions: existingTransactions, editing: nil, direction: .expense, amountCents: amountCents)
        } catch {
            throw AccountTransferError.wouldOverdraw(error.localizedDescription)
        }
        if let lock = PeriodLocking.latestLockDate(for: source.id, reconciliations: reconciliations, calendar: calendar),
           calendar.startOfDay(for: date) <= lock {
            throw AccountTransferError.sourceLocked(lock)
        }
        if let lock = PeriodLocking.latestLockDate(for: destination.id, reconciliations: reconciliations, calendar: calendar),
           calendar.startOfDay(for: date) <= lock {
            throw AccountTransferError.destinationLocked(lock)
        }

        let groupID = UUID()
        let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMemo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoing = LedgerTransaction(accountID: source.id, date: date, direction: .expense, amountCents: amountCents, payee: "Transfer to \(destination.name)", category: "Account Transfer")
        let incoming = LedgerTransaction(accountID: destination.id, date: date, direction: .income, amountCents: amountCents, payee: "Transfer from \(source.name)", category: "Account Transfer")
        for transaction in [outgoing, incoming] {
            transaction.isTransfer = true
            transaction.transferGroupID = groupID
            transaction.checkNumber = trimmedReference
            transaction.memo = trimmedMemo
            modelContext.insert(transaction)
        }
        AuditLogger.record(
            .create,
            recordType: "Account Transfer",
            recordID: groupID,
            summary: "Transferred \(Money.currency(cents: amountCents)) from \(source.name) to \(destination.name)",
            details: AuditLogger.details([
                ("Date", date.formatted(date: .numeric, time: .omitted)),
                ("Reference", trimmedReference),
                ("Memo", trimmedMemo),
                ("Outgoing transaction", outgoing.id.uuidString),
                ("Incoming transaction", incoming.id.uuidString),
            ]),
            in: modelContext
        )
        try modelContext.save()
        return (outgoing, incoming)
    }

    /// Removes both sides of a manual transfer entered by mistake. Deposit-batch legs and legs in a
    /// reconciled period stay protected.
    static func delete(transferGroupID: UUID, reconciliations: [ReconciliationRecord], calendar: Calendar = .current, in modelContext: ModelContext) throws {
        let transactions = try modelContext.fetch(FetchDescriptor<LedgerTransaction>())
        let legs = transactions.filter { $0.transferGroupID == transferGroupID && $0.isTransfer }
        let reimbursements = try modelContext.fetch(FetchDescriptor<ReimbursementRequest>())
        let memberEntries = try modelContext.fetch(FetchDescriptor<MemberLedgerEntry>())
        let allocations = try modelContext.fetch(FetchDescriptor<DepositAllocationRecord>())
        let batches = try modelContext.fetch(FetchDescriptor<DepositBatchRecord>())
        guard !legs.isEmpty,
              legs.allSatisfy({ leg in
                  leg.depositBatchID == nil
                      && !PeriodLocking.isLocked(leg, reconciliations: reconciliations, calendar: calendar)
                      && RecordDeletionPolicy.canDeleteTransaction(leg.id, transactions: transactions, depositAllocations: allocations, depositBatches: batches, reimbursements: reimbursements, memberEntries: memberEntries)
              }) else {
            throw AccountTransferError.notDeletable
        }
        let accounts = try modelContext.fetch(FetchDescriptor<AccountRecord>())
        let description = legs.map { leg in
            "\(accounts.first { $0.id == leg.accountID }?.name ?? "Unknown account") \(Money.currency(cents: leg.signedAmountCents))"
        }.joined(separator: "; ")
        AuditLogger.record(
            .delete,
            recordType: "Account Transfer",
            recordID: transferGroupID,
            summary: "Deleted transfer \(Money.currency(cents: legs.first?.amountCents ?? 0)) between troop accounts",
            details: AuditLogger.details([("Date", legs.first?.date.formatted(date: .numeric, time: .omitted)), ("Legs", description), ("Memo", legs.first?.memo)]),
            in: modelContext
        )
        legs.forEach { modelContext.delete($0) }
        try modelContext.save()
    }
}
