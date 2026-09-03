import CryptoKit
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let troopLedgerBackup = UTType(
        exportedAs: "com.bettnet.troopledger.backup",
        conformingTo: .package
    )
}

struct PlaintextBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.troopLedgerBackup] }

    let files: [String: Data]

    init(files: [String: Data]) {
        self.files = files
    }

    init(configuration: ReadConfiguration) throws {
        guard configuration.file.isDirectory else {
            throw CocoaError(.fileReadCorruptFile)
        }
        files = Self.flattenedFiles(in: configuration.file)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        makeFileWrapper()
    }

    func makeFileWrapper() -> FileWrapper {
        let root = FileWrapper(directoryWithFileWrappers: [:])
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            Self.addFile(data, components: path.split(separator: "/").map(String.init), to: root)
        }
        return root
    }

    private static func addFile(_ data: Data, components: [String], to directory: FileWrapper) {
        // Never let a stored name become a relative path component that escapes the package.
        let components = components.filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard let name = components.first else { return }
        if components.count == 1 {
            let file = FileWrapper(regularFileWithContents: data)
            file.preferredFilename = name
            directory.addFileWrapper(file)
            return
        }
        let child = directory.fileWrappers?.values.first { $0.isDirectory && $0.preferredFilename == name }
            ?? {
                let wrapper = FileWrapper(directoryWithFileWrappers: [:])
                wrapper.preferredFilename = name
                directory.addFileWrapper(wrapper)
                return wrapper
            }()
        addFile(data, components: Array(components.dropFirst()), to: child)
    }

    private static func flattenedFiles(in directory: FileWrapper, prefix: String = "") -> [String: Data] {
        guard let wrappers = directory.fileWrappers else { return [:] }
        return wrappers.reduce(into: [:]) { result, item in
            let name = item.value.preferredFilename ?? item.key
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if item.value.isDirectory {
                result.merge(flattenedFiles(in: item.value, prefix: path)) { _, new in new }
            } else if let data = item.value.regularFileContents {
                result[path] = data
            }
        }
    }
}

struct PlaintextBackupArchive {
    let files: [String: Data]
    let recordCounts: [String: Int]
}

@MainActor
enum PlaintextBackupService {
    static let formatVersion = 11

    static func defaultFilename(at date: Date = Date(), calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        return "TroopLedger Backup \(day).troopledgerbackup"
    }

