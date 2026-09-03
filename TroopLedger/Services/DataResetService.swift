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

            try modelContext.save()
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
