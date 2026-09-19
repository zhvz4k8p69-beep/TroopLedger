import Foundation
import SwiftData

/// Removes the complete single-troop database while preserving the app itself and its local UI preferences.
///
/// TroopLedger uses UUID references instead of SwiftData relationships, so every model can be deleted in one
/// save without leaving required relationship objects behind. Object-by-object deletion is intentional: it lets
/// SwiftData publish the deletions to the private CloudKit store used by the treasurer's other devices.
@MainActor
enum DataResetService {
    struct Result: Equatable {
        let deletedRecordCount: Int
    }

    static let supportedModelTypeNames: Set<String> = [
        FundraiserRecord.self,
        FundraiserProductRecord.self,
        FundraiserActivityRecord.self,
        TroopProfileRecord.self,
        AccountRecord.self,
        LedgerCategoryRecord.self,
        OperatingBudgetRecord.self,
        BudgetLineRecord.self,
        LedgerTransaction.self,
        DepositBatchRecord.self,
        DepositAllocationRecord.self,
        ReimbursementRequest.self,
        DisbursementControlSettings.self,
        ReimbursementAttachment.self,
        FamilyRecord.self,
        RecurringChargeBatchRecord.self,
        RecurringChargeAllocationRecord.self,
        PersonRecord.self,
        MemberLedgerEntry.self,
        RegistrationRecord.self,
        EventRecord.self,
        EventFeeScheduleRecord.self,
        EventParticipant.self,
        EventCloseoutRecord.self,
        EventCloseoutAllocationRecord.self,
        EventFinancialEntry.self,
        CashReceiptRecord.self,
        ReconciliationRecord.self,
        ImportRecord.self,
        GeneralSpreadsheetImportRecord.self,
        ScoutbookImportRecord.self,
        ExternalCalendarSubscription.self,
        AuditLogEntry.self,
    ].map { String(reflecting: $0) }.reduce(into: Set<String>()) { $0.insert($1) }