    static func makeArchive(
        from modelContext: ModelContext,
        exportedAt: Date = Date(),
        applicationVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    ) throws -> PlaintextBackupArchive {
        let tables = try makeTables(from: modelContext)
        let generatedAt = backupISO8601String(from: exportedAt)
        let document = BackupJSONDocument(
            format: "TroopLedger plaintext backup",
            formatVersion: formatVersion,
            applicationVersion: applicationVersion,
            generatedAt: generatedAt,
            tables: tables
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var files = tables.reduce(into: [String: Data]()) { result, table in
            result["\(table.name).csv"] = Data(csv(for: table).utf8)
        }
        let attachments = try modelContext.fetch(FetchDescriptor<ReimbursementAttachment>())
        for attachment in attachments {
            files[attachmentRelativePath(attachment)] = attachment.data
        }
        files["backup.json"] = try encoder.encode(document)
        files["README.txt"] = Data(readme(generatedAt: generatedAt, applicationVersion: applicationVersion).utf8)

        return PlaintextBackupArchive(
            files: files,
            recordCounts: Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0.rows.count) })
        )
    }

    private static func makeTables(from context: ModelContext) throws -> [BackupTable] {
        let troopProfiles = try context.fetch(FetchDescriptor<TroopProfileRecord>()).sortedByID()
        let accounts = try context.fetch(FetchDescriptor<AccountRecord>()).sortedByID()
        let categories = try context.fetch(FetchDescriptor<LedgerCategoryRecord>()).sortedByID()
        let budgets = try context.fetch(FetchDescriptor<OperatingBudgetRecord>()).sortedByID()
        let budgetLines = try context.fetch(FetchDescriptor<BudgetLineRecord>()).sortedByID()
        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>()).sortedByID()
        let depositBatches = try context.fetch(FetchDescriptor<DepositBatchRecord>()).sortedByID()
        let depositAllocations = try context.fetch(FetchDescriptor<DepositAllocationRecord>()).sortedByID()
        let reimbursementRequests = try context.fetch(FetchDescriptor<ReimbursementRequest>()).sortedByID()
        let disbursementSettings = try context.fetch(FetchDescriptor<DisbursementControlSettings>()).sortedByID()
        let reimbursementAttachments = try context.fetch(FetchDescriptor<ReimbursementAttachment>()).sortedByID()
        let families = try context.fetch(FetchDescriptor<FamilyRecord>()).sortedByID()
        let recurringChargeBatches = try context.fetch(FetchDescriptor<RecurringChargeBatchRecord>()).sortedByID()
        let recurringChargeAllocations = try context.fetch(FetchDescriptor<RecurringChargeAllocationRecord>()).sortedByID()
        let people = try context.fetch(FetchDescriptor<PersonRecord>()).sortedByID()
        let memberEntries = try context.fetch(FetchDescriptor<MemberLedgerEntry>()).sortedByID()
        let registrations = try context.fetch(FetchDescriptor<RegistrationRecord>()).sortedByID()
        let events = try context.fetch(FetchDescriptor<EventRecord>()).sortedByID()
        let eventFeeSchedules = try context.fetch(FetchDescriptor<EventFeeScheduleRecord>()).sortedByID()
        let participants = try context.fetch(FetchDescriptor<EventParticipant>()).sortedByID()
        let eventCloseouts = try context.fetch(FetchDescriptor<EventCloseoutRecord>()).sortedByID()
        let eventCloseoutAllocations = try context.fetch(FetchDescriptor<EventCloseoutAllocationRecord>()).sortedByID()
        let eventFinancialEntries = try context.fetch(FetchDescriptor<EventFinancialEntry>()).sortedByID()
        let cashReceipts = try context.fetch(FetchDescriptor<CashReceiptRecord>()).sortedByID()
        let reconciliations = try context.fetch(FetchDescriptor<ReconciliationRecord>()).sortedByID()
        let imports = try context.fetch(FetchDescriptor<ImportRecord>()).sortedByID()
        let generalSpreadsheetImports = try context.fetch(FetchDescriptor<GeneralSpreadsheetImportRecord>()).sortedByID()
        let scoutbookImports = try context.fetch(FetchDescriptor<ScoutbookImportRecord>()).sortedByID()
        let subscriptions = try context.fetch(FetchDescriptor<ExternalCalendarSubscription>()).sortedByID()
        let auditEntries = try context.fetch(FetchDescriptor<AuditLogEntry>()).sortedByID()

        return [
            BackupTable("troop_profile", columns: ["id", "troop_name", "troop_number", "council", "district", "chartered_organization", "address_line_1", "address_line_2", "city", "state_or_province", "postal_code", "country", "unit_email", "unit_phone", "website", "treasurer_name", "treasurer_preferred_name", "treasurer_title", "treasurer_email", "treasurer_phone", "committee_chair_name", "notes", "created_at", "modified_at"], rows: troopProfiles.map { profile in
                [.uuid("id", profile.id), .string("troop_name", profile.troopName), .string("troop_number", profile.troopNumber), .string("council", profile.council), .string("district", profile.district), .string("chartered_organization", profile.charteredOrganization), .string("address_line_1", profile.addressLine1), .string("address_line_2", profile.addressLine2), .string("city", profile.city), .string("state_or_province", profile.stateOrProvince), .string("postal_code", profile.postalCode), .string("country", profile.country), .string("unit_email", profile.unitEmail), .string("unit_phone", profile.unitPhone), .string("website", profile.website), .string("treasurer_name", profile.treasurerName), .string("treasurer_preferred_name", profile.treasurerPreferredName), .string("treasurer_title", profile.treasurerTitle), .string("treasurer_email", profile.treasurerEmail), .string("treasurer_phone", profile.treasurerPhone), .string("committee_chair_name", profile.committeeChairName), .string("notes", profile.notes), .date("created_at", profile.createdAt), .date("modified_at", profile.modifiedAt)]
            }),
            BackupTable("accounts", columns: ["id", "name", "institution", "kind", "opening_balance_cents", "is_active", "notes", "created_at"], rows: accounts.map { account in
                [.uuid("id", account.id), .string("name", account.name), .string("institution", account.institution), .string("kind", account.kindRaw), .integer("opening_balance_cents", account.openingBalanceCents), .boolean("is_active", account.isActive), .string("notes", account.notes), .date("created_at", account.createdAt)]
            }),
            BackupTable("ledger_categories", columns: ["id", "name", "direction", "is_active", "is_standard", "sort_order", "notes", "created_at", "modified_at"], rows: categories.map { category in
                [.uuid("id", category.id), .string("name", category.name), .string("direction", category.directionRaw), .boolean("is_active", category.isActive), .boolean("is_standard", category.isStandard), .integer("sort_order", Int64(category.sortOrder)), .string("notes", category.notes), .date("created_at", category.createdAt), .date("modified_at", category.modifiedAt)]
            }),
            BackupTable("operating_budgets", columns: ["id", "reporting_year_start", "status", "revision", "notes", "created_at", "modified_at", "approved_at"], rows: budgets.map { budget in
                [.uuid("id", budget.id), .integer("reporting_year_start", Int64(budget.reportingYearStart)), .string("status", budget.statusRaw), .integer("revision", Int64(budget.revision)), .string("notes", budget.notes), .date("created_at", budget.createdAt), .date("modified_at", budget.modifiedAt), .optionalDate("approved_at", budget.approvedAt)]
            }),
            BackupTable("budget_lines", columns: ["id", "budget_id", "category_id", "category_name", "direction", "amount_cents", "created_at", "modified_at"], rows: budgetLines.map { line in
                [.uuid("id", line.id), .optionalUUID("budget_id", line.budgetID), .optionalUUID("category_id", line.categoryID), .string("category_name", line.categoryName), .string("direction", line.directionRaw), .integer("amount_cents", line.amountCents), .date("created_at", line.createdAt), .date("modified_at", line.modifiedAt)]
            }),
            BackupTable("transactions", columns: ["id", "account_id", "date", "direction", "amount_cents", "check_number", "payee", "category", "memo", "person_id", "event_id", "is_cleared", "reconciled_at", "reconciliation_id", "is_adjustment", "adjusts_transaction_id", "adjustment_reason", "is_transfer", "transfer_group_id", "deposit_batch_id", "created_at", "modified_at", "source_sheet", "source_row"], rows: transactions.map { transaction in
                [.uuid("id", transaction.id), .optionalUUID("account_id", transaction.accountID), .date("date", transaction.date), .string("direction", transaction.directionRaw), .integer("amount_cents", transaction.amountCents), .string("check_number", transaction.checkNumber), .string("payee", transaction.payee), .string("category", transaction.category), .string("memo", transaction.memo), .optionalUUID("person_id", transaction.personID), .optionalUUID("event_id", transaction.eventID), .boolean("is_cleared", transaction.isCleared), .optionalDate("reconciled_at", transaction.reconciledAt), .optionalUUID("reconciliation_id", transaction.reconciliationID), .boolean("is_adjustment", transaction.isAdjustment), .optionalUUID("adjusts_transaction_id", transaction.adjustsTransactionID), .string("adjustment_reason", transaction.adjustmentReason), .boolean("is_transfer", transaction.isTransfer), .optionalUUID("transfer_group_id", transaction.transferGroupID), .optionalUUID("deposit_batch_id", transaction.depositBatchID), .date("created_at", transaction.createdAt), .date("modified_at", transaction.modifiedAt), .string("source_sheet", transaction.sourceSheet), .integer("source_row", Int64(transaction.sourceRow))]
            }),
            BackupTable("deposit_batches", columns: ["id", "undeposited_funds_account_id", "destination_account_id", "deposit_date", "total_cents", "reference", "notes", "holding_transaction_id", "bank_transaction_id", "created_at", "posted_at"], rows: depositBatches.map { batch in
                [.uuid("id", batch.id), .optionalUUID("undeposited_funds_account_id", batch.undepositedFundsAccountID), .optionalUUID("destination_account_id", batch.destinationAccountID), .date("deposit_date", batch.depositDate), .integer("total_cents", batch.totalCents), .string("reference", batch.reference), .string("notes", batch.notes), .optionalUUID("holding_transaction_id", batch.holdingTransactionID), .optionalUUID("bank_transaction_id", batch.bankTransactionID), .date("created_at", batch.createdAt), .date("posted_at", batch.postedAt)]
            }),
            BackupTable("deposit_allocations", columns: ["id", "batch_id", "source_transaction_id", "source_cash_receipt_id", "person_id", "event_id", "payer_name_snapshot", "purpose_snapshot", "payment_kind_snapshot", "received_at", "amount_cents", "created_at"], rows: depositAllocations.map { allocation in
                [.uuid("id", allocation.id), .optionalUUID("batch_id", allocation.batchID), .optionalUUID("source_transaction_id", allocation.sourceTransactionID), .optionalUUID("source_cash_receipt_id", allocation.sourceCashReceiptID), .optionalUUID("person_id", allocation.personID), .optionalUUID("event_id", allocation.eventID), .string("payer_name_snapshot", allocation.payerNameSnapshot), .string("purpose_snapshot", allocation.purposeSnapshot), .string("payment_kind_snapshot", allocation.paymentKindSnapshot), .date("received_at", allocation.receivedAt), .integer("amount_cents", allocation.amountCents), .date("created_at", allocation.createdAt)]
            }),
            BackupTable("reimbursement_requests", columns: ["id", "requester_person_id", "submitted_at", "purchase_date", "purpose", "category", "amount_cents", "event_id", "status", "reviewer_name", "review_notes", "reviewed_at", "approver_person_id", "approver_name_snapshot", "approver_household_snapshot", "signer_one_person_id", "signer_one_name_snapshot", "signer_one_household_snapshot", "signer_two_person_id", "signer_two_name_snapshot", "signer_two_household_snapshot", "disbursement_control_notes", "disbursement_control_recorded_at", "payment_date", "payment_reference", "linked_transaction_id", "notes", "created_at", "modified_at"], rows: reimbursementRequests.map { request in
                [.uuid("id", request.id), .optionalUUID("requester_person_id", request.requesterPersonID), .date("submitted_at", request.submittedAt), .date("purchase_date", request.purchaseDate), .string("purpose", request.purpose), .string("category", request.category), .integer("amount_cents", request.amountCents), .optionalUUID("event_id", request.eventID), .string("status", request.statusRaw), .string("reviewer_name", request.reviewerName), .string("review_notes", request.reviewNotes), .optionalDate("reviewed_at", request.reviewedAt), .optionalUUID("approver_person_id", request.approverPersonID), .string("approver_name_snapshot", request.approverNameSnapshot), .string("approver_household_snapshot", request.approverHouseholdSnapshot), .optionalUUID("signer_one_person_id", request.signerOnePersonID), .string("signer_one_name_snapshot", request.signerOneNameSnapshot), .string("signer_one_household_snapshot", request.signerOneHouseholdSnapshot), .optionalUUID("signer_two_person_id", request.signerTwoPersonID), .string("signer_two_name_snapshot", request.signerTwoNameSnapshot), .string("signer_two_household_snapshot", request.signerTwoHouseholdSnapshot), .string("disbursement_control_notes", request.disbursementControlNotes), .optionalDate("disbursement_control_recorded_at", request.disbursementControlRecordedAt), .optionalDate("payment_date", request.paymentDate), .string("payment_reference", request.paymentReference), .optionalUUID("linked_transaction_id", request.linkedTransactionID), .string("notes", request.notes), .date("created_at", request.createdAt), .date("modified_at", request.modifiedAt)]
            }),
            BackupTable("disbursement_control_settings", columns: ["id", "is_enabled", "expect_approver", "expected_signer_count", "warn_same_person", "warn_same_household", "warn_missing_household", "modified_at"], rows: disbursementSettings.map { settings in
                [.uuid("id", settings.id), .boolean("is_enabled", settings.isEnabled), .boolean("expect_approver", settings.expectApprover), .integer("expected_signer_count", Int64(settings.expectedSignerCount)), .boolean("warn_same_person", settings.warnSamePerson), .boolean("warn_same_household", settings.warnSameHousehold), .boolean("warn_missing_household", settings.warnMissingHousehold), .date("modified_at", settings.modifiedAt)]
            }),
            BackupTable("reimbursement_attachments", columns: ["id", "request_id", "filename", "media_type", "byte_count", "sha256", "relative_path", "created_at"], rows: reimbursementAttachments.map { attachment in
                [.uuid("id", attachment.id), .optionalUUID("request_id", attachment.requestID), .string("filename", attachment.filename), .string("media_type", attachment.mediaType), .integer("byte_count", attachment.byteCount), .string("sha256", attachment.sha256), .string("relative_path", attachmentRelativePath(attachment)), .date("created_at", attachment.createdAt)]
            }),
            BackupTable("families", columns: ["id", "name", "notes", "created_at", "modified_at"], rows: families.map { family in
                [.uuid("id", family.id), .string("name", family.name), .string("notes", family.notes), .date("created_at", family.createdAt), .date("modified_at", family.modifiedAt)]
            }),
            BackupTable("recurring_charge_batches", columns: ["id", "name", "kind", "charge_date", "category", "program_year", "fixed_amount_cents", "total_cents", "allocation_count", "notes", "created_at", "posted_at"], rows: recurringChargeBatches.map { batch in
                [.uuid("id", batch.id), .string("name", batch.name), .string("kind", batch.kindRaw), .date("charge_date", batch.chargeDate), .string("category", batch.category), .string("program_year", batch.programYear), .integer("fixed_amount_cents", batch.fixedAmountCents), .integer("total_cents", batch.totalCents), .integer("allocation_count", Int64(batch.allocationCount)), .string("notes", batch.notes), .date("created_at", batch.createdAt), .date("posted_at", batch.postedAt)]
            }),
            BackupTable("recurring_charge_allocations", columns: ["id", "batch_id", "person_id", "member_entry_id", "registration_id", "person_name_snapshot", "charge_date", "category_snapshot", "amount_cents", "created_at"], rows: recurringChargeAllocations.map { allocation in
                [.uuid("id", allocation.id), .optionalUUID("batch_id", allocation.batchID), .optionalUUID("person_id", allocation.personID), .optionalUUID("member_entry_id", allocation.memberEntryID), .optionalUUID("registration_id", allocation.registrationID), .string("person_name_snapshot", allocation.personNameSnapshot), .date("charge_date", allocation.chargeDate), .string("category_snapshot", allocation.categorySnapshot), .integer("amount_cents", allocation.amountCents), .date("created_at", allocation.createdAt)]
            }),
            BackupTable("people", columns: ["id", "first_name", "last_name", "role", "current_rank", "troop_position_ids", "custom_position", "patrol", "scouting_member_id", "email", "phone", "family_id", "join_date", "is_active", "notes", "created_at"], rows: people.map { person in
                [.uuid("id", person.id), .string("first_name", person.firstName), .string("last_name", person.lastName), .string("role", person.roleRaw), .string("current_rank", person.currentRankRaw), .string("troop_position_ids", person.troopPositionIDsRaw), .string("custom_position", person.customPosition), .string("patrol", person.patrol), .string("scouting_member_id", person.scoutingMemberID), .string("email", person.email), .string("phone", person.phone), .optionalUUID("family_id", person.familyID), .optionalDate("join_date", person.joinDate), .boolean("is_active", person.isActive), .string("notes", person.notes), .date("created_at", person.createdAt)]
            }),
            BackupTable("member_ledger_entries", columns: ["id", "person_id", "date", "kind", "amount_cents", "category", "event_id", "account_transaction_id", "charge_batch_id", "notes", "created_at", "source_sheet", "source_row", "source_system", "external_source_id"], rows: memberEntries.map { entry in
                [.uuid("id", entry.id), .optionalUUID("person_id", entry.personID), .date("date", entry.date), .string("kind", entry.kindRaw), .integer("amount_cents", entry.amountCents), .string("category", entry.category), .optionalUUID("event_id", entry.eventID), .optionalUUID("account_transaction_id", entry.accountTransactionID), .optionalUUID("charge_batch_id", entry.chargeBatchID), .string("notes", entry.notes), .date("created_at", entry.createdAt), .string("source_sheet", entry.sourceSheet), .integer("source_row", Int64(entry.sourceRow)), .string("source_system", entry.sourceSystem), .string("external_source_id", entry.externalSourceID)]
            }),
            BackupTable("registrations", columns: ["id", "person_id", "program_year", "unit_role", "status", "registered_on", "expires_on", "dues_assessed_cents", "notes", "created_at", "source_sheet", "source_row"], rows: registrations.map { registration in
                [.uuid("id", registration.id), .optionalUUID("person_id", registration.personID), .string("program_year", registration.programYear), .string("unit_role", registration.unitRole), .string("status", registration.statusRaw), .date("registered_on", registration.registeredOn), .optionalDate("expires_on", registration.expiresOn), .integer("dues_assessed_cents", registration.duesAssessedCents), .string("notes", registration.notes), .date("created_at", registration.createdAt), .string("source_sheet", registration.sourceSheet), .integer("source_row", Int64(registration.sourceRow))]
            }),
            BackupTable("events", columns: ["id", "name", "category", "classification", "start_date", "end_date", "registration_deadline", "location", "address", "location_details", "coordinator", "registration_reference", "status", "capacity", "budget_income_cents", "budget_expense_cents", "fee_fixed_costs_cents", "fee_per_person_costs_cents", "fee_expected_participants", "fee_contingency_basis_points", "fee_suggested_cents", "closed_at", "closeout_id", "notes", "date_is_approximate", "source_sheet", "source_system", "external_source_id", "calendar_subscription_id", "is_read_only", "is_all_day", "external_modified_at", "created_at"], rows: events.map { event in
                [.uuid("id", event.id), .string("name", event.name), .string("category", event.category), .string("classification", event.classificationRaw), .date("start_date", event.startDate), .date("end_date", event.endDate), .optionalDate("registration_deadline", event.registrationDeadline), .string("location", event.location), .string("address", event.address), .string("location_details", event.locationDetails), .string("coordinator", event.coordinator), .string("registration_reference", event.registrationReference), .string("status", event.statusRaw), .integer("capacity", Int64(event.capacity)), .integer("budget_income_cents", event.budgetIncomeCents), .integer("budget_expense_cents", event.budgetExpenseCents), .integer("fee_fixed_costs_cents", event.feeCalculatorFixedCostsCents), .integer("fee_per_person_costs_cents", event.feeCalculatorPerPersonCostsCents), .integer("fee_expected_participants", Int64(event.feeCalculatorExpectedParticipants)), .integer("fee_contingency_basis_points", Int64(event.feeCalculatorContingencyBasisPoints)), .integer("fee_suggested_cents", event.feeCalculatorSuggestedFeeCents), .optionalDate("closed_at", event.closedAt), .optionalUUID("closeout_id", event.closeoutID), .string("notes", event.notes), .boolean("date_is_approximate", event.dateIsApproximate), .string("source_sheet", event.sourceSheet), .string("source_system", event.sourceSystem), .string("external_source_id", event.externalSourceID), .optionalUUID("calendar_subscription_id", event.calendarSubscriptionID), .boolean("is_read_only", event.isReadOnly), .boolean("is_all_day", event.isAllDay), .optionalDate("external_modified_at", event.externalModifiedAt), .date("created_at", event.createdAt)]
            }),
            BackupTable("event_fee_schedules", columns: ["id", "event_id", "name", "eligibility_notes", "fee_cents", "is_default", "created_at", "modified_at"], rows: eventFeeSchedules.map { schedule in
                [.uuid("id", schedule.id), .optionalUUID("event_id", schedule.eventID), .string("name", schedule.name), .string("eligibility_notes", schedule.eligibilityNotes), .integer("fee_cents", schedule.feeCents), .boolean("is_default", schedule.isDefault), .date("created_at", schedule.createdAt), .date("modified_at", schedule.modifiedAt)]
            }),
            BackupTable("event_participants", columns: ["id", "event_id", "person_id", "guest_name", "status", "fee_cents", "paid_cents", "fee_schedule_id", "fee_schedule_name_snapshot", "transportation", "notes", "created_at"], rows: participants.map { participant in
                [.uuid("id", participant.id), .optionalUUID("event_id", participant.eventID), .optionalUUID("person_id", participant.personID), .string("guest_name", participant.guestName), .string("status", participant.statusRaw), .integer("fee_cents", participant.feeCents), .integer("paid_cents", participant.paidCents), .optionalUUID("fee_schedule_id", participant.feeScheduleID), .string("fee_schedule_name_snapshot", participant.feeScheduleNameSnapshot), .string("transportation", participant.transportation), .string("notes", participant.notes), .date("created_at", participant.createdAt)]
            }),
            BackupTable("event_closeouts", columns: ["id", "event_id", "closed_at", "roster_count", "actual_income_cents", "actual_expense_cents", "actual_participant_cost_cents", "unpaid_cents", "refund_due_cents", "final_variance_cents", "posted_adjustment_count", "notes", "created_at"], rows: eventCloseouts.map { closeout in
                [.uuid("id", closeout.id), .optionalUUID("event_id", closeout.eventID), .date("closed_at", closeout.closedAt), .integer("roster_count", Int64(closeout.rosterCount)), .integer("actual_income_cents", closeout.actualIncomeCents), .integer("actual_expense_cents", closeout.actualExpenseCents), .integer("actual_participant_cost_cents", closeout.actualParticipantCostCents), .integer("unpaid_cents", closeout.unpaidCents), .integer("refund_due_cents", closeout.refundDueCents), .integer("final_variance_cents", closeout.finalVarianceCents), .integer("posted_adjustment_count", Int64(closeout.postedAdjustmentCount)), .string("notes", closeout.notes), .date("created_at", closeout.createdAt)]
            }),
            BackupTable("event_closeout_allocations", columns: ["id", "closeout_id", "event_id", "participant_id", "person_id", "member_entry_id", "participant_name_snapshot", "status_snapshot", "fee_schedule_name_snapshot", "fee_cents", "paid_cents", "balance_cents", "proposed_adjustment_cents", "created_at"], rows: eventCloseoutAllocations.map { allocation in
                [.uuid("id", allocation.id), .optionalUUID("closeout_id", allocation.closeoutID), .optionalUUID("event_id", allocation.eventID), .optionalUUID("participant_id", allocation.participantID), .optionalUUID("person_id", allocation.personID), .optionalUUID("member_entry_id", allocation.memberEntryID), .string("participant_name_snapshot", allocation.participantNameSnapshot), .string("status_snapshot", allocation.statusSnapshot), .string("fee_schedule_name_snapshot", allocation.feeScheduleNameSnapshot), .integer("fee_cents", allocation.feeCents), .integer("paid_cents", allocation.paidCents), .integer("balance_cents", allocation.balanceCents), .integer("proposed_adjustment_cents", allocation.proposedAdjustmentCents), .date("created_at", allocation.createdAt)]
            }),
            BackupTable("event_financial_entries", columns: ["id", "event_id", "date", "direction", "amount_cents", "description", "is_projected", "source_sheet", "source_row", "created_at"], rows: eventFinancialEntries.map { entry in
                [.uuid("id", entry.id), .optionalUUID("event_id", entry.eventID), .date("date", entry.date), .string("direction", entry.directionRaw), .integer("amount_cents", entry.amountCents), .string("description", entry.entryDescription), .boolean("is_projected", entry.isProjected), .string("source_sheet", entry.sourceSheet), .integer("source_row", Int64(entry.sourceRow)), .date("created_at", entry.createdAt)]
            }),
            BackupTable("cash_receipts", columns: ["id", "date", "person_name", "purpose", "amount_cents", "payment_kind", "source_sheet", "source_row", "created_at"], rows: cashReceipts.map { receipt in
                [.uuid("id", receipt.id), .date("date", receipt.date), .string("person_name", receipt.personName), .string("purpose", receipt.purpose), .integer("amount_cents", receipt.amountCents), .string("payment_kind", receipt.paymentKind), .string("source_sheet", receipt.sourceSheet), .integer("source_row", Int64(receipt.sourceRow)), .date("created_at", receipt.createdAt)]
            }),
            BackupTable("reconciliations", columns: ["id", "account_id", "statement_date", "statement_ending_balance_cents", "cleared_balance_cents", "completed_at", "notes"], rows: reconciliations.map { reconciliation in
                [.uuid("id", reconciliation.id), .optionalUUID("account_id", reconciliation.accountID), .date("statement_date", reconciliation.statementDate), .integer("statement_ending_balance_cents", reconciliation.statementEndingBalanceCents), .integer("cleared_balance_cents", reconciliation.clearedBalanceCents), .date("completed_at", reconciliation.completedAt), .string("notes", reconciliation.notes)]
            }),
            BackupTable("workbook_imports", columns: ["id", "source_name", "source_fingerprint", "imported_at", "account_count", "transaction_count", "cash_receipt_count", "people_count", "registration_count", "member_entry_count", "event_count", "event_line_item_count"], rows: imports.map { record in
                [.uuid("id", record.id), .string("source_name", record.sourceName), .string("source_fingerprint", record.sourceFingerprint), .date("imported_at", record.importedAt), .integer("account_count", Int64(record.accountCount)), .integer("transaction_count", Int64(record.transactionCount)), .integer("cash_receipt_count", Int64(record.cashReceiptCount)), .integer("people_count", Int64(record.peopleCount)), .integer("registration_count", Int64(record.registrationCount)), .integer("member_entry_count", Int64(record.memberEntryCount)), .integer("event_count", Int64(record.eventCount)), .integer("event_line_item_count", Int64(record.eventLineItemCount))]
            }),
            BackupTable("general_spreadsheet_imports", columns: ["id", "source_name", "source_fingerprint", "imported_at", "account_id", "source_row_count", "imported_count", "skipped_count", "mapping_summary", "exception_notes"], rows: generalSpreadsheetImports.map { record in
                [.uuid("id", record.id), .string("source_name", record.sourceName), .string("source_fingerprint", record.sourceFingerprint), .date("imported_at", record.importedAt), .optionalUUID("account_id", record.accountID), .integer("source_row_count", Int64(record.sourceRowCount)), .integer("imported_count", Int64(record.importedCount)), .integer("skipped_count", Int64(record.skippedCount)), .string("mapping_summary", record.mappingSummary), .string("exception_notes", record.exceptionNotes)]
            }),
            BackupTable("scoutbook_imports", columns: ["id", "source_name", "source_fingerprint", "import_kind", "imported_at", "source_row_count", "inserted_count", "updated_count", "skipped_count", "notes"], rows: scoutbookImports.map { record in
                [.uuid("id", record.id), .string("source_name", record.sourceName), .string("source_fingerprint", record.sourceFingerprint), .string("import_kind", record.importKind), .date("imported_at", record.importedAt), .integer("source_row_count", Int64(record.sourceRowCount)), .integer("inserted_count", Int64(record.insertedCount)), .integer("updated_count", Int64(record.updatedCount)), .integer("skipped_count", Int64(record.skippedCount)), .string("notes", record.notes)]
            }),
            BackupTable("calendar_subscriptions", columns: ["id", "name", "feed_url", "is_enabled", "last_synced_at", "last_error", "last_event_count", "created_at"], rows: subscriptions.map { subscription in
                [.uuid("id", subscription.id), .string("name", subscription.name), .string("feed_url", subscription.feedURLString), .boolean("is_enabled", subscription.isEnabled), .optionalDate("last_synced_at", subscription.lastSyncedAt), .string("last_error", subscription.lastError), .integer("last_event_count", Int64(subscription.lastEventCount)), .date("created_at", subscription.createdAt)]
            }),
            BackupTable("audit_log", columns: ["id", "timestamp", "action", "record_type", "record_id", "summary", "details", "device_name", "operating_system", "user_identity"], rows: auditEntries.map { entry in
                [.uuid("id", entry.id), .date("timestamp", entry.timestamp), .string("action", entry.actionRaw), .string("record_type", entry.recordType), .optionalUUID("record_id", entry.recordID), .string("summary", entry.summary), .string("details", entry.details), .string("device_name", entry.deviceName), .string("operating_system", entry.operatingSystem), .string("user_identity", entry.userIdentity)]
            }),
            BackupTable("attachments_manifest", columns: ["attachment_id", "record_type", "record_id", "relative_path", "original_filename", "media_type", "byte_count", "sha256", "recorded_byte_count", "recorded_sha256", "integrity"], rows: reimbursementAttachments.map { attachment in
                // Hash the bytes actually written to the package rather than trusting the value recorded at attach time,
                // so a receipt that changed after it was attached is visible in the manifest.
                let actualSHA256 = sha256Hex(attachment.data)
                let intact = actualSHA256 == attachment.sha256.lowercased() && Int64(attachment.data.count) == attachment.byteCount
                return [.uuid("attachment_id", attachment.id), .string("record_type", "Reimbursement Request"), .optionalUUID("record_id", attachment.requestID), .string("relative_path", attachmentRelativePath(attachment)), .string("original_filename", attachment.filename), .string("media_type", attachment.mediaType), .integer("byte_count", Int64(attachment.data.count)), .string("sha256", actualSHA256), .integer("recorded_byte_count", attachment.byteCount), .string("recorded_sha256", attachment.sha256), .string("integrity", intact ? "verified" : "MISMATCH")]
            }),
        ]
    }

    private static func attachmentRelativePath(_ attachment: ReimbursementAttachment) -> String {
        let request = attachment.requestID?.uuidString.lowercased() ?? "unlinked"
        return "attachments/\(request)/\(attachment.id.uuidString.lowercased())-\(safePathComponent(attachment.filename))"
    }

    /// Reduces a stored filename to a single safe path component. Attachment names are sanitized when attached,
    /// but records can also arrive from older app versions or other devices through CloudKit, so the exporter
    /// must not trust them when it decides where inside the package a file is written.
    static func safePathComponent(_ filename: String) -> String {
        let lastComponent = (filename as NSString).lastPathComponent
        var cleaned = String(lastComponent.map { character in
            character.isLetter || character.isNumber || "._- ".contains(character) ? character : "_"
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "receipt" : cleaned
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func csv(for table: BackupTable) -> String {
        let header = table.columns.map(csvField).joined(separator: ",")
        let lines = table.rows.map { row in
            table.columns.map { column in csvField(row[column]?.csvString ?? "") }.joined(separator: ",")
        }
        return ([header] + lines).joined(separator: "\r\n") + "\r\n"
    }

    private static func csvField(_ value: String) -> String {
        CSVFormatting.field(value)
    }

    private static func readme(generatedAt: String, applicationVersion: String) -> String {
        """
        TroopLedger Plaintext Backup

        Format version: \(formatVersion)
        Application version: \(applicationVersion)
        Generated at: \(generatedAt)

        backup.json contains the complete normalized snapshot. Each table is also present as a UTF-8, RFC 4180-style CSV file. UUID fields preserve relationships between tables. Dates use UTC ISO 8601, and money is stored as integer cents.

        troop_profile.csv preserves the unit identity, mailing and contact details, treasurer information, and report-header settings. attachments_manifest.csv lists reimbursement receipt files, their owning request, relative path, media type, byte count, and SHA-256 checksum. The receipt files are stored beneath the attachments directory. Reimbursement rows preserve recorded approver and signer identity snapshots, and disbursement_control_settings.csv preserves the advisory warning policy. Deposit batches, their receipt allocations, and both linked account-transfer entries are preserved in deposit_batches.csv, deposit_allocations.csv, and transactions.csv. Event fee assumptions, fee schedules, frozen close-outs, and their immutable participant allocations are preserved in the event tables.

        This backup contains private financial and contact information, including calendar subscription URLs. Store and transfer it securely. Text values that begin with a formula character (=, +, -, @) are prefixed with an apostrophe in the CSV files so spreadsheet programs treat them as text; use backup.json when exact value preservation matters.
        """
    }
}

private struct BackupJSONDocument: Encodable {
    let format: String
    let formatVersion: Int
    let applicationVersion: String
    let generatedAt: String
    let tables: [BackupTable]
}

private struct BackupTable: Encodable {
    let name: String
    let columns: [String]
    let rows: [[String: BackupValue]]

    init(_ name: String, columns: [String], rows: [[BackupField]]) {
        self.name = name
        self.columns = columns
        self.rows = rows.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key, $0.value) }) }
    }
}

