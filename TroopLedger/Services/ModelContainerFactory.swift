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

    /// Opens the on-disk store. A failure (corrupt store, migration error, full disk) used to `fatalError`,
    /// which put the app into a crash loop with no explanation; callers now receive the error and can show it.
    static func openCloudContainer() -> Result<ModelContainer, Error> {
        let schema = Schema(modelTypes)
        let configuration = ModelConfiguration(
            "TroopLedger",
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )
        return Result { try ModelContainer(for: schema, configurations: configuration) }
    }

    static func makeCloudContainer() -> ModelContainer {
        switch openCloudContainer() {
        case .success(let container): return container
        case .failure(let error): fatalError("Unable to initialize TroopLedger storage: \(error)")
        }
    }

    static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(modelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