    static func deleteAllRecords(from modelContext: ModelContext) throws -> Result {
        if modelContext.hasChanges {
            try modelContext.save()
        }

        do {
            var deletedRecordCount = 0

            deletedRecordCount += try deleteAll(FundraiserRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(FundraiserProductRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(FundraiserActivityRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(TroopProfileRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(AccountRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(LedgerCategoryRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(OperatingBudgetRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(BudgetLineRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(LedgerTransaction.self, from: modelContext)
            deletedRecordCount += try deleteAll(DepositBatchRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(DepositAllocationRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(ReimbursementRequest.self, from: modelContext)
            deletedRecordCount += try deleteAll(DisbursementControlSettings.self, from: modelContext)
            deletedRecordCount += try deleteAll(ReimbursementAttachment.self, from: modelContext)
            deletedRecordCount += try deleteAll(FamilyRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(RecurringChargeBatchRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(RecurringChargeAllocationRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(PersonRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(MemberLedgerEntry.self, from: modelContext)
            deletedRecordCount += try deleteAll(RegistrationRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(EventRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(EventFeeScheduleRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(EventParticipant.self, from: modelContext)
            deletedRecordCount += try deleteAll(EventCloseoutRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(EventCloseoutAllocationRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(EventFinancialEntry.self, from: modelContext)
            deletedRecordCount += try deleteAll(CashReceiptRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(ReconciliationRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(ImportRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(GeneralSpreadsheetImportRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(ScoutbookImportRecord.self, from: modelContext)
            deletedRecordCount += try deleteAll(ExternalCalendarSubscription.self, from: modelContext)
            deletedRecordCount += try deleteAll(AuditLogEntry.self, from: modelContext)

            // The old log is gone by design, but the new one must not begin silently: the first entry records
            // that a reset happened, when, on which device, and how much it removed.
            AuditLogger.record(
                .delete,
                recordType: "Database",
                recordID: nil,
                summary: "Deleted all records and started over",
                details: AuditLogger.details([("Records deleted", String(deletedRecordCount))]),
                in: modelContext
            )
            try modelContext.save()
            // The troop profile is gone; the iOS actor fallback must stop naming its treasurer on every
            // entry written after the reset until the app is relaunched or the profile is edited.
            AuditLogger.invalidateTreasurerIdentity()
            return Result(deletedRecordCount: deletedRecordCount)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private static func deleteAll<Model: PersistentModel>(
        _ type: Model.Type,
        from modelContext: ModelContext
    ) throws -> Int {
        let records = try modelContext.fetch(FetchDescriptor<Model>())
        for record in records {
            modelContext.delete(record)
        }
        return records.count
    }
}

struct DataIntegrityIssue: Identifiable, Equatable {
    enum Severity: String { case problem = "Problem", warning = "Warning" }
    let severity: Severity
    let area: String
    let message: String
    var id: String { "\(area)|\(message)" }
}

/// Because records link by UUID rather than SwiftData relationships, a CloudKit merge, an interrupted save,
/// or an older app version can leave dangling links that no screen surfaces. This walk finds them.
@MainActor
enum DataIntegrityService {
    static func check(in context: ModelContext) throws -> [DataIntegrityIssue] {
        let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())
        let people = try context.fetch(FetchDescriptor<PersonRecord>())
        let events = try context.fetch(FetchDescriptor<EventRecord>())
        let requests = try context.fetch(FetchDescriptor<ReimbursementRequest>())
        let entries = try context.fetch(FetchDescriptor<MemberLedgerEntry>())
        let batches = try context.fetch(FetchDescriptor<DepositBatchRecord>())
        let allocations = try context.fetch(FetchDescriptor<DepositAllocationRecord>())
        let participants = try context.fetch(FetchDescriptor<EventParticipant>())
        let registrations = try context.fetch(FetchDescriptor<RegistrationRecord>())
        let closeouts = try context.fetch(FetchDescriptor<EventCloseoutRecord>())
        let fundraisers = try context.fetch(FetchDescriptor<FundraiserRecord>())
        let products = try context.fetch(FetchDescriptor<FundraiserProductRecord>())
        let activities = try context.fetch(FetchDescriptor<FundraiserActivityRecord>())
        var fundraiserIssues: [DataIntegrityIssue] = []
        let fundraiserIDs = Set(fundraisers.map(\.id))
        let personIDs = Set(people.map(\.id))
        for product in products {
            if !fundraiserIDs.contains(product.fundraiserID ?? UUID()) {
                fundraiserIssues.append(.init(severity: .problem, area: "Fundraisers", message: "\(product.name) has no fundraiser."))
            }
            do { try FundraiserService.validate(activities.filter { $0.productID == product.id }) }
            catch { fundraiserIssues.append(.init(severity: .problem, area: "Fundraisers", message: "\(product.name): \(error.localizedDescription)")) }
        }
        for row in activities {
            if !products.contains(where: { $0.id == row.productID && $0.fundraiserID == row.fundraiserID }) {
                fundraiserIssues.append(.init(severity: .problem, area: "Fundraisers", message: "\(row.kindRaw) for \(row.sellerName) has a missing or mismatched product."))
            }
            if let personID = row.personID, !personIDs.contains(personID) {
                fundraiserIssues.append(.init(severity: .warning, area: "Fundraisers", message: "\(row.sellerName) has fundraiser history but no People record."))
            }
        }
        return check(accounts: accounts, transactions: transactions, people: people, events: events, requests: requests, entries: entries, batches: batches, allocations: allocations, participants: participants, registrations: registrations, closeouts: closeouts) + fundraiserIssues
    }

    nonisolated static func check(
        accounts: [AccountRecord],
        transactions: [LedgerTransaction],
        people: [PersonRecord],
        events: [EventRecord],
        requests: [ReimbursementRequest],
        entries: [MemberLedgerEntry],
        batches: [DepositBatchRecord],
        allocations: [DepositAllocationRecord],
        participants: [EventParticipant],
        registrations: [RegistrationRecord],
        closeouts: [EventCloseoutRecord]
    ) -> [DataIntegrityIssue] {
        var issues: [DataIntegrityIssue] = []
        let accountIDs = Set(accounts.map(\.id))
        let transactionIDs = Set(transactions.map(\.id))
        let personIDs = Set(people.map(\.id))
        let eventIDs = Set(events.map(\.id))
        let batchIDs = Set(batches.map(\.id))

        let holding = accounts.filter { $0.kind == .undepositedFunds }
        if holding.count > 1 {
            issues.append(.init(severity: .problem, area: "Accounts", message: "\(holding.count) Undeposited Funds accounts exist; deposits expect exactly one. Merge or archive the extras."))
        }
        for transaction in transactions {
            if let accountID = transaction.accountID, !accountIDs.contains(accountID) {
                issues.append(.init(severity: .problem, area: "Transactions", message: "\(describe(transaction)) belongs to an account that no longer exists."))
            }
            if let personID = transaction.personID, !personIDs.contains(personID) {
                issues.append(.init(severity: .warning, area: "Transactions", message: "\(describe(transaction)) is linked to a person that no longer exists."))
            }
            if let eventID = transaction.eventID, !eventIDs.contains(eventID) {
                issues.append(.init(severity: .warning, area: "Transactions", message: "\(describe(transaction)) is linked to an event that no longer exists."))
            }
        }
        let transferGroups = Dictionary(grouping: transactions.filter { $0.isTransfer && $0.transferGroupID != nil }, by: { $0.transferGroupID! })
        for (_, legs) in transferGroups {
            if legs.count != 2 {
                issues.append(.init(severity: .problem, area: "Transfers", message: "Transfer \(legs.map(describe).joined(separator: " / ")) has \(legs.count) side\(legs.count == 1 ? "" : "s") instead of two."))
            } else if legs[0].amountCents != legs[1].amountCents || legs[0].direction == legs[1].direction {
                issues.append(.init(severity: .problem, area: "Transfers", message: "Transfer \(legs.map(describe).joined(separator: " / ")) does not balance."))
            }
        }
        for request in requests {
            if let linked = request.linkedTransactionID, !transactionIDs.contains(linked) {
                issues.append(.init(severity: .problem, area: "Reimbursements", message: "\(request.purpose) (\(Money.currency(cents: request.amountCents))) points to a payment transaction that no longer exists."))
            }
            if request.status == .paid, request.linkedTransactionID == nil {
                issues.append(.init(severity: .problem, area: "Reimbursements", message: "\(request.purpose) is marked paid without a linked payment."))
            }
            if let requester = request.requesterPersonID, !personIDs.contains(requester) {
                issues.append(.init(severity: .warning, area: "Reimbursements", message: "\(request.purpose) names a requester that no longer exists."))
            }
        }
        for entry in entries {
            if let personID = entry.personID, !personIDs.contains(personID) {
                issues.append(.init(severity: .problem, area: "Member ledger", message: "A \(entry.kind.rawValue.lowercased()) of \(Money.currency(cents: entry.amountCents)) dated \(entry.date.formatted(date: .numeric, time: .omitted)) belongs to a person that no longer exists."))
            }
            if let linked = entry.accountTransactionID, !transactionIDs.contains(linked) {
                issues.append(.init(severity: .warning, area: "Member ledger", message: "A payment of \(Money.currency(cents: entry.amountCents)) dated \(entry.date.formatted(date: .numeric, time: .omitted)) points to a bank receipt that no longer exists."))
            }
        }
        // Grouped once; per-record filters over the full tables made this check quadratic in a large database.
        let allocationsByBatch = Dictionary(grouping: allocations, by: \.batchID)
        let participantsByEvent = Dictionary(grouping: participants, by: \.eventID)
        let eventIncomeByEvent = Dictionary(grouping: transactions.filter { $0.direction == .income && !$0.isTransfer }, by: \.eventID)
        let closedOutEventIDs = Set(closeouts.compactMap(\.eventID))
        for batch in batches {
            for (label, id) in [("holding", batch.holdingTransactionID), ("bank", batch.bankTransactionID)] where id.map({ !transactionIDs.contains($0) }) ?? true {
                issues.append(.init(severity: .problem, area: "Deposits", message: "Deposit of \(Money.currency(cents: batch.totalCents)) on \(batch.depositDate.formatted(date: .numeric, time: .omitted)) is missing its \(label) transfer entry."))
            }
            let allocated = (allocationsByBatch[batch.id] ?? []).reduce(Int64(0)) { $0 + $1.amountCents }
            if allocated != batch.totalCents {
                issues.append(.init(severity: .problem, area: "Deposits", message: "Deposit of \(Money.currency(cents: batch.totalCents)) on \(batch.depositDate.formatted(date: .numeric, time: .omitted)) has allocations totaling \(Money.currency(cents: allocated))."))
            }
        }
        for allocation in allocations where allocation.batchID.map({ !batchIDs.contains($0) }) ?? true {
            issues.append(.init(severity: .warning, area: "Deposits", message: "An allocation of \(Money.currency(cents: allocation.amountCents)) for \(allocation.payerNameSnapshot) belongs to no deposit batch."))
        }
        for participant in participants {
            if let eventID = participant.eventID, !eventIDs.contains(eventID) {
                issues.append(.init(severity: .warning, area: "Events", message: "A roster row (paid \(Money.currency(cents: participant.paidCents))) belongs to an event that no longer exists."))
            }
            if let personID = participant.personID, !personIDs.contains(personID) {
                issues.append(.init(severity: .warning, area: "Events", message: "A roster row belongs to a person that no longer exists."))
            }
        }
        for registration in registrations where registration.personID.map({ !personIDs.contains($0) }) ?? true {
            issues.append(.init(severity: .warning, area: "People", message: "A \(registration.programYear) registration belongs to a person that no longer exists."))
        }
        for event in events where event.closedAt != nil && !closedOutEventIDs.contains(event.id) {
            issues.append(.init(severity: .problem, area: "Events", message: "\(event.name) is marked closed but has no close-out record."))
        }
        // Cash traceability: member payments that no bank receipt backs, and rosters that record more money
        // collected than the register shows for the event.
        let unlinkedPayments = entries.filter { $0.kind == .payment && $0.accountTransactionID == nil }
        if !unlinkedPayments.isEmpty {
            let total = unlinkedPayments.reduce(Int64(0)) { $0 + $1.amountCents }
            issues.append(.init(severity: .warning, area: "Cash traceability", message: "\(unlinkedPayments.count) member payment\(unlinkedPayments.count == 1 ? "" : "s") totaling \(Money.currency(cents: total)) \(unlinkedPayments.count == 1 ? "is" : "are") not linked to a bank receipt."))
        }
        for event in events {
            let rosterPaid = (participantsByEvent[event.id] ?? []).reduce(Int64(0)) { $0 + $1.paidCents }
            guard rosterPaid > 0 else { continue }
            let linkedIncome = (eventIncomeByEvent[event.id] ?? []).reduce(Int64(0)) { $0 + $1.amountCents }
            if rosterPaid > linkedIncome {
                issues.append(.init(severity: .warning, area: "Cash traceability", message: "\(event.name): roster payments total \(Money.currency(cents: rosterPaid)) but only \(Money.currency(cents: linkedIncome)) of income is linked to the event."))
            }
        }
        let duplicateIDs = Dictionary(grouping: people.filter { !$0.scoutingMemberID.trimmingCharacters(in: .whitespaces).isEmpty }, by: { $0.scoutingMemberID.trimmingCharacters(in: .whitespaces) })
            .filter { $0.value.count > 1 }
        for (memberID, matches) in duplicateIDs {
            issues.append(.init(severity: .warning, area: "People", message: "Scouting Member ID \(memberID) is shared by \(matches.map(\.displayName).sorted().joined(separator: ", "))."))
        }
        return issues.sorted { ($0.severity == .problem ? 0 : 1, $0.area, $0.message) < ($1.severity == .problem ? 0 : 1, $1.area, $1.message) }
    }

    nonisolated private static func describe(_ transaction: LedgerTransaction) -> String {
        "\(transaction.payee.isEmpty ? transaction.category : transaction.payee) \(Money.currency(cents: transaction.signedAmountCents)) on \(transaction.date.formatted(date: .numeric, time: .omitted))"
    }
}

/// Centralizes UUID-reference checks for destructive list actions. TroopLedger intentionally uses UUID links
/// instead of SwiftData relationships, so deletion must explicitly protect every referencing record type.
enum RecordDeletionPolicy {
    static func canDeleteAccount(
        _ accountID: UUID,
        transactions: [LedgerTransaction],
        reconciliations: [ReconciliationRecord],
        depositBatches: [DepositBatchRecord],
        spreadsheetImports: [GeneralSpreadsheetImportRecord]
    ) -> Bool {
        !transactions.contains { $0.accountID == accountID }
            && !reconciliations.contains { $0.accountID == accountID }
            && !depositBatches.contains {
                $0.undepositedFundsAccountID == accountID || $0.destinationAccountID == accountID
            }
            && !spreadsheetImports.contains { $0.accountID == accountID }
    }

    static func canDeletePerson(
        _ personID: UUID,
        transactions: [LedgerTransaction],
        depositAllocations: [DepositAllocationRecord],
        reimbursements: [ReimbursementRequest],
        recurringAllocations: [RecurringChargeAllocationRecord],
        memberEntries: [MemberLedgerEntry],
        registrations: [RegistrationRecord],
        participants: [EventParticipant],
        closeoutAllocations: [EventCloseoutAllocationRecord]
    ) -> Bool {
        !transactions.contains { $0.personID == personID }
            && !depositAllocations.contains { $0.personID == personID }
            && !reimbursements.contains {
                $0.requesterPersonID == personID
                    || $0.approverPersonID == personID
                    || $0.signerOnePersonID == personID
                    || $0.signerTwoPersonID == personID
            }
            && !recurringAllocations.contains { $0.personID == personID }
            && !memberEntries.contains { $0.personID == personID }
            && !registrations.contains { $0.personID == personID }
            && !participants.contains { $0.personID == personID }
            && !closeoutAllocations.contains { $0.personID == personID }
    }

    static func canDeleteEvent(
        _ eventID: UUID,
        transactions: [LedgerTransaction],
        depositAllocations: [DepositAllocationRecord],
        reimbursements: [ReimbursementRequest],
        memberEntries: [MemberLedgerEntry],
        feeSchedules: [EventFeeScheduleRecord],
        participants: [EventParticipant],
        closeouts: [EventCloseoutRecord],
        closeoutAllocations: [EventCloseoutAllocationRecord],
        financialEntries: [EventFinancialEntry]
    ) -> Bool {
        !transactions.contains { $0.eventID == eventID }
            && !depositAllocations.contains { $0.eventID == eventID }
            && !reimbursements.contains { $0.eventID == eventID }
            && !memberEntries.contains { $0.eventID == eventID }
            && !feeSchedules.contains { $0.eventID == eventID }
            && !participants.contains { $0.eventID == eventID }
            && !closeouts.contains { $0.eventID == eventID }
            && !closeoutAllocations.contains { $0.eventID == eventID }
            && !financialEntries.contains { $0.eventID == eventID }
    }

    static func canDeleteTransaction(
        _ transactionID: UUID,
        transactions: [LedgerTransaction],
        depositAllocations: [DepositAllocationRecord],
        depositBatches: [DepositBatchRecord],
        reimbursements: [ReimbursementRequest],
        memberEntries: [MemberLedgerEntry]
    ) -> Bool {
        !transactions.contains { $0.adjustsTransactionID == transactionID }
            && !depositAllocations.contains { $0.sourceTransactionID == transactionID }
            && !depositBatches.contains {
                $0.holdingTransactionID == transactionID || $0.bankTransactionID == transactionID
            }
            && !reimbursements.contains { $0.linkedTransactionID == transactionID }
            && !memberEntries.contains { $0.accountTransactionID == transactionID }
    }
}
