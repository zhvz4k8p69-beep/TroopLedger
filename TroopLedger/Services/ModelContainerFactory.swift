import SwiftData

enum ModelContainerFactory {
    static let modelTypes: [any PersistentModel.Type] = [
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
    ]

    static func makeCloudContainer() -> ModelContainer {
        let schema = Schema(modelTypes)
        let configuration = ModelConfiguration(
            "TroopLedger",
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Unable to initialize TroopLedger storage: \(error)")
        }
    }

    static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(modelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