private struct BackupField {
    let key: String
    let value: BackupValue

    static func string(_ key: String, _ value: String) -> Self { .init(key: key, value: .string(value)) }
    static func integer(_ key: String, _ value: Int64) -> Self { .init(key: key, value: .integer(value)) }
    static func boolean(_ key: String, _ value: Bool) -> Self { .init(key: key, value: .boolean(value)) }
    static func uuid(_ key: String, _ value: UUID) -> Self { .string(key, value.uuidString.lowercased()) }
    static func optionalUUID(_ key: String, _ value: UUID?) -> Self { value.map { .uuid(key, $0) } ?? .init(key: key, value: .null) }
    static func date(_ key: String, _ value: Date) -> Self { .string(key, backupISO8601String(from: value)) }
    static func optionalDate(_ key: String, _ value: Date?) -> Self { value.map { .date(key, $0) } ?? .init(key: key, value: .null) }
}

private enum BackupValue: Encodable {
    case string(String)
    case integer(Int64)
    case boolean(Bool)
    case null

    var csvString: String {
        switch self {
        case .string(let value): value
        case .integer(let value): String(value)
        case .boolean(let value): value ? "true" : "false"
        case .null: ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private extension Array where Element: PersistentModel & Identifiable, Element.ID == UUID {
    func sortedByID() -> [Element] {
        sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

private func backupISO8601String(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

/// Shared RFC 4180 field encoding for every CSV the app exports.
///
/// Besides quoting separators, it neutralizes spreadsheet formula triggers. Payees, memos, categories, and event
/// names come from bank exports, Scoutbook files, and calendar feeds, and the exported CSVs are handed to other
/// people, so a cell such as `=HYPERLINK(...)` or `=cmd|' /C calc'!A0` must open as text, never as a formula.
enum CSVFormatting {
    static func field(_ value: String) -> String {
        let text = isFormulaLike(value) ? "'" + value : value
        guard text != value || text.contains(",") || text.contains("\"") || text.contains("\n") || text.contains("\r") else {
            return text
        }
        return "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// True when a spreadsheet would evaluate the cell. Plain signed numbers such as `-1250` are not formulas.
    static func isFormulaLike(_ value: String) -> Bool {
        let candidate = value.drop(while: { $0 == " " })
        guard let first = candidate.first else { return false }
        switch first {
        case "=", "+", "@", "\t", "\r":
            return true
        case "-":
            return !isPlainNumber(candidate)
        default:
            return false
        }
    }

    private static func isPlainNumber(_ value: Substring) -> Bool {
        var digits = value.dropFirst()
        guard !digits.isEmpty else { return false }
        if let dot = digits.firstIndex(of: ".") {
            let fraction = digits[digits.index(after: dot)...]
            digits = digits[..<dot]
            guard !fraction.isEmpty, fraction.allSatisfy(\.isNumber) else { return false }
        }
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }
}
