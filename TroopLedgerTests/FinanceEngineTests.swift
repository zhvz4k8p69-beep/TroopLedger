import XCTest
import SwiftData
import SwiftUI
@testable import TroopLedger

final class FinanceEngineTests: XCTestCase {
    @MainActor
    func testStartOverDeletesEveryPersistedRecordType() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let now = Date()

        context.insert(TroopProfileRecord())
        context.insert(AccountRecord(name: "Checking"))
        context.insert(LedgerCategoryRecord(name: "Dues", direction: .income))
        context.insert(OperatingBudgetRecord(reportingYearStart: 2026))
        context.insert(BudgetLineRecord(budgetID: nil, categoryID: nil, categoryName: "Dues", direction: .income, amountCents: 1))
        context.insert(LedgerTransaction(accountID: nil, date: now, direction: .income, amountCents: 1, payee: "Test", category: "Dues"))
        context.insert(DepositBatchRecord(undepositedFundsAccountID: nil, destinationAccountID: nil, depositDate: now, totalCents: 1))
        context.insert(DepositAllocationRecord(batchID: nil, receivedAt: now, amountCents: 1))
        context.insert(ReimbursementRequest(requesterPersonID: nil, purchaseDate: now, purpose: "Test", category: "Supplies", amountCents: 1))
        context.insert(DisbursementControlSettings())
        context.insert(ReimbursementAttachment(requestID: nil, filename: "receipt.txt", mediaType: "text/plain", byteCount: 1, sha256: "test", data: Data([0])))
        context.insert(FamilyRecord(name: "Test Family"))
        context.insert(RecurringChargeBatchRecord(name: "Test Charges", kind: .dues, chargeDate: now, category: "Dues"))
        context.insert(RecurringChargeAllocationRecord(batchID: nil, personID: nil, chargeDate: now, amountCents: 1))
        context.insert(PersonRecord(firstName: "Test", lastName: "Person", role: .scout))
        context.insert(MemberLedgerEntry(personID: nil, date: now, kind: .charge, amountCents: 1, category: "Dues"))
        context.insert(RegistrationRecord(personID: nil, programYear: "2026", unitRole: "Scout", status: .current))
        context.insert(EventRecord(name: "Test Event", startDate: now, endDate: now))
        context.insert(EventFeeScheduleRecord(eventID: nil, name: "Standard", feeCents: 1))
        context.insert(EventParticipant(eventID: nil, personID: nil))
        context.insert(EventCloseoutRecord(eventID: nil, closedAt: now))
        context.insert(EventCloseoutAllocationRecord(closeoutID: nil, eventID: nil, participantID: nil))
        context.insert(EventFinancialEntry(eventID: nil, date: now, direction: .expense, amountCents: 1, description: "Test"))
        context.insert(CashReceiptRecord(date: now, personName: "Test", purpose: "Dues", amountCents: 1, paymentKind: "Cash"))
        context.insert(ReconciliationRecord(accountID: nil, statementDate: now, statementEndingBalanceCents: 1, clearedBalanceCents: 1))
        context.insert(ImportRecord(sourceName: "test.xlsx", sourceFingerprint: "workbook"))
        context.insert(GeneralSpreadsheetImportRecord(sourceName: "test.csv", sourceFingerprint: "spreadsheet", accountID: nil))
        context.insert(ScoutbookImportRecord(sourceName: "scoutbook.csv", sourceFingerprint: "scoutbook", importKind: "Roster"))
        context.insert(ExternalCalendarSubscription(name: "Calendar", feedURLString: "https://example.com/calendar.ics"))
        context.insert(AuditLogEntry(action: .create, recordType: "Test", recordID: nil, summary: "Test", deviceName: "Test Mac", operatingSystem: "macOS Test", userIdentity: "Tester"))
        try context.save()

        XCTAssertEqual(
            DataResetService.supportedModelTypeNames,
            Set(ModelContainerFactory.modelTypes.map { String(reflecting: $0) }),
            "The reset service must be updated whenever the SwiftData schema changes."
        )

        let result = try DataResetService.deleteAllRecords(from: context)

        XCTAssertEqual(result.deletedRecordCount, ModelContainerFactory.modelTypes.count)
        let backup = try PlaintextBackupService.makeArchive(from: context, applicationVersion: "1.0.0-test")
        XCTAssertTrue(backup.recordCounts.values.allSatisfy { $0 == 0 })
    }

    func testBookBalanceUsesOpeningBalanceAndSignedTransactions() throws {
        let account = AccountRecord(name: "Checking", openingBalanceCents: 10_000)
        let deposit = LedgerTransaction(accountID: account.id, date: Date(), direction: .income, amountCents: 5_000, payee: "Deposit", category: "Dues")
        let expense = LedgerTransaction(accountID: account.id, date: Date(), direction: .expense, amountCents: 2_500, payee: "Council", category: "Registration")

        XCTAssertEqual(FinanceEngine.bookBalance(account: account, transactions: [deposit, expense]), 12_500)
    }

    func testCashPositionSeparatesUndepositedFundsFromBankAndCashOnHand() {
        let checking = AccountRecord(name: "Checking", kind: .checking, openingBalanceCents: 10_000)
        let cash = AccountRecord(name: "Cash Box", kind: .cash, openingBalanceCents: 2_000)
        let undeposited = AccountRecord(name: "Undeposited Funds", kind: .undepositedFunds, openingBalanceCents: 1_000)
        let receivedCheck = LedgerTransaction(
            accountID: undeposited.id,
            date: Date(),
            direction: .income,
            amountCents: 4_500,
            payee: "Family",
            category: "Dues"
        )

        let position = FinanceEngine.cashPosition(
            accounts: [checking, cash, undeposited],
            transactions: [receivedCheck]
        )

        XCTAssertEqual(position.bankAndCashOnHandCents, 12_000)
        XCTAssertEqual(position.undepositedFundsCents, 5_500)
        XCTAssertEqual(position.totalCents, 17_500)
        XCTAssertEqual(undeposited.kindRaw, "Undeposited Funds")
    }

    func testClearedBalanceIncludesOnlyClearedAndSelectedTransactions() throws {
        let account = AccountRecord(name: "Checking", openingBalanceCents: 10_000)
        let cleared = LedgerTransaction(accountID: account.id, date: Date(), direction: .expense, amountCents: 2_000, payee: "Cleared", category: "Supplies")
        cleared.isCleared = true
        let selected = LedgerTransaction(accountID: account.id, date: Date(), direction: .income, amountCents: 4_000, payee: "Deposit", category: "Dues")
        let outstanding = LedgerTransaction(accountID: account.id, date: Date(), direction: .expense, amountCents: 1_000, payee: "Outstanding", category: "Supplies")

        XCTAssertEqual(
            FinanceEngine.clearedBalance(account: account, transactions: [cleared, selected, outstanding], additionallyCleared: [selected.id]),
            12_000
        )
    }

    func testReconciliationIncludesWholeStatementDayButExcludesFutureClearedTransactions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let statementDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 9)))
        let sameDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 20)))
        let nextDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        let account = AccountRecord(name: "Checking", openingBalanceCents: 10_000)
        let selected = LedgerTransaction(accountID: account.id, date: sameDay, direction: .income, amountCents: 2_000, payee: "Deposit", category: "Dues")
        let futureCleared = LedgerTransaction(accountID: account.id, date: nextDay, direction: .expense, amountCents: 9_000, payee: "Future", category: "Supplies")
        futureCleared.isCleared = true

        XCTAssertTrue(ReconciliationPolicy.isEligible(selected, accountID: account.id, statementDate: statementDate, calendar: calendar))
        XCTAssertFalse(ReconciliationPolicy.isEligible(futureCleared, accountID: account.id, statementDate: statementDate, calendar: calendar))
        XCTAssertEqual(
            FinanceEngine.clearedBalance(
                account: account,
                transactions: [selected, futureCleared],
                additionallyCleared: [selected.id],
                through: statementDate,
                calendar: calendar
            ),
            12_000
        )
    }

    func testReconciledAccountOpeningBalanceIsImmutable() {
        let account = AccountRecord(name: "Checking", openingBalanceCents: 10_000)
        let reconciliation = ReconciliationRecord(accountID: account.id, statementDate: Date(), statementEndingBalanceCents: 10_000, clearedBalanceCents: 10_000)

        XCTAssertTrue(ReconciliationPolicy.canEditOpeningBalance(account, reconciliations: []))
        XCTAssertFalse(ReconciliationPolicy.canEditOpeningBalance(account, reconciliations: [reconciliation]))
    }

    func testReconciliationsLockAccountThroughLatestStatementDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let account = AccountRecord(name: "Checking")
        let otherAccount = AccountRecord(name: "Savings")
        let january = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 31)))
        let february = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 28)))
        let march = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)))
        let reconciliations = [
            ReconciliationRecord(accountID: account.id, statementDate: january, statementEndingBalanceCents: 0, clearedBalanceCents: 0),
            ReconciliationRecord(accountID: account.id, statementDate: february, statementEndingBalanceCents: 0, clearedBalanceCents: 0),
            ReconciliationRecord(accountID: otherAccount.id, statementDate: march, statementEndingBalanceCents: 0, clearedBalanceCents: 0),
        ]
        let oldTransaction = LedgerTransaction(accountID: account.id, date: january, direction: .expense, amountCents: 1_000, payee: "Old", category: "Supplies")
        let newTransaction = LedgerTransaction(accountID: account.id, date: march, direction: .expense, amountCents: 1_000, payee: "New", category: "Supplies")

        XCTAssertEqual(PeriodLocking.latestLockDate(for: account.id, reconciliations: reconciliations, calendar: calendar), february)
        XCTAssertTrue(PeriodLocking.isLocked(oldTransaction, reconciliations: reconciliations, calendar: calendar))
        XCTAssertFalse(PeriodLocking.isLocked(newTransaction, reconciliations: reconciliations, calendar: calendar))
        XCTAssertEqual(
            PeriodLocking.firstUnlockedDate(for: account.id, reconciliations: reconciliations, relativeTo: january, calendar: calendar),
            march
        )
    }

    func testLockedPeriodsRequireLinkedExplainedAdjustments() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let account = AccountRecord(name: "Checking")
        let lockedDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 30)))
        let unlockedDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1)))
        let reconciliation = ReconciliationRecord(accountID: account.id, statementDate: lockedDate, statementEndingBalanceCents: 0, clearedBalanceCents: 0)
        let targetID = UUID()

        XCTAssertEqual(
            PeriodLocking.validatePosting(
                accountID: account.id,
                date: lockedDate,
                isAdjustment: false,
                adjustsTransactionID: nil,
                adjustmentReason: "",
                reconciliations: [reconciliation],
                calendar: calendar
            ),
            .locked(through: lockedDate)
        )
        XCTAssertEqual(
            PeriodLocking.validatePosting(
                accountID: account.id,
                date: unlockedDate,
                isAdjustment: true,
                adjustsTransactionID: nil,
                adjustmentReason: "Correction",
                reconciliations: [reconciliation],
                calendar: calendar
            ),
            .adjustmentTargetRequired
        )
        XCTAssertEqual(
            PeriodLocking.validatePosting(
                accountID: account.id,
                date: unlockedDate,
                isAdjustment: true,
                adjustsTransactionID: targetID,
                adjustmentReason: "  ",
                reconciliations: [reconciliation],
                calendar: calendar
            ),
            .adjustmentReasonRequired
        )
        XCTAssertEqual(
            PeriodLocking.validatePosting(
                accountID: account.id,
                date: unlockedDate,
                isAdjustment: true,
                adjustsTransactionID: targetID,
                adjustmentReason: "Correct the duplicated amount",
                reconciliations: [reconciliation],
                calendar: calendar
            ),
            .valid
        )
    }

    @MainActor
    func testAuditLoggerPersistsImmutableActivityMetadata() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let recordID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_788_825_600)
        let identity = AuditIdentity(
            deviceName: "Treasurer Mac",
            operatingSystem: "macOS Test",
            userIdentity: "Test Treasurer"
        )

        AuditLogger.record(
            .edit,
            recordType: "Transaction",
            recordID: recordID,
            summary: "Edited transaction Camp reservation",
            details: "Amount: $125.00",
            at: timestamp,
            identity: identity,
            in: context
        )
        try context.save()

        let entries = try context.fetch(FetchDescriptor<AuditLogEntry>())
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entry.action, .edit)
        XCTAssertEqual(entry.recordType, "Transaction")
        XCTAssertEqual(entry.recordID, recordID)
        XCTAssertEqual(entry.timestamp, timestamp)
        XCTAssertEqual(entry.deviceName, identity.deviceName)
        XCTAssertEqual(entry.operatingSystem, identity.operatingSystem)
        XCTAssertEqual(entry.userIdentity, identity.userIdentity)
        XCTAssertEqual(entry.details, "Amount: $125.00")
    }

    @MainActor
    func testUndepositedFundsSetupCreatesOneAuditedHoldingAccount() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let account = try UndepositedFundsService.createAccount(in: context)

        XCTAssertEqual(account.name, "Undeposited Funds")
        XCTAssertEqual(account.kind, .undepositedFunds)
        XCTAssertEqual(account.openingBalanceCents, 0)
        XCTAssertTrue(account.notes.contains("not yet included in a bank deposit"))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AccountRecord>()), 1)
        let audit = try XCTUnwrap(context.fetch(FetchDescriptor<AuditLogEntry>()).first)
        XCTAssertEqual(audit.recordID, account.id)
        XCTAssertTrue(audit.summary.contains("Undeposited Funds"))

        XCTAssertThrowsError(try UndepositedFundsService.createAccount(in: context)) { error in
            XCTAssertEqual(error as? UndepositedFundsError, .accountAlreadyExists)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AccountRecord>()), 1)
    }

    @MainActor
    func testBatchDepositPostsOneBankTransferAndPreservesReceiptAllocations() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let date = Date(timeIntervalSince1970: 1_788_825_600)
        let undeposited = AccountRecord(name: "Undeposited Funds", kind: .undepositedFunds)
        let checking = AccountRecord(name: "Checking", kind: .checking)
        let person = PersonRecord(firstName: "Alex", lastName: "Family", role: .parent)
        let event = EventRecord(name: "Fall Campout", startDate: date, endDate: date)
        let ledgerReceipt = LedgerTransaction(
            accountID: undeposited.id,
            date: date,
            direction: .income,
            amountCents: 3_000,
            payee: person.displayName,
            category: "Dues"
        )
        ledgerReceipt.personID = person.id
        ledgerReceipt.eventID = event.id
        let importedReceipt = CashReceiptRecord(
            date: date,
            personName: person.displayName,
            purpose: "Camp fee",
            amountCents: 2_000,
            paymentKind: "Check"
        )
        context.insert(undeposited)
        context.insert(checking)
        context.insert(person)
        context.insert(event)
        context.insert(ledgerReceipt)
        context.insert(importedReceipt)
        try context.save()

        let batch = try BatchDepositService.post(
            destinationAccountID: checking.id,
            depositDate: date,
            reference: "DEP-100",
            notes: "Weekly deposit",
            sourceTransactionIDs: [ledgerReceipt.id],
            sourceCashReceiptIDs: [importedReceipt.id],
            reconciliations: [],
            now: date,
            in: context
        )

        XCTAssertEqual(batch.totalCents, 5_000)
        XCTAssertEqual(batch.reference, "DEP-100")
        let allocations = try context.fetch(FetchDescriptor<DepositAllocationRecord>())
        XCTAssertEqual(allocations.count, 2)
        XCTAssertEqual(Set(allocations.map(\.payerNameSnapshot)), [person.displayName])
        XCTAssertTrue(allocations.contains { $0.eventID == event.id && $0.purposeSnapshot == "Dues" })
        XCTAssertTrue(allocations.contains { $0.sourceCashReceiptID == importedReceipt.id && $0.paymentKindSnapshot == "Check" })

        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())
        let transfers = transactions.filter(\.isTransfer)
        XCTAssertEqual(transfers.count, 2)
        XCTAssertEqual(Set(transfers.compactMap(\.transferGroupID)), [batch.id])
        XCTAssertEqual(FinanceEngine.bookBalance(account: undeposited, transactions: transactions), 0)
        XCTAssertEqual(FinanceEngine.bookBalance(account: checking, transactions: transactions), 5_000)

        let annual = FinanceEngine.annualReport(period: .containing(date), transactions: transactions)
        XCTAssertEqual(annual.totalIncomeCents, 5_000)
        XCTAssertEqual(annual.totalExpenseCents, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AuditLogEntry>()), 1)

        let archive = try PlaintextBackupService.makeArchive(from: context, applicationVersion: "0.15.0-test")
        XCTAssertEqual(archive.recordCounts["deposit_batches"], 1)
        XCTAssertEqual(archive.recordCounts["deposit_allocations"], 2)
        let transactionCSV = try XCTUnwrap(String(data: XCTUnwrap(archive.files["transactions.csv"]), encoding: .utf8))
        XCTAssertTrue(transactionCSV.contains("is_transfer"))
        XCTAssertTrue(transactionCSV.contains(batch.id.uuidString.lowercased()))
    }

    @MainActor
    func testBatchDepositRejectsReusedReceiptsAndLockedDestination() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 24)))
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let undeposited = AccountRecord(name: "Undeposited Funds", kind: .undepositedFunds)
        let checking = AccountRecord(name: "Checking", kind: .checking)
        let firstReceipt = LedgerTransaction(accountID: undeposited.id, date: date, direction: .income, amountCents: 1_000, payee: "Family A", category: "Dues")
        context.insert(undeposited)
        context.insert(checking)
        context.insert(firstReceipt)
        try context.save()

        _ = try BatchDepositService.post(
            destinationAccountID: checking.id,
            depositDate: date,
            reference: "1",
            notes: "",
            sourceTransactionIDs: [firstReceipt.id],
            sourceCashReceiptIDs: [],
            reconciliations: [],
            calendar: calendar,
            in: context
        )
        XCTAssertThrowsError(
            try BatchDepositService.post(
                destinationAccountID: checking.id,
                depositDate: date,
                reference: "2",
                notes: "",
                sourceTransactionIDs: [firstReceipt.id],
                sourceCashReceiptIDs: [],
                reconciliations: [],
                calendar: calendar,
                in: context
            )
        ) { error in
            XCTAssertEqual(error as? BatchDepositError, .receiptAlreadyDeposited)
        }

        let secondReceipt = LedgerTransaction(accountID: undeposited.id, date: date, direction: .income, amountCents: 1_500, payee: "Family B", category: "Dues")
        context.insert(secondReceipt)
        try context.save()
        let lock = ReconciliationRecord(accountID: checking.id, statementDate: date, statementEndingBalanceCents: 0, clearedBalanceCents: 0)
        XCTAssertThrowsError(
            try BatchDepositService.post(
                destinationAccountID: checking.id,
                depositDate: date,
                reference: "3",
                notes: "",
                sourceTransactionIDs: [secondReceipt.id],
                sourceCashReceiptIDs: [],
                reconciliations: [lock],
                calendar: calendar,
                in: context
            )
        ) { error in
            guard case .destinationPeriodLocked = error as? BatchDepositError else {
                return XCTFail("Expected destination lock, got \(error)")
            }
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DepositBatchRecord>()), 1)
    }

    @MainActor
    func testPlaintextBackupExportsEveryModelAsJSONAndNormalizedCSV() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let timestamp = Date(timeIntervalSince1970: 1_788_825_600.125)

        let account = AccountRecord(name: "Checking, \"Primary\"", institution: "Local Bank", openingBalanceCents: 12_345)
        account.createdAt = timestamp
        let troopProfile = TroopProfileRecord()
        troopProfile.troopName = "Mayflower Troop"
        troopProfile.troopNumber = "51"
        troopProfile.council = "Mayflower Council"
        troopProfile.treasurerName = "Dominic Bettinelli"
        troopProfile.createdAt = timestamp
        troopProfile.modifiedAt = timestamp
        let person = PersonRecord(firstName: "Taylor", lastName: "Scout", role: .scout)
        let family = FamilyRecord(name: "Scout Family")
        family.createdAt = timestamp
        family.modifiedAt = timestamp
        person.familyID = family.id
        person.email = "taylor@example.com"
        person.createdAt = timestamp
        let transaction = LedgerTransaction(accountID: account.id, date: timestamp, direction: .expense, amountCents: 2_500, payee: "Camp", category: "Camping")
        transaction.memo = "Deposit, first installment\nReceipt retained"
        transaction.personID = person.id
        transaction.createdAt = timestamp
        transaction.modifiedAt = timestamp
        let subscription = ExternalCalendarSubscription(name: "Troop Calendar", feedURLString: "https://example.com/private-feed.ics?token=secret")
        subscription.createdAt = timestamp
        let category = LedgerCategoryRecord(name: "Camping", direction: .expense)
        let budget = OperatingBudgetRecord(reportingYearStart: 2025, status: .approved, revision: 1)
        budget.approvedAt = timestamp
        let budgetLine = BudgetLineRecord(budgetID: budget.id, categoryID: category.id, categoryName: category.name, direction: .expense, amountCents: 50_000)
        context.insert(account)
        context.insert(troopProfile)
        context.insert(family)
        context.insert(person)
        context.insert(transaction)
        context.insert(subscription)
        context.insert(category)
        context.insert(budget)
        context.insert(budgetLine)
        try context.save()

        let archive = try PlaintextBackupService.makeArchive(
            from: context,
            exportedAt: timestamp,
            applicationVersion: "0.10.0-test"
        )
        let expectedTables: Set<String> = [
            "troop_profile", "accounts", "ledger_categories", "operating_budgets", "budget_lines", "transactions", "deposit_batches", "deposit_allocations", "reimbursement_requests", "disbursement_control_settings", "reimbursement_attachments", "people", "member_ledger_entries", "registrations", "events",
            "event_fee_schedules", "event_participants", "event_closeouts", "event_closeout_allocations", "event_financial_entries", "cash_receipts", "reconciliations",
            "workbook_imports", "general_spreadsheet_imports", "scoutbook_imports", "calendar_subscriptions", "audit_log",
            "attachments_manifest", "families", "recurring_charge_batches", "recurring_charge_allocations",
        ]

        XCTAssertEqual(Set(archive.recordCounts.keys), expectedTables)
        XCTAssertEqual(archive.recordCounts.count, ModelContainerFactory.modelTypes.count + 1)
        XCTAssertEqual(archive.recordCounts["accounts"], 1)
        XCTAssertEqual(archive.recordCounts["troop_profile"], 1)
        XCTAssertEqual(archive.recordCounts["transactions"], 1)
        XCTAssertEqual(archive.recordCounts["people"], 1)
        XCTAssertEqual(archive.recordCounts["families"], 1)
        XCTAssertEqual(archive.recordCounts["calendar_subscriptions"], 1)
        XCTAssertEqual(archive.recordCounts["ledger_categories"], 1)
        XCTAssertEqual(archive.recordCounts["operating_budgets"], 1)
        XCTAssertEqual(archive.recordCounts["budget_lines"], 1)
        XCTAssertEqual(archive.recordCounts["attachments_manifest"], 0)
        XCTAssertEqual(Set(archive.files.keys), Set(expectedTables.map { "\($0).csv" } + ["backup.json", "README.txt"]))

        let jsonData = try XCTUnwrap(archive.files["backup.json"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, PlaintextBackupService.formatVersion)
        XCTAssertEqual(json["applicationVersion"] as? String, "0.10.0-test")
        let tables = try XCTUnwrap(json["tables"] as? [[String: Any]])
        XCTAssertEqual(Set(tables.compactMap { $0["name"] as? String }), expectedTables)

        let accountsCSV = try XCTUnwrap(String(data: XCTUnwrap(archive.files["accounts.csv"]), encoding: .utf8))
        XCTAssertTrue(accountsCSV.contains("\"Checking, \"\"Primary\"\"\""))
        let troopCSV = try XCTUnwrap(String(data: XCTUnwrap(archive.files["troop_profile.csv"]), encoding: .utf8))
        XCTAssertTrue(troopCSV.contains("Mayflower Troop,51,Mayflower Council"))
        let transactionsCSV = try XCTUnwrap(String(data: XCTUnwrap(archive.files["transactions.csv"]), encoding: .utf8))
        XCTAssertTrue(transactionsCSV.contains("\"Deposit, first installment\nReceipt retained\""))
        let subscriptionsCSV = try XCTUnwrap(String(data: XCTUnwrap(archive.files["calendar_subscriptions.csv"]), encoding: .utf8))
        XCTAssertTrue(subscriptionsCSV.contains("https://example.com/private-feed.ics?token=secret"))
        let budgetLinesCSV = try XCTUnwrap(String(data: XCTUnwrap(archive.files["budget_lines.csv"]), encoding: .utf8))
        XCTAssertTrue(budgetLinesCSV.contains("Camping,Expense,50000"))
        let peopleCSV = try XCTUnwrap(String(data: XCTUnwrap(archive.files["people.csv"]), encoding: .utf8))
        XCTAssertTrue(peopleCSV.contains(family.id.uuidString.lowercased()))
        let attachmentCSV = try XCTUnwrap(String(data: XCTUnwrap(archive.files["attachments_manifest.csv"]), encoding: .utf8))
        XCTAssertEqual(attachmentCSV, "attachment_id,record_type,record_id,relative_path,original_filename,media_type,byte_count,sha256,recorded_byte_count,recorded_sha256,integrity\r\n")

        let wrapper = PlaintextBackupDocument(files: archive.files).makeFileWrapper()
        XCTAssertTrue(wrapper.isDirectory)
        let wrapperFilenames: [String] = wrapper.fileWrappers.map { Array($0.keys) } ?? []
        XCTAssertEqual(Set(wrapperFilenames), Set(archive.files.keys))

    }

    @MainActor
    func testPlaintextBackupFilenameUsesExportDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 3)))

        XCTAssertEqual(
            PlaintextBackupService.defaultFilename(at: date, calendar: calendar),
            "TroopLedger Backup 2026-09-03.troopledgerbackup"
        )
    }

    func testMemberLedgerSeparatesChargesFromPaymentsAndCredits() throws {
        let personID = UUID()
        let charge = MemberLedgerEntry(personID: personID, date: Date(), kind: .charge, amountCents: 20_000, category: "Dues")
        let payment = MemberLedgerEntry(personID: personID, date: Date(), kind: .payment, amountCents: 15_000, category: "Dues")
        let credit = MemberLedgerEntry(personID: personID, date: Date(), kind: .credit, amountCents: 2_000, category: "Fundraising")

        XCTAssertEqual(FinanceEngine.memberBalance(personID: personID, entries: [charge, payment, credit]), 3_000)
    }

    func testAnnualReportGroupsCategories() throws {
        let calendar = Calendar(identifier: .gregorian)
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)))
        let dues1 = LedgerTransaction(accountID: nil, date: date, direction: .income, amountCents: 10_000, payee: "Family A", category: "Dues")
        let dues2 = LedgerTransaction(accountID: nil, date: date, direction: .income, amountCents: 5_000, payee: "Family B", category: "Dues")
        let camp = LedgerTransaction(accountID: nil, date: date, direction: .expense, amountCents: 8_000, payee: "Camp", category: "Camping")

        let report = FinanceEngine.annualReport(year: 2026, transactions: [dues1, dues2, camp], calendar: calendar)

        XCTAssertEqual(report.income, [CategoryTotal(category: "Dues", amountCents: 15_000)])
        XCTAssertEqual(report.expenses, [CategoryTotal(category: "Camping", amountCents: 8_000)])
        XCTAssertEqual(report.netCents, 7_000)
    }

    @MainActor
    func testCategoryCatalogSeedsStandardsAndExistingRegisterCategoriesOnce() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(LedgerTransaction(accountID: nil, date: Date(), direction: .expense, amountCents: 1_000, payee: "Hall", category: "Meeting Space"))
        context.insert(LedgerTransaction(accountID: nil, date: Date(), direction: .income, amountCents: 2_000, payee: "Family", category: "Dues"))
        try context.save()

        let inserted = try CategoryCatalog.seedMissingDefinitions(in: context)
        let insertedAgain = try CategoryCatalog.seedMissingDefinitions(in: context)
        let categories = try context.fetch(FetchDescriptor<LedgerCategoryRecord>())

        XCTAssertEqual(inserted, CategoryCatalog.standardCategories.count + 1)
        XCTAssertEqual(insertedAgain, 0)
        XCTAssertEqual(categories.filter { $0.name == "Dues" && $0.direction == .income }.count, 1)
        XCTAssertEqual(categories.filter { $0.name == "Meeting Space" && $0.direction == .expense }.count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AuditLogEntry>()), 1)
    }

    func testBudgetVarianceIncludesUnbudgetedActualsAndUsesFavorableSigns() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
        }
        let budgetID = UUID()
        let lines = [
            BudgetLineRecord(budgetID: budgetID, categoryID: nil, categoryName: "Dues", direction: .income, amountCents: 100_000),
            BudgetLineRecord(budgetID: budgetID, categoryID: nil, categoryName: "Camping", direction: .expense, amountCents: 60_000),
        ]
        let transactions = [
            LedgerTransaction(accountID: nil, date: try date(2025, 9, 1), direction: .income, amountCents: 110_000, payee: "Families", category: " dues "),
            LedgerTransaction(accountID: nil, date: try date(2026, 2, 1), direction: .expense, amountCents: 55_000, payee: "Camp", category: "Camping"),
            LedgerTransaction(accountID: nil, date: try date(2026, 3, 1), direction: .expense, amountCents: 2_000, payee: "Bank", category: "Bank Fees"),
            LedgerTransaction(accountID: nil, date: try date(2026, 9, 1), direction: .expense, amountCents: 99_000, payee: "Outside", category: "Camping"),
        ]
        let period = ReportingPeriod(basis: .schoolYear, startingYear: 2025, calendar: calendar)

        let report = BudgetEngine.varianceReport(period: period, transactions: transactions, budgetLines: lines)

        XCTAssertEqual(report.income.first { $0.categoryName == "Dues" }?.actualCents, 110_000)
        XCTAssertEqual(report.income.first { $0.categoryName == "Dues" }?.varianceCents, 10_000)
        XCTAssertEqual(report.expenses.first { $0.categoryName == "Camping" }?.varianceCents, 5_000)
        XCTAssertEqual(report.expenses.first { $0.categoryName == "Bank Fees" }?.budgetCents, 0)
        XCTAssertEqual(report.expenses.first { $0.categoryName == "Bank Fees" }?.varianceCents, -2_000)
        XCTAssertEqual(report.budgetNetCents, 40_000)
        XCTAssertEqual(report.actualNetCents, 53_000)
        XCTAssertEqual(report.netVarianceCents, 13_000)
    }

    func testSchoolYearRunsFromSeptemberThroughAugust() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let august31 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 8, day: 31, hour: 23, minute: 59)))
        let september1 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 9, day: 1)))
        let followingAugust31 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 23, minute: 59)))
        let followingSeptember1 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        let period = ReportingPeriod(basis: .schoolYear, startingYear: 2025, calendar: calendar)

        XCTAssertEqual(ReportingYearBasis.schoolYear.startingYear(containing: august31, calendar: calendar), 2024)
        XCTAssertEqual(ReportingYearBasis.schoolYear.startingYear(containing: september1, calendar: calendar), 2025)
        XCTAssertEqual(calendar.dateComponents([.month], from: period.startDate, to: period.endDateExclusive).month, 12)
        XCTAssertFalse(period.contains(august31))
        XCTAssertTrue(period.contains(september1))
        XCTAssertTrue(period.contains(followingAugust31))
        XCTAssertFalse(period.contains(followingSeptember1))
        XCTAssertEqual(period.label, "2025–2026 School Year")
        XCTAssertEqual(period.dateRangeLabel(calendar: calendar), "September 1, 2025 – August 31, 2026")
    }

    func testSchoolYearReportIncludesBothSidesOfCalendarYearBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
        }
        let before = LedgerTransaction(accountID: nil, date: try date(2025, 8, 31), direction: .income, amountCents: 99_000, payee: "Before", category: "Dues")
        let september = LedgerTransaction(accountID: nil, date: try date(2025, 9, 1), direction: .income, amountCents: 10_000, payee: "September dues", category: "Dues")
        let january = LedgerTransaction(accountID: nil, date: try date(2026, 1, 15), direction: .income, amountCents: 5_000, payee: "January dues", category: "Dues")
        let august = LedgerTransaction(accountID: nil, date: try date(2026, 8, 31), direction: .expense, amountCents: 8_000, payee: "Summer camp", category: "Camping")
        let after = LedgerTransaction(accountID: nil, date: try date(2026, 9, 1), direction: .expense, amountCents: 77_000, payee: "After", category: "Camping")
        let period = ReportingPeriod(basis: .schoolYear, startingYear: 2025, calendar: calendar)

        let report = FinanceEngine.annualReport(period: period, transactions: [before, september, january, august, after])

        XCTAssertEqual(report.income, [CategoryTotal(category: "Dues", amountCents: 15_000)])
        XCTAssertEqual(report.expenses, [CategoryTotal(category: "Camping", amountCents: 8_000)])
        XCTAssertEqual(report.netCents, 7_000)
    }

    func testMoneyParsingRoundsToCents() throws {
        XCTAssertEqual(Money.cents(from: "12.345"), 1_235)
        XCTAssertEqual(Money.cents(from: "0"), 0)
        XCTAssertNil(Money.cents(from: "not money"))
    }

    func testPersonActivityFilters() {
        let active = PersonRecord(firstName: "Active", lastName: "Member", role: .scout)
        let inactive = PersonRecord(firstName: "Inactive", lastName: "Member", role: .leader)
        inactive.isActive = false

        XCTAssertTrue(PersonActivityFilter.active.includes(active))
        XCTAssertFalse(PersonActivityFilter.active.includes(inactive))
        XCTAssertFalse(PersonActivityFilter.inactive.includes(active))
        XCTAssertTrue(PersonActivityFilter.inactive.includes(inactive))
        XCTAssertTrue(PersonActivityFilter.all.includes(active))
        XCTAssertTrue(PersonActivityFilter.all.includes(inactive))
    }

    func testPersonRoleFilters() {
        let scout = PersonRecord(firstName: "Sam", lastName: "Scout", role: .scout)
        let leader = PersonRecord(firstName: "Lee", lastName: "Leader", role: .leader)
        let parent = PersonRecord(firstName: "Pat", lastName: "Parent", role: .parent)
        let other = PersonRecord(firstName: "Otto", lastName: "Other", role: .other)

        XCTAssertTrue(PersonRoleFilter.scouts.includes(scout))
        XCTAssertFalse(PersonRoleFilter.scouts.includes(leader))
        XCTAssertTrue(PersonRoleFilter.leaders.includes(leader))
        XCTAssertFalse(PersonRoleFilter.leaders.includes(scout))
        XCTAssertTrue(PersonRoleFilter.parents.includes(parent))
        XCTAssertTrue(PersonRoleFilter.other.includes(other))
        XCTAssertTrue([scout, leader, parent, other].allSatisfy(PersonRoleFilter.all.includes))
    }

    func testScoutsBSARankLadderIsCompleteAndOrdered() {
        XCTAssertEqual(
            ScoutsBSARank.allCases.map(\.displayName),
            ["No rank recorded", "Scout", "Tenderfoot", "Second Class", "First Class", "Star", "Life", "Eagle"]
        )
        XCTAssertEqual(ScoutsBSARank.matching("First Class"), .firstClass)
    }

    func testTroopPositionCatalogIncludesYouthAndAdultRoles() {
        let youth = TroopPosition.allCases.filter { $0.category == .youth }
        let adult = TroopPosition.allCases.filter { $0.category == .adult }

        XCTAssertEqual(youth.count, 17)
        XCTAssertEqual(adult.count, 13)
        XCTAssertTrue(youth.contains(.assistantPatrolLeader))
        XCTAssertTrue(youth.contains(.orderOfTheArrowRepresentative))
        XCTAssertTrue(adult.contains(.scoutmaster))
        XCTAssertTrue(adult.contains(.treasurer))
        XCTAssertFalse(TroopPosition.assistantPatrolLeader.fulfillsYouthPositionOfResponsibility)
        XCTAssertFalse(TroopPosition.bugler.fulfillsYouthPositionOfResponsibility)
        XCTAssertTrue(TroopPosition.quartermaster.fulfillsYouthPositionOfResponsibility)
    }

    func testPersonStoresRankAndMultiplePositions() {
        let person = PersonRecord(firstName: "Alex", lastName: "Smith", role: .scout)
        person.currentRank = .star
        person.troopPositions = [.quartermaster, .patrolLeader, .quartermaster]
        person.customPosition = "Green Bar Historian"

        XCTAssertEqual(person.currentRank, .star)
        XCTAssertEqual(Set(person.troopPositions), [.quartermaster, .patrolLeader])
        XCTAssertTrue(person.positionSummary.contains("Patrol Leader"))
        XCTAssertTrue(person.positionSummary.contains("Green Bar Historian"))
    }

    @MainActor
    func testBundledWorkbookSnapshotImportsOnceAndReconcilesChecking() throws {
        let snapshot = try SpreadsheetImporter.loadBundledSnapshot()
        XCTAssertEqual(snapshot.sourceFingerprint, "bcfb2f06f74e722b407bd28a4a3cdd298cfe28526a96fdbd3c45bb2983ae5057")
        XCTAssertEqual(snapshot.totalRecordCount, 649)
        XCTAssertTrue(snapshot.checks.checkingBalanceMatches)
        XCTAssertTrue(snapshot.checks.issues.isEmpty)

        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let importRecord = try SpreadsheetImporter.importSnapshot(snapshot, into: context)

        XCTAssertEqual(importRecord.transactionCount, 228)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CashReceiptRecord>()), 26)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersonRecord>()), 34)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RegistrationRecord>()), 97)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EventRecord>()), 24)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EventFinancialEntry>()), 212)

        let account = try XCTUnwrap(context.fetch(FetchDescriptor<AccountRecord>()).first)
        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())
        XCTAssertEqual(FinanceEngine.bookBalance(account: account, transactions: transactions), 83_638)
        let auditEntries = try context.fetch(FetchDescriptor<AuditLogEntry>())
        XCTAssertEqual(auditEntries.count, 1)
        XCTAssertEqual(auditEntries.first?.action, .importData)
        XCTAssertEqual(auditEntries.first?.recordID, importRecord.id)

        XCTAssertThrowsError(try SpreadsheetImporter.importSnapshot(snapshot, into: context)) { error in
            XCTAssertEqual(error as? SpreadsheetImportError, .alreadyImported)
        }
    }

    func testScoutbookCSVParserHandlesQuotedCommasAndNewlines() throws {
        let csv = """
        BSA Member ID,First Name,Last Name,Member Type,Notes
        12345,Alex,Smith,Scout,"Needs review, then follow up"
        67890,Jamie,Jones,Scout,"Line one
        Line two"
        """
        let document = try ScoutbookImporter.parse(data: Data(csv.utf8), sourceName: "Scouts-Members.csv")
        let preview = ScoutbookImporter.preview(document: document, kind: .members)

        XCTAssertEqual(document.detectedKind, .members)
        XCTAssertEqual(document.rows.count, 2)
        XCTAssertEqual(document.rows[0].value(["Notes"]), "Needs review, then follow up")
        XCTAssertEqual(document.rows[1].value(["Notes"]), "Line one\nLine two")
        XCTAssertEqual(preview.validRowCount, 2)
        XCTAssertTrue(preview.issues.isEmpty)
    }

    func testGeneralSpreadsheetMappingParsesQuotedRowsAndPreviewsAmounts() throws {
        let csv = """
        Date,Type,Amount,Payee,Category,Memo,Reference,Cleared
        9/2/2026,Income,"$125.50","Families, Inc",Dues,"Line one
        Line two",DEP-1,yes
        9/3/2026,Expense,(25.00),Council,Registration,Annual fee,104,no
        """
        let document = try GeneralSpreadsheetImporter.parse(data: Data(csv.utf8), sourceName: "register.csv")
        let mapping = TransactionColumnMapping.detected(from: document.headers)
        let accountID = UUID()
        let preview = GeneralSpreadsheetImporter.preview(
            document: document,
            mapping: mapping,
            accountID: accountID,
            defaultDirection: .expense,
            defaultCategory: "Uncategorized",
            reconciliations: []
        )

        XCTAssertEqual(document.rows.count, 2)
        XCTAssertEqual(document.rows[0].value(at: mapping[.payee]), "Families, Inc")
        XCTAssertEqual(document.rows[0].value(at: mapping[.memo]), "Line one\nLine two")
        XCTAssertTrue(preview.mappingIssues.isEmpty)
        XCTAssertEqual(preview.validRows.count, 2)
        XCTAssertTrue(preview.invalidRows.isEmpty)
        XCTAssertEqual(preview.totalIncomeCents, 12_550)
        XCTAssertEqual(preview.totalExpenseCents, 2_500)
        XCTAssertEqual(preview.validRows[0].draft?.reference, "DEP-1")
        XCTAssertEqual(preview.validRows[0].draft?.isCleared, true)
    }

    @MainActor
    func testGeneralSpreadsheetImportSkipsReviewedExceptionsAndProtectsFingerprint() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let account = AccountRecord(name: "Checking")
        context.insert(account)
        let lockDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 31)))
        let reconciliation = ReconciliationRecord(accountID: account.id, statementDate: lockDate, statementEndingBalanceCents: 0, clearedBalanceCents: 0)
        context.insert(reconciliation)
        try context.save()

        let csv = """
        Transaction Date,Direction,Amount,Payee,Category
        8/31/2026,Expense,10.00,Locked Vendor,Supplies
        9/1/2026,Income,100.00,Family,Dues
        not-a-date,Expense,5.00,Bad Row,Supplies
        """
        let document = try GeneralSpreadsheetImporter.parse(data: Data(csv.utf8), sourceName: "future-register.tsv")
        let mapping = TransactionColumnMapping.detected(from: document.headers)
        let preview = GeneralSpreadsheetImporter.preview(
            document: document,
            mapping: mapping,
            accountID: account.id,
            defaultDirection: .expense,
            defaultCategory: "Uncategorized",
            reconciliations: [reconciliation],
            calendar: calendar
        )

        XCTAssertEqual(preview.validRows.count, 1)
        XCTAssertEqual(preview.invalidRows.count, 2)
        XCTAssertTrue(preview.invalidRows.flatMap(\.issues).contains { $0.contains("locked period") })
        XCTAssertThrowsError(
            try GeneralSpreadsheetImporter.importDocument(
                document,
                mapping: mapping,
                accountID: account.id,
                defaultDirection: .expense,
                defaultCategory: "Uncategorized",
                reconciliations: [reconciliation],
                skipExceptions: false,
                calendar: calendar,
                into: context
            )
        ) { error in
            XCTAssertEqual(error as? GeneralSpreadsheetImportError, .unresolvedExceptions)
        }

        let result = try GeneralSpreadsheetImporter.importDocument(
            document,
            mapping: mapping,
            accountID: account.id,
            defaultDirection: .expense,
            defaultCategory: "Uncategorized",
            reconciliations: [reconciliation],
            skipExceptions: true,
            calendar: calendar,
            into: context
        )
        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())
        let history = try XCTUnwrap(context.fetch(FetchDescriptor<GeneralSpreadsheetImportRecord>()).first)

        XCTAssertEqual(result, GeneralSpreadsheetImportResult(inserted: 1, skipped: 2))
        XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(transactions.first?.payee, "Family")
        XCTAssertEqual(transactions.first?.sourceSheet, "future-register.tsv")
        XCTAssertEqual(transactions.first?.sourceRow, 3)
        XCTAssertEqual(history.importedCount, 1)
        XCTAssertEqual(history.skippedCount, 2)
        XCTAssertTrue(history.exceptionNotes.contains("Row 2"))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AuditLogEntry>()), 1)
        XCTAssertThrowsError(
            try GeneralSpreadsheetImporter.importDocument(
                document,
                mapping: mapping,
                accountID: account.id,
                defaultDirection: .expense,
                defaultCategory: "Uncategorized",
                reconciliations: [reconciliation],
                skipExceptions: true,
                calendar: calendar,
                into: context
            )
        ) { error in
            XCTAssertEqual(error as? GeneralSpreadsheetImportError, .alreadyImported)
        }
    }

    @MainActor
    func testReimbursementApprovalCreatesOneUnlockedLinkedExpense() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let account = AccountRecord(name: "Checking")
        let requester = PersonRecord(firstName: "Pat", lastName: "Leader", role: .leader)
        let request = ReimbursementRequest(
            requesterPersonID: requester.id,
            purchaseDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20))),
            purpose: "Camp stove fuel",
            category: "Camping Supplies",
            amountCents: 4_250
        )
        let lockDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 31)))
        let lock = ReconciliationRecord(accountID: account.id, statementDate: lockDate, statementEndingBalanceCents: 0, clearedBalanceCents: 0)
        context.insert(account)
        context.insert(requester)
        context.insert(request)
        context.insert(lock)
        try context.save()

        try ReimbursementService.review(
            request,
            approve: true,
            reviewerName: "Treasurer",
            notes: "Receipt reviewed",
            in: context
        )
        XCTAssertEqual(request.status, .approved)
        XCTAssertThrowsError(
            try ReimbursementService.createAndLinkPayment(
                for: request,
                accountID: account.id,
                paymentDate: lockDate,
                reference: "1001",
                payee: requester.displayName,
                reconciliations: [lock],
                calendar: calendar,
                in: context
            )
        ) { error in
            guard case .paymentDateLocked = error as? ReimbursementError else {
                return XCTFail("Expected locked payment date, got \(error)")
            }
        }

        let paymentDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        let transaction = try ReimbursementService.createAndLinkPayment(
            for: request,
            accountID: account.id,
            paymentDate: paymentDate,
            reference: "1001",
            payee: requester.displayName,
            reconciliations: [lock],
            calendar: calendar,
            in: context
        )

        XCTAssertEqual(request.status, .paid)
        XCTAssertEqual(request.linkedTransactionID, transaction.id)
        XCTAssertEqual(transaction.direction, .expense)
        XCTAssertEqual(transaction.amountCents, 4_250)
        XCTAssertEqual(transaction.personID, requester.id)
        XCTAssertEqual(transaction.memo, "Reimbursement: Camp stove fuel")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 1)
        XCTAssertThrowsError(
            try ReimbursementService.createAndLinkPayment(
                for: request,
                accountID: account.id,
                paymentDate: paymentDate,
                reference: "1002",
                payee: requester.displayName,
                reconciliations: [lock],
                calendar: calendar,
                in: context
            )
        ) { error in
            XCTAssertEqual(error as? ReimbursementError, .requestNotApproved)
        }
    }

    @MainActor
    func testReimbursementReceiptIsFingerprintProtectedAndIncludedInBackup() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let requester = PersonRecord(firstName: "Alex", lastName: "Adult", role: .leader)
        let request = ReimbursementRequest(
            requesterPersonID: requester.id,
            purchaseDate: Date(timeIntervalSince1970: 1_787_558_400),
            purpose: "Program supplies",
            category: "Program Supplies",
            amountCents: 1_299
        )
        context.insert(requester)
        context.insert(request)
        try context.save()
        let receiptData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])

        let attachment = try ReimbursementService.addAttachment(
            to: request,
            data: receiptData,
            filename: "Store / Receipt.png",
            mediaType: "image/png",
            in: context
        )
        XCTAssertEqual(attachment.filename, "Receipt.png")
        XCTAssertThrowsError(
            try ReimbursementService.addAttachment(
                to: request,
                data: receiptData,
                filename: "copy.png",
                mediaType: "image/png",
                in: context
            )
        ) { error in
            XCTAssertEqual(error as? ReimbursementError, .duplicateReceipt)
        }

        let archive = try PlaintextBackupService.makeArchive(
            from: context,
            exportedAt: Date(timeIntervalSince1970: 1_787_558_400),
            applicationVersion: "0.11.0-test"
        )
        let attachmentPath = try XCTUnwrap(archive.files.keys.first { $0.hasPrefix("attachments/") })
        XCTAssertEqual(archive.files[attachmentPath], receiptData)
        XCTAssertEqual(archive.recordCounts["reimbursement_requests"], 1)
        XCTAssertEqual(archive.recordCounts["reimbursement_attachments"], 1)
        XCTAssertEqual(archive.recordCounts["attachments_manifest"], 1)
        let manifest = try XCTUnwrap(String(data: XCTUnwrap(archive.files["attachments_manifest.csv"]), encoding: .utf8))
        XCTAssertTrue(manifest.contains(attachmentPath))
        XCTAssertTrue(manifest.contains(attachment.sha256))

        let wrapper = PlaintextBackupDocument(files: archive.files).makeFileWrapper()
        let attachmentDirectory = wrapper.fileWrappers?.values.first { $0.preferredFilename == "attachments" }
        XCTAssertEqual(attachmentDirectory?.isDirectory, true)
    }

    func testDisbursementControlWarningsAreConfigurable() {
        let approverID = UUID()
        let signerID = UUID()
        let assessment = DisbursementControlEvaluator.assess(
            approver: .init(personID: approverID, name: "Alex Adult", household: "North"),
            signerOne: .init(personID: approverID, name: "Alex Adult", household: "North"),
            signerTwo: .init(personID: signerID, name: "Morgan Adult", household: "North"),
            policy: DisbursementControlPolicy()
        )

        XCTAssertTrue(assessment.warnings.contains { $0.contains("same person") })
        XCTAssertTrue(assessment.warnings.contains { $0.contains("same household") })
        XCTAssertFalse(assessment.warnings.contains { $0.contains("expects") })

        let disabled = DisbursementControlEvaluator.assess(
            approver: .empty,
            signerOne: .empty,
            signerTwo: .empty,
            policy: DisbursementControlPolicy(
                expectApprover: false,
                expectedSignerCount: 0,
                warnSamePerson: false,
                warnSameHousehold: false,
                warnMissingHousehold: false
            )
        )
        XCTAssertEqual(disabled.warnings, [])
    }

    func testDisabledDisbursementControlsSuppressWarningsWithoutErasingEvidence() {
        let request = ReimbursementRequest(
            requesterPersonID: UUID(),
            purchaseDate: Date(),
            purpose: "Supplies",
            category: "Program Supplies",
            amountCents: 1_000
        )
        request.approverNameSnapshot = "Historical Approver"
        request.approverHouseholdSnapshot = "Recorded household"

        let assessment = DisbursementControlEvaluator.assess(
            approver: request.controlIdentity(for: .approver),
            signerOne: .empty,
            signerTwo: .empty,
            policy: DisbursementControlPolicy(isEnabled: false)
        )

        XCTAssertEqual(assessment.warnings, [])
        XCTAssertEqual(request.approverNameSnapshot, "Historical Approver")
        XCTAssertEqual(request.approverHouseholdSnapshot, "Recorded household")
    }

    @MainActor
    func testDisbursementEvidenceIsHistoricalAuditedAndBackedUp() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let approver = PersonRecord(firstName: "Avery", lastName: "Approver", role: .leader)
        let signer = PersonRecord(firstName: "Casey", lastName: "Signer", role: .parent)
        let request = ReimbursementRequest(
            requesterPersonID: signer.id,
            purchaseDate: Date(timeIntervalSince1970: 1_787_558_400),
            purpose: "Training materials",
            category: "Program Supplies",
            amountCents: 2_500
        )
        let settings = DisbursementControlSettings()
        settings.isEnabled = true
        settings.expectedSignerCount = 1
        context.insert(approver)
        context.insert(signer)
        context.insert(request)
        context.insert(settings)
        try context.save()

        try ReimbursementService.review(
            request,
            approve: true,
            reviewerName: approver.displayName,
            notes: "Receipt verified",
            approver: .init(personID: approver.id, name: approver.displayName, household: "A household"),
            in: context
        )
        try ReimbursementService.saveDisbursementControls(
            for: request,
            approver: request.controlIdentity(for: .approver),
            signerOne: .init(personID: signer.id, name: signer.displayName, household: "B household"),
            signerTwo: .empty,
            notes: "Check signed in person",
            in: context
        )
        let savedApproverName = request.approverNameSnapshot
        approver.firstName = "Changed"
        try context.save()

        XCTAssertEqual(request.approverNameSnapshot, savedApproverName)
        XCTAssertFalse(
            ReimbursementService.assessment(
                for: request,
                policy: DisbursementControlPolicy(settings: settings)
            ).hasWarnings
        )
        XCTAssertGreaterThanOrEqual(try context.fetchCount(FetchDescriptor<AuditLogEntry>()), 2)

        let archive = try PlaintextBackupService.makeArchive(from: context, applicationVersion: "0.12.0-test")
        XCTAssertEqual(archive.recordCounts["disbursement_control_settings"], 1)
        let settingsCSV = try XCTUnwrap(String(data: XCTUnwrap(archive.files["disbursement_control_settings.csv"]), encoding: .utf8))
        XCTAssertTrue(settingsCSV.contains("is_enabled"))
        let requestsCSV = try XCTUnwrap(String(data: XCTUnwrap(archive.files["reimbursement_requests.csv"]), encoding: .utf8))
        XCTAssertTrue(requestsCSV.contains("approver_name_snapshot"))
        XCTAssertTrue(requestsCSV.contains(savedApproverName))
        XCTAssertTrue(requestsCSV.contains("Check signed in person"))
    }

    func testReimbursementApprovalReportClassifiesWorkflowExceptionsAndAuditHistory() throws {
        let person = PersonRecord(firstName: "Jamie", lastName: "Requester", role: .leader)
        let submitted = ReimbursementRequest(
            requesterPersonID: person.id,
            purchaseDate: Date(timeIntervalSince1970: 1_787_558_400),
            purpose: "Awaiting, approval",
            category: "Program Supplies",
            amountCents: 1_500
        )
        let approved = ReimbursementRequest(
            requesterPersonID: person.id,
            purchaseDate: Date(timeIntervalSince1970: 1_787_558_400),
            purpose: "Approved request",
            category: "Program Supplies",
            amountCents: 2_500
        )
        approved.status = .approved
        approved.reviewerName = "Treasurer"
        approved.reviewedAt = Date(timeIntervalSince1970: 1_787_644_800)
        let receipt = ReimbursementAttachment(
            requestID: approved.id,
            filename: "receipt.pdf",
            mediaType: "application/pdf",
            byteCount: 1,
            sha256: "abc",
            data: Data([1])
        )
        let audit = AuditLogEntry(
            action: .edit,
            recordType: "Reimbursement Request",
            recordID: approved.id,
            summary: "Approved reimbursement request",
            deviceName: "Test",
            operatingSystem: "Test",
            userIdentity: "Tester"
        )

        let report = ReimbursementApprovalReportService.makeReport(
            requests: [submitted, approved],
            attachments: [receipt],
            transactions: [],
            people: [person],
            auditEntries: [audit],
            policy: DisbursementControlPolicy(isEnabled: false),
            generatedAt: Date(timeIntervalSince1970: 1_787_731_200)
        )

        let submittedRow = try XCTUnwrap(report.rows.first { $0.requestID == submitted.id })
        XCTAssertEqual(Set(submittedRow.issues.map(\.kind)), [.receipt, .approval])
        let approvedRow = try XCTUnwrap(report.rows.first { $0.requestID == approved.id })
        XCTAssertEqual(approvedRow.issues.map(\.kind), [.transaction])
        XCTAssertEqual(approvedRow.auditEntryCount, 1)
        XCTAssertEqual(report.exceptionRows.count, 2)

        let csv = ReimbursementApprovalReportService.csv(for: report)
        XCTAssertTrue(csv.contains("exception_details"))
        XCTAssertTrue(csv.contains("audit_entry_count"))
        XCTAssertTrue(csv.contains("\"Awaiting, approval\""))
        XCTAssertTrue(csv.contains("Approved request has no linked payment transaction."))
    }

    func testReimbursementApprovalReportAppliesEnabledSignerPolicyAndValidatesPaymentLink() throws {
        let request = ReimbursementRequest(
            requesterPersonID: UUID(),
            purchaseDate: Date(),
            purpose: "Paid supplies",
            category: "Program Supplies",
            amountCents: 3_000
        )
        request.status = .paid
        request.reviewerName = "Reviewer"
        request.reviewedAt = Date()
        let transaction = LedgerTransaction(
            accountID: UUID(),
            date: Date(),
            direction: .expense,
            amountCents: 3_000,
            payee: "Requester",
            category: "Program Supplies"
        )
        request.linkedTransactionID = transaction.id
        let receipt = ReimbursementAttachment(
            requestID: request.id,
            filename: "receipt.jpg",
            mediaType: "image/jpeg",
            byteCount: 1,
            sha256: "def",
            data: Data([2])
        )

        let report = ReimbursementApprovalReportService.makeReport(
            requests: [request],
            attachments: [receipt],
            transactions: [transaction],
            people: [],
            auditEntries: [],
            policy: DisbursementControlPolicy(expectedSignerCount: 2)
        )
        let row = try XCTUnwrap(report.rows.first)

        XCTAssertTrue(row.issues.contains { $0.kind == .approval && $0.message.contains("approver") })
        XCTAssertTrue(row.issues.contains { $0.kind == .signer && $0.message.contains("expects 2 signers") })
        XCTAssertFalse(row.issues.contains { $0.kind == .transaction })
        XCTAssertEqual(report.exceptionCount(for: .signer), 1)
    }

    @MainActor
    func testScoutbookRosterAndPaymentLogImportWithDuplicateProtection() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let rosterCSV = """
        BSA Member ID,First Name,Last Name,Member Type,Patrol,Rank,Position,Status,Expiration Date
        12345,Alex,Smith,Scout,Eagles,First Class,Patrol Leader,Current,12/31/2026
        67890,Taylor,Jones,Adult,,,Treasurer,Current,12/31/2026
        """
        let roster = try ScoutbookImporter.parse(data: Data(rosterCSV.utf8), sourceName: "Scouts-Members.csv")
        let rosterResult = try ScoutbookImporter.importDocument(roster, kind: .members, into: context)
        XCTAssertEqual(rosterResult.inserted, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersonRecord>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RegistrationRecord>()), 2)

        let paymentCSV = """
        Transaction Date,Member ID,Name,Transaction Type,Amount,Category,Description
        8/1/2026,12345,"Smith, Alex",Charge,-25.00,Camping,Summer camp fee
        8/5/2026,12345,"Smith, Alex",Payment Received,10.00,Camping,Partial payment
        """
        let payments = try ScoutbookImporter.parse(data: Data(paymentCSV.utf8), sourceName: "Payment-Log.csv")
        let paymentResult = try ScoutbookImporter.importDocument(payments, kind: .paymentLog, into: context)
        XCTAssertEqual(paymentResult.inserted, 2)

        let person = try XCTUnwrap(context.fetch(FetchDescriptor<PersonRecord>()).first { $0.scoutingMemberID == "12345" })
        XCTAssertEqual(person.role, .scout)
        XCTAssertEqual(person.currentRank, .firstClass)
        XCTAssertEqual(person.troopPositions, [.patrolLeader])
        let treasurer = try XCTUnwrap(context.fetch(FetchDescriptor<PersonRecord>()).first { $0.scoutingMemberID == "67890" })
        XCTAssertEqual(treasurer.role, .leader)
        XCTAssertEqual(treasurer.troopPositions, [.treasurer])
        let entries = try context.fetch(FetchDescriptor<MemberLedgerEntry>())
        XCTAssertEqual(FinanceEngine.memberBalance(personID: person.id, entries: entries), 1_500)
        XCTAssertThrowsError(try ScoutbookImporter.importDocument(payments, kind: .paymentLog, into: context)) { error in
            XCTAssertEqual(error as? ScoutbookImportError, .alreadyImported)
        }
    }

    func testScoutbookCalendarParserHandlesAllDayTimedAndRecurringEvents() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:camp-1
        DTSTART;VALUE=DATE:20260912
        DTEND;VALUE=DATE:20260914
        SUMMARY:Fall Campout
        LOCATION:Camp Green
        DESCRIPTION:Bring a tent\\nand rain gear
        END:VEVENT
        BEGIN:VEVENT
        UID:meeting-1
        DTSTART:20260915T190000
        DTEND:20260915T203000
        RRULE:FREQ=WEEKLY;COUNT=3
        SUMMARY:Troop Meeting
        END:VEVENT
        END:VCALENDAR
        """
        let events = try ScoutbookCalendarService.parse(data: Data(ics.utf8))

        XCTAssertEqual(events.count, 4)
        let camp = try XCTUnwrap(events.first { $0.externalID == "camp-1" })
        XCTAssertTrue(camp.isAllDay)
        XCTAssertEqual(camp.notes, "Bring a tent\nand rain gear")
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: camp.startDate, to: camp.endDate).day, 1)
        XCTAssertEqual(events.filter { $0.title == "Troop Meeting" }.count, 3)
    }

    func testEventRosterGroupsScoutsBeforeAdultsAndRendersPDF() throws {
        let troopProfile = TroopProfileRecord()
        troopProfile.troopName = "Mayflower Troop"
        troopProfile.troopNumber = "51"
        troopProfile.council = "Mayflower Council"
        let event = EventRecord(name: "Fall Campout", startDate: Date(timeIntervalSince1970: 1_788_825_600), endDate: Date(timeIntervalSince1970: 1_788_912_000))
        event.location = "Camp Green"
        event.address = "123 Camp Road, Greenfield, MA"
        event.classification = .district
        event.coordinator = "Morgan Leader"
        event.isAllDay = true

        let leader = PersonRecord(firstName: "Morgan", lastName: "Leader", role: .leader)
        leader.troopPositions = [.scoutmaster]
        let scoutB = PersonRecord(firstName: "Taylor", lastName: "Zulu", role: .scout)
        scoutB.patrol = "Eagles"
        let scoutA = PersonRecord(firstName: "Alex", lastName: "Able", role: .scout)
        scoutA.patrol = "Foxes"

        let leaderParticipant = EventParticipant(eventID: event.id, personID: leader.id, status: .registered)
        let scoutBParticipant = EventParticipant(eventID: event.id, personID: scoutB.id, status: .waitlisted)
        let scoutAParticipant = EventParticipant(eventID: event.id, personID: scoutA.id, status: .attended)
        scoutAParticipant.transportation = "Van 1"
        let guestParticipant = EventParticipant(eventID: event.id, personID: nil, status: .registered)
        guestParticipant.guestName = "Casey Guest"

        let roster = EventRosterSnapshot(
            event: event,
            participants: [leaderParticipant, scoutBParticipant, scoutAParticipant, guestParticipant],
            people: [leader, scoutB, scoutA],
            troopProfile: troopProfile
        )

        XCTAssertEqual(roster.troop.formalName, "Mayflower Troop • Troop 51")
        XCTAssertEqual(roster.rows.map(\.name), ["Alex Able", "Taylor Zulu", "Morgan Leader", "Casey Guest"])
        XCTAssertEqual(roster.scoutCount, 2)
        XCTAssertEqual(roster.adultCount, 1)
        XCTAssertEqual(roster.rows.first?.transportation, "Van 1")
        XCTAssertEqual(roster.rows.last?.group, "Guest")
        XCTAssertEqual(roster.classification, "District Event")
        XCTAssertEqual(roster.location, "Camp Green, 123 Camp Road, Greenfield, MA")

        let pdf = try XCTUnwrap(EventRosterPDFRenderer.render(roster))
        XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
        XCTAssertGreaterThan(pdf.count, 1_000)
    }

    @MainActor
    func testReviewedFixedDuesBatchPostsTraceableChargesAndRejectsDuplicate() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let scout = PersonRecord(firstName: "Alex", lastName: "Able", role: .scout)
        let sibling = PersonRecord(firstName: "Taylor", lastName: "Able", role: .scout)
        context.insert(scout)
        context.insert(sibling)
        try context.save()
        let date = Date(timeIntervalSince1970: 1_788_825_600)
        let draft = RecurringChargeBatchDraft(
            name: "September Dues",
            kind: .dues,
            chargeDate: date,
            category: "Dues",
            fixedAmountCents: 2_500,
            programYear: "",
            notes: "Approved monthly dues",
            selectedPersonIDs: [scout.id, sibling.id]
        )

        let proposal = try RecurringChargeBatchService.preview(
            draft: draft,
            people: [scout, sibling],
            registrations: [],
            existingAllocations: []
        )
        XCTAssertEqual(proposal.rows.map(\.personName), ["Alex Able", "Taylor Able"])
        XCTAssertEqual(proposal.totalCents, 5_000)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MemberLedgerEntry>()), 0)

        let batch = try RecurringChargeBatchService.post(draft: draft, in: context)
        let entries = try context.fetch(FetchDescriptor<MemberLedgerEntry>())
        let allocations = try context.fetch(FetchDescriptor<RecurringChargeAllocationRecord>())
        XCTAssertEqual(batch.totalCents, 5_000)
        XCTAssertEqual(batch.allocationCount, 2)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.kind == .charge && $0.chargeBatchID == batch.id })
        XCTAssertTrue(entries.allSatisfy { $0.sourceSystem == "TroopLedger Charge Batch" })
        XCTAssertEqual(allocations.count, 2)
        XCTAssertEqual(Set(allocations.compactMap(\.memberEntryID)), Set(entries.map(\.id)))
        XCTAssertEqual(FinanceEngine.memberBalance(personID: scout.id, entries: entries), 2_500)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AuditLogEntry>()), 1)

        XCTAssertThrowsError(try RecurringChargeBatchService.post(draft: draft, in: context)) { error in
            XCTAssertEqual(error as? RecurringChargeBatchError, .duplicateCharge("Alex Able"))
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecurringChargeBatchRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MemberLedgerEntry>()), 2)

        let archive = try PlaintextBackupService.makeArchive(from: context, applicationVersion: "0.17.0-test")
        let entriesCSV = try XCTUnwrap(String(data: XCTUnwrap(archive.files["member_ledger_entries.csv"]), encoding: .utf8))
        XCTAssertTrue(entriesCSV.contains(batch.id.uuidString.lowercased()))
        XCTAssertEqual(archive.recordCounts["recurring_charge_batches"], 1)
        XCTAssertEqual(archive.recordCounts["recurring_charge_allocations"], 2)
    }

    @MainActor
    func testRegistrationBatchUsesPreferredAssessedDuesAndRequiresEveryAssessment() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let scout = PersonRecord(firstName: "Alex", lastName: "Able", role: .scout)
        let leader = PersonRecord(firstName: "Morgan", lastName: "Leader", role: .leader)
        context.insert(scout)
        context.insert(leader)
        let older = RegistrationRecord(personID: scout.id, programYear: "2026-2027", unitRole: "Scout", status: .pending)
        older.duesAssessedCents = 5_000
        older.registeredOn = Date(timeIntervalSince1970: 1_780_000_000)
        let current = RegistrationRecord(personID: scout.id, programYear: "2026-2027", unitRole: "Scout", status: .current)
        current.duesAssessedCents = 6_500
        current.registeredOn = Date(timeIntervalSince1970: 1_770_000_000)
        let leaderRegistration = RegistrationRecord(personID: leader.id, programYear: "2026-2027", unitRole: "Committee", status: .current)
        leaderRegistration.duesAssessedCents = 7_200
        context.insert(older)
        context.insert(current)
        context.insert(leaderRegistration)
        try context.save()

        let date = Date(timeIntervalSince1970: 1_788_825_600)
        let draft = RecurringChargeBatchDraft(
            name: "2026 Recharter",
            kind: .registration,
            chargeDate: date,
            category: "Registration",
            fixedAmountCents: nil,
            programYear: "2026-2027",
            notes: "",
            selectedPersonIDs: [scout.id, leader.id]
        )
        let batch = try RecurringChargeBatchService.post(draft: draft, in: context)
        let entries = try context.fetch(FetchDescriptor<MemberLedgerEntry>())
        let allocations = try context.fetch(FetchDescriptor<RecurringChargeAllocationRecord>())
        XCTAssertEqual(batch.totalCents, 13_700)
        XCTAssertEqual(Set(entries.map(\.amountCents)), Set<Int64>([6_500, 7_200]))
        XCTAssertTrue(allocations.contains { $0.personID == scout.id && $0.registrationID == current.id })
        XCTAssertFalse(allocations.contains { $0.registrationID == older.id })

        let unassessed = PersonRecord(firstName: "Casey", lastName: "Missing", role: .scout)
        let invalidDraft = RecurringChargeBatchDraft(
            name: "Missing Assessment",
            kind: .registration,
            chargeDate: date,
            category: "Registration",
            fixedAmountCents: nil,
            programYear: "2026-2027",
            notes: "",
            selectedPersonIDs: [unassessed.id]
        )
        XCTAssertThrowsError(try RecurringChargeBatchService.preview(
            draft: invalidDraft,
            people: [unassessed],
            registrations: [older, current, leaderRegistration],
            existingAllocations: []
        )) { error in
            XCTAssertEqual(error as? RecurringChargeBatchError, .missingRegistrationAssessments(["Casey Missing"]))
        }
    }

    func testFamilyStatementCalculatesActivityCurrentBalanceAndUpcomingCharges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
        }

        let family = FamilyRecord(name: "Able Family")
        let troopProfile = TroopProfileRecord()
        troopProfile.troopName = "Mayflower Troop"
        troopProfile.troopNumber = "51"
        troopProfile.council = "Mayflower Council"
        troopProfile.addressLine1 = "123 Main Street"
        troopProfile.city = "Plymouth"
        troopProfile.stateOrProvince = "MA"
        troopProfile.postalCode = "02360"
        troopProfile.treasurerName = "Dominic Bettinelli"
        troopProfile.treasurerPreferredName = "Dom"
        let scout = PersonRecord(firstName: "Alex", lastName: "Able", role: .scout)
        let guardian = PersonRecord(firstName: "Jordan", lastName: "Able", role: .parent)
        scout.familyID = family.id
        guardian.familyID = family.id
        let other = PersonRecord(firstName: "Other", lastName: "Family", role: .scout)
        let event = EventRecord(name: "Fall Campout", startDate: try date(2026, 10, 10), endDate: try date(2026, 10, 11))

        func entry(_ person: PersonRecord, _ date: Date, _ kind: MemberEntryKind, _ cents: Int64, _ category: String) -> MemberLedgerEntry {
            MemberLedgerEntry(personID: person.id, date: date, kind: kind, amountCents: cents, category: category)
        }
        let opening = entry(scout, try date(2026, 8, 20), .charge, 10_000, "Prior dues")
        let charge = entry(scout, try date(2026, 9, 5), .charge, 5_000, "Camp fee")
        charge.eventID = event.id
        let payment = entry(guardian, try date(2026, 9, 8), .payment, 2_000, "Payment")
        let credit = entry(scout, try date(2026, 9, 10), .credit, 500, "Fundraising credit")
        let increase = entry(scout, try date(2026, 9, 12), .adjustmentIncrease, 1_000, "Correction")
        let decrease = entry(scout, try date(2026, 9, 13), .adjustmentDecrease, 300, "Correction")
        let upcoming = entry(scout, try date(2026, 10, 1), .charge, 4_000, "October dues")
        let unrelated = entry(other, try date(2026, 9, 6), .charge, 99_000, "Other family")

        let snapshot = try FamilyStatementService.makeSnapshot(
            family: family,
            people: [scout, guardian, other],
            entries: [opening, charge, payment, credit, increase, decrease, upcoming, unrelated],
            events: [event],
            periodStart: try date(2026, 9, 1),
            asOfDate: try date(2026, 9, 30),
            troopProfile: troopProfile,
            generatedAt: try date(2026, 9, 30),
            calendar: calendar,
            now: try date(2026, 9, 30)
        )

        XCTAssertEqual(snapshot.memberNames, ["Alex Able", "Jordan Able"])
        XCTAssertEqual(snapshot.troop.formalName, "Mayflower Troop • Troop 51")
        XCTAssertEqual(snapshot.troop.mailingAddress, "123 Main Street, Plymouth MA 02360")
        XCTAssertEqual(troopProfile.greetingName, "Dom")
        XCTAssertEqual(snapshot.beginningBalanceCents, 10_000)
        XCTAssertEqual(snapshot.newChargesCents, 5_000)
        XCTAssertEqual(snapshot.paymentsAndCreditsCents, 2_500)
        XCTAssertEqual(snapshot.balanceAdjustmentsCents, 700)
        XCTAssertEqual(snapshot.currentBalanceCents, 13_200)
        XCTAssertEqual(snapshot.activity.count, 5)
        XCTAssertEqual(snapshot.activity.last?.runningBalanceCents, 13_200)
        XCTAssertTrue(snapshot.activity.first?.description.contains("Fall Campout") == true)
        XCTAssertEqual(snapshot.upcoming.map(\.amountCents), [4_000])
        XCTAssertEqual(FamilyStatementService.defaultFilename(for: snapshot), "Able-Family-Statement-2026-09-30.pdf")

        let pdf = try XCTUnwrap(FamilyStatementPDFRenderer.render(snapshot))
        XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
        XCTAssertGreaterThan(pdf.count, 3_000)
        if let outputPath = ProcessInfo.processInfo.environment["TROOPLEDGER_SAMPLE_PDF"] {
            try pdf.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }

    func testFamilyStatementRequiresMembersAndValidDates() throws {
        let family = FamilyRecord(name: "Empty Family")
        let today = Date(timeIntervalSince1970: 1_788_825_600)
        XCTAssertThrowsError(try FamilyStatementService.makeSnapshot(
            family: family,
            people: [],
            entries: [],
            events: [],
            periodStart: today,
            asOfDate: today
        )) { error in
            XCTAssertEqual(error as? FamilyStatementError, .noMembers)
        }

        let member = PersonRecord(firstName: "Alex", lastName: "Able", role: .scout)
        member.familyID = family.id
        XCTAssertThrowsError(try FamilyStatementService.makeSnapshot(
            family: family,
            people: [member],
            entries: [],
            events: [],
            periodStart: today.addingTimeInterval(86_400),
            asOfDate: today
        )) { error in
            XCTAssertEqual(error as? FamilyStatementError, .invalidPeriod)
        }
    }

    func testEventFeeCalculatorShowsBreakEvenContingencyAndRoundedSuggestion() {
        let calculation = EventFeeCalculator.calculate(
            fixedCostsCents: 25_000,
            perPersonCostsCents: 1_250,
            expectedParticipants: 20,
            contingencyBasisPoints: 1_000
        )

        XCTAssertEqual(calculation.baseTotalCents, 50_000)
        XCTAssertEqual(calculation.contingencyCents, 5_000)
        XCTAssertEqual(calculation.totalCostCents, 55_000)
        XCTAssertEqual(calculation.exactBreakEvenFeeCents, 2_750)
        XCTAssertEqual(calculation.suggestedFeeCents, 2_800)
    }

    @MainActor
    func testEventCloseoutFreezesRosterPostsAdjustmentsAndRejectsDuplicate() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let event = EventRecord(name: "Winter Camp", startDate: Date(), endDate: Date())
        let scout = PersonRecord(firstName: "Alex", lastName: "Scout", role: .scout)
        let adult = PersonRecord(firstName: "Jordan", lastName: "Leader", role: .leader)
        let scoutParticipant = EventParticipant(eventID: event.id, personID: scout.id, status: .attended)
        scoutParticipant.feeCents = 4_000
        scoutParticipant.paidCents = 2_500
        scoutParticipant.feeScheduleNameSnapshot = "Youth"
        let adultParticipant = EventParticipant(eventID: event.id, personID: adult.id, status: .registered)
        adultParticipant.feeCents = 5_000
        adultParticipant.paidCents = 6_000
        let cancelled = EventParticipant(eventID: event.id, personID: nil, status: .cancelled)
        cancelled.guestName = "Cancelled Guest"
        let expense = LedgerTransaction(accountID: nil, date: Date(), direction: .expense, amountCents: 10_000, payee: "Camp", category: "Camping")
        expense.eventID = event.id
        let income = LedgerTransaction(accountID: nil, date: Date(), direction: .income, amountCents: 8_500, payee: "Families", category: "Event Fees")
        income.eventID = event.id
        context.insert(event)
        context.insert(scout)
        context.insert(adult)
        context.insert(scoutParticipant)
        context.insert(adultParticipant)
        context.insert(cancelled)
        context.insert(expense)
        context.insert(income)

        let preview = try EventCloseoutService.makePreview(
            event: event,
            participants: [scoutParticipant, adultParticipant, cancelled],
            people: [scout, adult],
            transactions: [expense, income],
            financialEntries: []
        )
        XCTAssertEqual(preview.participants.count, 2)
        XCTAssertEqual(preview.actualParticipantCostCents, 5_000)
        XCTAssertEqual(preview.unpaidCents, 1_500)
        XCTAssertEqual(preview.refundDueCents, -1_000)
        XCTAssertEqual(preview.finalVarianceCents, -1_500)

        let closeout = try EventCloseoutService.post(preview: preview, event: event, closeDate: Date(), notes: "Reviewed", postMemberAdjustments: true, existingCloseouts: [], in: context)
        XCTAssertEqual(closeout.postedAdjustmentCount, 1)
        XCTAssertEqual(event.status, .completed)
        XCTAssertEqual(event.closeoutID, closeout.id)
        XCTAssertNotNil(event.closedAt)
        let entries = try context.fetch(FetchDescriptor<MemberLedgerEntry>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.personID, scout.id)
        XCTAssertEqual(entries.first?.kind, .adjustmentIncrease)
        XCTAssertEqual(entries.first?.amountCents, 1_000)
        let allocations = try context.fetch(FetchDescriptor<EventCloseoutAllocationRecord>())
        XCTAssertEqual(allocations.count, 2)
        XCTAssertThrowsError(try EventCloseoutService.post(preview: preview, event: event, closeDate: Date(), notes: "", postMemberAdjustments: false, existingCloseouts: [closeout], in: context)) { error in
            XCTAssertEqual(error as? EventCloseoutError, .alreadyClosed)
        }
    }

    func testMonthlyReportAndCommitteePackageUsePeriodBoundariesAndManifest() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
        }
        let account = AccountRecord(name: "Checking", openingBalanceCents: 10_000)
        let before = LedgerTransaction(accountID: account.id, date: try date(2026, 7, 31), direction: .income, amountCents: 1_000, payee: "Before", category: "Dues")
        let income = LedgerTransaction(accountID: account.id, date: try date(2026, 8, 1), direction: .income, amountCents: 5_000, payee: "Families", category: "Dues")
        let expense = LedgerTransaction(accountID: account.id, date: try date(2026, 8, 31), direction: .expense, amountCents: 2_000, payee: "Store", category: "Supplies")
        let after = LedgerTransaction(accountID: account.id, date: try date(2026, 9, 1), direction: .expense, amountCents: 9_000, payee: "After", category: "Other")
        let person = PersonRecord(firstName: "Alex", lastName: "Scout", role: .scout)
        let charge = MemberLedgerEntry(personID: person.id, date: try date(2026, 8, 15), kind: .charge, amountCents: 3_000, category: "Dues")
        let reconciliation = ReconciliationRecord(accountID: account.id, statementDate: try date(2026, 8, 31), statementEndingBalanceCents: 14_000, clearedBalanceCents: 14_000)
        let report = TreasurerReportService.makeSnapshot(
            title: "Monthly Treasurer Report",
            periodStart: try date(2026, 8, 1),
            periodEnd: try date(2026, 8, 31),
            profile: nil,
            accounts: [account],
            transactions: [before, income, expense, after],
            people: [person],
            memberEntries: [charge],
            reconciliations: [reconciliation],
            generatedAt: try date(2026, 9, 1),
            calendar: calendar
        )
        XCTAssertEqual(report.openingCashCents, 11_000)
        XCTAssertEqual(report.totalIncomeCents, 5_000)
        XCTAssertEqual(report.totalExpenseCents, 2_000)
        XCTAssertEqual(report.endingCashCents, 14_000)
        XCTAssertEqual(report.outstandingMemberCents, 3_000)
        XCTAssertEqual(report.reconciliationStatus.first?.differenceCents, 0)
        let pdf = try XCTUnwrap(TreasurerReportPDFRenderer.render(report))
        XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
        if let outputPath = ProcessInfo.processInfo.environment["TROOPLEDGER_MONTHLY_REPORT_PDF"] {
            try pdf.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
        let files = try CommitteeReportPackageService.makeFiles(report: report, transactions: [before, income, expense, after])
        XCTAssertNotNil(files["treasurer-report.pdf"])
        let manifest = try XCTUnwrap(String(data: XCTUnwrap(files["manifest-sha256.csv"]), encoding: .utf8))
        XCTAssertTrue(manifest.contains("treasurer-report.pdf"))
        let register = try XCTUnwrap(String(data: XCTUnwrap(files["register.csv"]), encoding: .utf8))
        XCTAssertTrue(register.contains("Families"))
        XCTAssertFalse(register.contains("Before"))
        XCTAssertFalse(register.contains("After"))
    }

    func testRecharterForecastKeepsAssumptionsVisibleAndSeparateFromAssessedDues() {
        let account = AccountRecord(name: "Checking", openingBalanceCents: 100_000)
        let scout = PersonRecord(firstName: "Alex", lastName: "Scout", role: .scout)
        let adult = PersonRecord(firstName: "Jordan", lastName: "Leader", role: .leader)
        let inactive = PersonRecord(firstName: "Former", lastName: "Scout", role: .scout)
        inactive.isActive = false
        let registration = RegistrationRecord(personID: scout.id, programYear: "2027", unitRole: "Scout", status: .current)
        registration.duesAssessedCents = 8_500
        let forecast = RecharterForecastService.makeSnapshot(
            programYear: "2027",
            people: [scout, adult, inactive],
            registrations: [registration],
            accounts: [account],
            transactions: [],
            perPersonCostCents: 7_500,
            unitCharterCostCents: 10_000,
            otherCostCents: 5_000,
            expectedCollectionsCents: 20_000
        )
        XCTAssertEqual(forecast.activePersonCount, 2)
        XCTAssertEqual(forecast.assessedRegistrationCents, 8_500)
        XCTAssertEqual(forecast.totalCostCents, 30_000)
        XCTAssertEqual(forecast.projectedEndingCashCents, 90_000)
    }

    @MainActor
    func testAnnualAuditPackageContainsPeriodReportsCompleteRecordsAndManifest() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let account = AccountRecord(name: "Checking", openingBalanceCents: 50_000)
        let transaction = LedgerTransaction(accountID: account.id, date: Date(), direction: .expense, amountCents: 1_000, payee: "Council", category: "Registration")
        context.insert(account)
        context.insert(transaction)
        try context.save()

        let period = ReportingPeriod.containing(Date(), basis: .schoolYear)
        let files = try AnnualAuditPackageService.makeFiles(from: context, period: period)

        XCTAssertTrue(files["annual-treasurer-report.pdf"]?.starts(with: Data("%PDF".utf8)) == true)
        XCTAssertNotNil(files["annual-summary.csv"])
        XCTAssertNotNil(files["annual-register.csv"])
        XCTAssertNotNil(files["budget-to-actual.csv"])
        XCTAssertNotNil(files["approval-exceptions.csv"])
        XCTAssertNotNil(files["complete-records/backup.json"])
        XCTAssertNotNil(files["complete-records/event_closeouts.csv"])
        let manifest = try XCTUnwrap(String(data: XCTUnwrap(files["manifest-sha256.csv"]), encoding: .utf8))
        XCTAssertTrue(manifest.contains("annual-treasurer-report.pdf"))
        XCTAssertTrue(manifest.contains("complete-records/backup.json"))
    }

    func testDeletionPolicyProtectsReferencedAccountsPeopleEventsAndTransactions() {
        let account = AccountRecord(name: "Checking")
        let reconciliation = ReconciliationRecord(accountID: account.id, statementDate: Date(), statementEndingBalanceCents: 0, clearedBalanceCents: 0)
        XCTAssertFalse(RecordDeletionPolicy.canDeleteAccount(account.id, transactions: [], reconciliations: [reconciliation], depositBatches: [], spreadsheetImports: []))

        let person = PersonRecord(firstName: "Alex", lastName: "Scout", role: .scout)
        let personTransaction = LedgerTransaction(accountID: nil, date: Date(), direction: .income, amountCents: 1, payee: person.displayName, category: "Dues")
        personTransaction.personID = person.id
        XCTAssertFalse(RecordDeletionPolicy.canDeletePerson(person.id, transactions: [personTransaction], depositAllocations: [], reimbursements: [], recurringAllocations: [], memberEntries: [], registrations: [], participants: [], closeoutAllocations: []))

        let event = EventRecord(name: "Campout", startDate: Date(), endDate: Date())
        let participant = EventParticipant(eventID: event.id, personID: nil)
        XCTAssertFalse(RecordDeletionPolicy.canDeleteEvent(event.id, transactions: [], depositAllocations: [], reimbursements: [], memberEntries: [], feeSchedules: [], participants: [participant], closeouts: [], closeoutAllocations: [], financialEntries: []))

        let paidTransaction = LedgerTransaction(accountID: nil, date: Date(), direction: .expense, amountCents: 1, payee: "Vendor", category: "Supplies")
        let reimbursement = ReimbursementRequest(requesterPersonID: nil, purchaseDate: Date(), purpose: "Supplies", category: "Supplies", amountCents: 1)
        reimbursement.linkedTransactionID = paidTransaction.id
        XCTAssertFalse(RecordDeletionPolicy.canDeleteTransaction(paidTransaction.id, transactions: [], depositAllocations: [], depositBatches: [], reimbursements: [reimbursement], memberEntries: []))
    }

    func testSynchronizedAndClosedEventsRejectRosterAndFinancialMutations() {
        let openEvent = EventRecord(name: "Open", startDate: Date(), endDate: Date())
        XCTAssertTrue(EventMutationPolicy.canEdit(openEvent))

        let synchronized = EventRecord(name: "Synced", startDate: Date(), endDate: Date())
        synchronized.isReadOnly = true
        XCTAssertFalse(EventMutationPolicy.canEdit(synchronized))
        XCTAssertThrowsError(try EventCloseoutService.makePreview(event: synchronized, participants: [], people: [], transactions: [], financialEntries: [])) { error in
            XCTAssertEqual(error as? EventCloseoutError, .readOnly)
        }

        let closed = EventRecord(name: "Closed", startDate: Date(), endDate: Date())
        closed.closedAt = Date()
        XCTAssertFalse(EventMutationPolicy.canEdit(closed))
    }

    @MainActor
    func testCalendarSyncRemovesStaleEmptyEventsAndDetachesStaleReferencedEvents() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let subscription = ExternalCalendarSubscription(name: "Scoutbook", feedURLString: "https://example.com/feed.ics")
        let removable = EventRecord(name: "Removed", startDate: Date(), endDate: Date())
        removable.calendarSubscriptionID = subscription.id
        removable.externalSourceID = "removed"
        removable.isReadOnly = true
        let preserved = EventRecord(name: "Preserved", startDate: Date(), endDate: Date())
        preserved.calendarSubscriptionID = subscription.id
        preserved.externalSourceID = "preserved"
        preserved.isReadOnly = true
        let participant = EventParticipant(eventID: preserved.id, personID: nil)
        context.insert(subscription)
        context.insert(removable)
        context.insert(preserved)
        context.insert(participant)
        try context.save()

        let result = try ScoutbookCalendarService.apply(feedEvents: [], to: subscription, in: context)
        try context.save()

        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.detached, 1)
        let events = try context.fetch(FetchDescriptor<EventRecord>())
        XCTAssertFalse(events.contains { $0.id == removable.id })
        let detached = try XCTUnwrap(events.first { $0.id == preserved.id })
        XCTAssertNil(detached.calendarSubscriptionID)
        XCTAssertFalse(detached.isReadOnly)
    }

    @MainActor
    func testRemovingCalendarSubscriptionPreservesEventsWithLocalRecords() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let subscription = ExternalCalendarSubscription(name: "Scoutbook", feedURLString: "https://example.com/feed.ics")
        let event = EventRecord(name: "Campout", startDate: Date(), endDate: Date())
        event.calendarSubscriptionID = subscription.id
        event.externalSourceID = "campout"
        event.isReadOnly = true
        let schedule = EventFeeScheduleRecord(eventID: event.id, name: "Standard", feeCents: 2_500)
        context.insert(subscription)
        context.insert(event)
        context.insert(schedule)
        try context.save()

        try ScoutbookCalendarService.remove(subscription: subscription, from: context)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ExternalCalendarSubscription>()), 0)
        let retained = try XCTUnwrap(context.fetch(FetchDescriptor<EventRecord>()).first)
        XCTAssertNil(retained.calendarSubscriptionID)
        XCTAssertFalse(retained.isReadOnly)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EventFeeScheduleRecord>()), 1)
    }

    @MainActor
    func testScoutbookImportDoesNotMergeSameNameWhenMemberIDsConflict() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let existing = PersonRecord(firstName: "Alex", lastName: "Scout", role: .scout)
        existing.scoutingMemberID = "OLD-100"
        context.insert(existing)
        try context.save()
        let csv = "First Name,Last Name,Member ID,Status\nAlex,Scout,NEW-200,Active\n"
        let document = try ScoutbookImporter.parse(data: Data(csv.utf8), sourceName: "members.csv")

        _ = try ScoutbookImporter.importDocument(document, kind: .members, into: context)

        let people = try context.fetch(FetchDescriptor<PersonRecord>())
        XCTAssertEqual(people.count, 2)
        XCTAssertEqual(Set(people.map(\.scoutingMemberID)), ["OLD-100", "NEW-200"])
    }

    @MainActor
    func testScoutbookPaymentImportRejectsZeroAmountRows() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let csv = "Name,Date,Amount\nAlex Scout,8/30/2026,0.00\n"
        let document = try ScoutbookImporter.parse(data: Data(csv.utf8), sourceName: "payment-log.csv")
        let preview = ScoutbookImporter.preview(document: document, kind: .paymentLog)

        XCTAssertEqual(preview.validRowCount, 0)
        XCTAssertTrue(preview.issues.contains { $0.contains("zero amount") })
        XCTAssertThrowsError(try ScoutbookImporter.importDocument(document, kind: .paymentLog, into: context)) { error in
            XCTAssertEqual(error as? ScoutbookImportError, .noImportableRows)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MemberLedgerEntry>()), 0)
    }

    func testRegistrationRejectsNegativeDues() {
        XCTAssertThrowsError(try RegistrationPolicy.validate(
            personID: UUID(),
            programYear: "2027",
            registeredOn: Date(),
            expiresOn: nil,
            duesAssessedCents: -1,
            registrations: []
        )) { error in
            XCTAssertEqual(error as? RegistrationValidationError, .negativeDues)
        }
    }

    func testRegistrationRejectsExpirationBeforeRegistration() {
        // Registration fields are date-only, so use distinct calendar days.
        let registered = Date(timeIntervalSince1970: 172_800)
        let expired = Date(timeIntervalSince1970: 86_400)
        XCTAssertThrowsError(try RegistrationPolicy.validate(
            personID: UUID(),
            programYear: "2027",
            registeredOn: registered,
            expiresOn: expired,
            duesAssessedCents: 0,
            registrations: []
        )) { error in
            XCTAssertEqual(error as? RegistrationValidationError, .expirationBeforeRegistration)
        }
    }

    func testRegistrationRejectsDuplicateProgramYear() {
        let personID = UUID()
        let existing = RegistrationRecord(personID: personID, programYear: " 2027 ", unitRole: "Scout", status: .current)
        XCTAssertThrowsError(try RegistrationPolicy.validate(
            personID: personID,
            programYear: "2027",
            registeredOn: Date(),
            expiresOn: nil,
            duesAssessedCents: 0,
            registrations: [existing]
        )) { error in
            XCTAssertEqual(error as? RegistrationValidationError, .duplicateProgramYear)
        }
    }

    func testEventDraftRejectsNegativeBudgets() {
        XCTAssertThrowsError(try EventDraftPolicy.validate(
            event: nil,
            name: "Campout",
            startDate: Date(),
            endDate: Date(),
            registrationDeadline: nil,
            budgetIncomeCents: -1,
            budgetExpenseCents: 0
        )) { error in
            XCTAssertEqual(error as? EventDraftValidationError, .negativeBudget)
        }
    }

    func testEventDraftRejectsRegistrationDeadlineAfterStart() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertThrowsError(try EventDraftPolicy.validate(
            event: nil,
            name: "Campout",
            startDate: start,
            endDate: Date(timeIntervalSince1970: 3_000),
            registrationDeadline: Date(timeIntervalSince1970: 2_000),
            budgetIncomeCents: 0,
            budgetExpenseCents: 0
        )) { error in
            XCTAssertEqual(error as? EventDraftValidationError, .deadlineAfterStart)
        }
    }

    @MainActor
    func testEventCloseoutRejectsPreviewFromDifferentEvent() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let event = EventRecord(name: "Campout", startDate: Date(), endDate: Date())
        let preview = EventCloseoutPreview(
            eventID: UUID(),
            actualIncomeCents: 0,
            actualExpenseCents: 0,
            actualParticipantCostCents: 0,
            finalVarianceCents: 0,
            unpaidCents: 0,
            refundDueCents: 0,
            participants: []
        )

        XCTAssertThrowsError(try EventCloseoutService.post(
            preview: preview,
            event: event,
            closeDate: Date(),
            notes: "",
            postMemberAdjustments: false,
            existingCloseouts: [],
            in: context
        )) { error in
            XCTAssertEqual(error as? EventCloseoutError, .previewEventMismatch)
        }
        XCTAssertNil(event.closedAt)
    }

    func testInactiveAccountWithBalanceRemainsInCashPosition() {
        let account = AccountRecord(name: "Archived Checking", kind: .checking, openingBalanceCents: 12_345)
        account.isActive = false

        let position = FinanceEngine.cashPosition(accounts: [account], transactions: [])

        XCTAssertEqual(position.bankAndCashOnHandCents, 12_345)
        XCTAssertEqual(position.totalCents, 12_345)
    }

    @MainActor
    func testReimbursementCannotLinkAccountTransferAsPayment() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let request = ReimbursementRequest(requesterPersonID: UUID(), purchaseDate: Date(), purpose: "Supplies", category: "Supplies", amountCents: 5_000)
        request.status = .approved
        let transfer = LedgerTransaction(accountID: UUID(), date: Date(), direction: .expense, amountCents: 5_000, payee: "Transfer", category: "Account Transfer")
        transfer.isTransfer = true
        context.insert(request)
        context.insert(transfer)
        try context.save()

        XCTAssertThrowsError(try ReimbursementService.linkExistingPayment(for: request, transactionID: transfer.id, in: context)) { error in
            XCTAssertEqual(error as? ReimbursementError, .transferTransaction)
        }
        XCTAssertEqual(request.status, .approved)
        XCTAssertNil(request.linkedTransactionID)
    }

    @MainActor
    func testBatchDepositRejectsNonpositiveReceiptSources() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let undeposited = AccountRecord(name: "Undeposited Funds", kind: .undepositedFunds, openingBalanceCents: 1_000)
        let checking = AccountRecord(name: "Checking", kind: .checking)
        let zeroLedgerReceipt = LedgerTransaction(
            accountID: undeposited.id,
            date: Date(),
            direction: .income,
            amountCents: 0,
            payee: "Family",
            category: "Dues"
        )
        let negativeImportedReceipt = CashReceiptRecord(
            date: Date(),
            personName: "Family",
            purpose: "Dues",
            amountCents: -500,
            paymentKind: "Cash"
        )
        context.insert(undeposited)
        context.insert(checking)
        context.insert(zeroLedgerReceipt)
        context.insert(negativeImportedReceipt)
        try context.save()

        XCTAssertTrue(BatchDepositService.eligibleTransactions(
            undepositedFundsAccountID: undeposited.id,
            transactions: [zeroLedgerReceipt],
            allocations: []
        ).isEmpty)
        XCTAssertTrue(BatchDepositService.eligibleCashReceipts(
            receipts: [negativeImportedReceipt],
            allocations: []
        ).isEmpty)
        XCTAssertThrowsError(try BatchDepositService.post(
            destinationAccountID: checking.id,
            depositDate: Date(),
            reference: "",
            notes: "",
            sourceTransactionIDs: [],
            sourceCashReceiptIDs: [negativeImportedReceipt.id],
            reconciliations: [],
            in: context
        )) { error in
            XCTAssertEqual(error as? BatchDepositError, .invalidReceiptAmount)
        }
    }

    @MainActor
    func testGeneralSpreadsheetImportRejectsInactiveAccount() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let account = AccountRecord(name: "Archived Checking")
        account.isActive = false
        context.insert(account)
        try context.save()
        let csv = "Date,Amount,Payee\n8/30/2026,10.00,Family\n"
        let document = try GeneralSpreadsheetImporter.parse(data: Data(csv.utf8), sourceName: "register.csv")
        let mapping = TransactionColumnMapping.detected(from: document.headers)

        XCTAssertThrowsError(try GeneralSpreadsheetImporter.importDocument(
            document,
            mapping: mapping,
            accountID: account.id,
            defaultDirection: .income,
            defaultCategory: "Dues",
            reconciliations: [],
            skipExceptions: false,
            into: context
        )) { error in
            XCTAssertEqual(error as? GeneralSpreadsheetImportError, .inactiveAccount)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 0)
    }

    func testGeneralSpreadsheetRejectsOutOfRangeAmount() throws {
        let csv = "Date,Amount\n8/30/2026,999999999999999999999999.00\n"
        let document = try GeneralSpreadsheetImporter.parse(data: Data(csv.utf8), sourceName: "register.csv")
        let mapping = TransactionColumnMapping.detected(from: document.headers)
        let preview = GeneralSpreadsheetImporter.preview(
            document: document,
            mapping: mapping,
            accountID: UUID(),
            defaultDirection: .income,
            defaultCategory: "Dues",
            reconciliations: []
        )

        XCTAssertEqual(preview.validRows.count, 0)
        XCTAssertTrue(preview.invalidRows.flatMap(\.issues).contains { $0.contains("out-of-range") })
    }

    func testGeneralSpreadsheetRejectsNegativeSplitColumnAmount() throws {
        let csv = "Date,Income Amount,Expense Amount\n8/30/2026,-10.00,\n"
        let document = try GeneralSpreadsheetImporter.parse(data: Data(csv.utf8), sourceName: "register.csv")
        let mapping = TransactionColumnMapping.detected(from: document.headers)
        let preview = GeneralSpreadsheetImporter.preview(
            document: document,
            mapping: mapping,
            accountID: UUID(),
            defaultDirection: .income,
            defaultCategory: "Dues",
            reconciliations: []
        )

        XCTAssertEqual(preview.validRows.count, 0)
        XCTAssertTrue(preview.invalidRows.flatMap(\.issues).contains { $0.contains("cannot be negative") })
    }

    func testGeneralSpreadsheetDelimiterDetectionIgnoresQuotedTabs() throws {
        let csv = "Date,Amount,Memo\n8/30/2026,10.00,\"one\ttwo\tthree\tfour\tfive\tsix\"\n"
        let document = try GeneralSpreadsheetImporter.parse(data: Data(csv.utf8), sourceName: "register.csv")
        let mapping = TransactionColumnMapping.detected(from: document.headers)

        XCTAssertEqual(document.headers, ["Date", "Amount", "Memo"])
        XCTAssertEqual(document.rows.count, 1)
        XCTAssertEqual(document.rows[0].value(at: mapping[.memo]), "one\ttwo\tthree\tfour\tfive\tsix")
    }

    @MainActor
    func testScoutbookImportDoesNotChooseBetweenAmbiguousSameNamePeople() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let first = PersonRecord(firstName: "Alex", lastName: "Scout", role: .leader)
        let second = PersonRecord(firstName: "Alex", lastName: "Scout", role: .parent)
        context.insert(first)
        context.insert(second)
        try context.save()
        let csv = "First Name,Last Name,Status\nAlex,Scout,Active\n"
        let document = try ScoutbookImporter.parse(data: Data(csv.utf8), sourceName: "members.csv")

        _ = try ScoutbookImporter.importDocument(document, kind: .members, into: context)

        let people = try context.fetch(FetchDescriptor<PersonRecord>())
        XCTAssertEqual(people.count, 3)
        XCTAssertEqual(people.first(where: { $0.id == first.id })?.role, .leader)
        XCTAssertEqual(people.first(where: { $0.id == second.id })?.role, .parent)
    }

    @MainActor
    func testScoutbookImportNormalizesProgramYearBeforeMatchingRegistration() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let person = PersonRecord(firstName: "Alex", lastName: "Scout", role: .scout)
        person.scoutingMemberID = "123"
        let registration = RegistrationRecord(personID: person.id, programYear: " 2027 ", unitRole: "Scout", status: .current)
        context.insert(person)
        context.insert(registration)
        try context.save()
        let csv = "First Name,Last Name,Member ID,Program Year,Status\nAlex,Scout,123,2027,Active\n"
        let document = try ScoutbookImporter.parse(data: Data(csv.utf8), sourceName: "members.csv")

        _ = try ScoutbookImporter.importDocument(document, kind: .members, into: context)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RegistrationRecord>()), 1)
    }

    @MainActor
    func testScoutbookImportDerivesProgramYearFromHistoricalRegistrationDate() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let csv = "First Name,Last Name,Member ID,Registration Date,Status\nAlex,Scout,123,1/15/2024,Active\n"
        let document = try ScoutbookImporter.parse(data: Data(csv.utf8), sourceName: "members.csv")

        _ = try ScoutbookImporter.importDocument(document, kind: .members, into: context)

        let registration = try XCTUnwrap(context.fetch(FetchDescriptor<RegistrationRecord>()).first)
        XCTAssertEqual(registration.programYear, "2024")
    }

    @MainActor
    func testReimbursementCannotRemoveAnotherRequestsAttachment() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let first = ReimbursementRequest(requesterPersonID: UUID(), purchaseDate: Date(), purpose: "First", category: "Supplies", amountCents: 100)
        let second = ReimbursementRequest(requesterPersonID: UUID(), purchaseDate: Date(), purpose: "Second", category: "Supplies", amountCents: 100)
        let attachment = ReimbursementAttachment(requestID: first.id, filename: "receipt.pdf", mediaType: "application/pdf", byteCount: 1, sha256: "abc", data: Data([1]))
        context.insert(first)
        context.insert(second)
        context.insert(attachment)
        try context.save()

        XCTAssertThrowsError(try ReimbursementService.removeAttachment(attachment, from: second, in: context)) { error in
            XCTAssertEqual(error as? ReimbursementError, .attachmentRequestMismatch)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReimbursementAttachment>()), 1)
    }

    @MainActor
    func testReimbursementCannotCreatePaymentFromInactiveAccount() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let account = AccountRecord(name: "Archived Checking")
        account.isActive = false
        let request = ReimbursementRequest(requesterPersonID: UUID(), purchaseDate: Date(), purpose: "Supplies", category: "Supplies", amountCents: 500)
        request.status = .approved
        context.insert(account)
        context.insert(request)
        try context.save()

        XCTAssertThrowsError(try ReimbursementService.createAndLinkPayment(
            for: request,
            accountID: account.id,
            paymentDate: Date(),
            reference: "",
            payee: "Alex Adult",
            reconciliations: [],
            in: context
        )) { error in
            XCTAssertEqual(error as? ReimbursementError, .accountRequired)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 0)
        XCTAssertEqual(request.status, .approved)
    }

    func testMoneyParsingRejectsOutOfRangeValues() {
        XCTAssertNil(Money.cents(from: "999999999999999999999999.00"))
        XCTAssertNil(Money.cents(from: "-999999999999999999999999.00"))
    }

    func testReconciliationEligibilityRequiresAnAccount() {
        let orphan = LedgerTransaction(
            accountID: nil,
            date: Date(),
            direction: .income,
            amountCents: 100,
            payee: "Orphan",
            category: "Dues"
        )

        XCTAssertFalse(ReconciliationPolicy.isEligible(orphan, accountID: nil, statementDate: Date()))
    }

    func testReconciliationCompletionRejectsInactiveAccount() {
        let account = AccountRecord(name: "Archived Checking")
        account.isActive = false

        XCTAssertThrowsError(try ReconciliationCompletionPolicy.validate(
            account: account,
            statementDate: Date(),
            statementBalanceCents: 0,
            clearedBalanceCents: 0,
            selectedTransactionIDs: [],
            transactions: [],
            reconciliations: []
        )) { error in
            XCTAssertEqual(error as? ReconciliationCompletionError, .inactiveAccount)
        }
    }

    func testReconciliationCompletionRejectsStaleSelectedTransaction() {
        let account = AccountRecord(name: "Checking")
        let otherAccount = AccountRecord(name: "Savings")
        let selected = LedgerTransaction(
            accountID: otherAccount.id,
            date: Date(),
            direction: .income,
            amountCents: 100,
            payee: "Wrong account",
            category: "Dues"
        )

        XCTAssertThrowsError(try ReconciliationCompletionPolicy.validate(
            account: account,
            statementDate: Date(),
            statementBalanceCents: 0,
            clearedBalanceCents: 0,
            selectedTransactionIDs: [selected.id],
            transactions: [selected],
            reconciliations: []
        )) { error in
            XCTAssertEqual(error as? ReconciliationCompletionError, .ineligibleSelection)
        }
    }

    func testEventFeeCalculatorNormalizesNegativeCostAssumptions() {
        let calculation = EventFeeCalculator.calculate(
            fixedCostsCents: -10_000,
            perPersonCostsCents: -500,
            expectedParticipants: 20,
            contingencyBasisPoints: 1_000
        )

        XCTAssertEqual(calculation.fixedCostsCents, 0)
        XCTAssertEqual(calculation.perPersonCostsCents, 0)
        XCTAssertEqual(calculation.baseTotalCents, 0)
        XCTAssertEqual(calculation.suggestedFeeCents, 0)
    }

    func testEventFeeScheduleRejectsNegativeAmount() {
        let event = EventRecord(name: "Campout", startDate: Date(), endDate: Date())

        XCTAssertThrowsError(try EventFeeSchedulePolicy.validate(
            event: event,
            schedule: nil,
            name: "Youth",
            feeCents: -1,
            schedules: []
        )) { error in
            XCTAssertEqual(error as? EventFeeScheduleValidationError, .negativeFee)
        }
    }

    func testEventFeeScheduleRejectsDuplicateName() {
        let event = EventRecord(name: "Campout", startDate: Date(), endDate: Date())
        let existing = EventFeeScheduleRecord(eventID: event.id, name: " Youth Fee ", feeCents: 2_500)

        XCTAssertThrowsError(try EventFeeSchedulePolicy.validate(
            event: event,
            schedule: nil,
            name: "youth fee",
            feeCents: 3_000,
            schedules: [existing]
        )) { error in
            XCTAssertEqual(error as? EventFeeScheduleValidationError, .duplicateName)
        }
    }

    func testEventFeeScheduleCannotBeDeletedWhileAssigned() {
        let event = EventRecord(name: "Campout", startDate: Date(), endDate: Date())
        let schedule = EventFeeScheduleRecord(eventID: event.id, name: "Youth", feeCents: 2_500)
        let participant = EventParticipant(eventID: event.id, personID: UUID())
        participant.feeScheduleID = schedule.id

        XCTAssertThrowsError(try EventFeeSchedulePolicy.validateDeletion(schedule, participants: [participant])) { error in
            XCTAssertEqual(error as? EventFeeScheduleValidationError, .scheduleInUse)
        }
    }

    func testEventParticipantRejectsNegativeFinancialValues() {
        let event = EventRecord(name: "Campout", startDate: Date(), endDate: Date())
        let participant = EventParticipant(eventID: event.id, personID: UUID())

        XCTAssertThrowsError(try EventParticipantPolicy.validate(
            event: event,
            participant: participant,
            guestName: "",
            feeCents: -1,
            paidCents: 0,
            feeScheduleID: nil,
            schedules: []
        )) { error in
            XCTAssertEqual(error as? EventParticipantValidationError, .negativeFee)
        }
        XCTAssertThrowsError(try EventParticipantPolicy.validate(
            event: event,
            participant: participant,
            guestName: "",
            feeCents: 0,
            paidCents: -1,
            feeScheduleID: nil,
            schedules: []
        )) { error in
            XCTAssertEqual(error as? EventParticipantValidationError, .negativePaid)
        }
    }

    func testEventParticipantRejectsFeeScheduleFromAnotherEvent() {
        let event = EventRecord(name: "Campout", startDate: Date(), endDate: Date())
        let otherEvent = EventRecord(name: "Other", startDate: Date(), endDate: Date())
        let participant = EventParticipant(eventID: event.id, personID: UUID())
        let schedule = EventFeeScheduleRecord(eventID: otherEvent.id, name: "Other Fee", feeCents: 2_500)

        XCTAssertThrowsError(try EventParticipantPolicy.validate(
            event: event,
            participant: participant,
            guestName: "",
            feeCents: 2_500,
            paidCents: 0,
            feeScheduleID: schedule.id,
            schedules: [schedule]
        )) { error in
            XCTAssertEqual(error as? EventParticipantValidationError, .feeScheduleWrongEvent)
        }
    }

    func testAppearanceToggleUsesTheSystemSchemeUntilAChoiceIsStored() {
        XCTAssertEqual(
            AppAppearance.resolved(storedRawValue: "", fallback: .dark),
            .dark
        )
        XCTAssertEqual(
            AppAppearance.toggledRawValue(storedRawValue: "", fallback: .dark),
            AppAppearance.light.rawValue
        )
        XCTAssertEqual(
            AppAppearance.toggledRawValue(storedRawValue: AppAppearance.light.rawValue, fallback: .light),
            AppAppearance.dark.rawValue
        )
    }

    func testScoutMotionCelebratesOnlyWhenAProgressTargetIsNewlyReached() {
        XCTAssertFalse(ScoutMotion.shouldCelebrateTransition(previous: nil, current: 4, target: 4))
        XCTAssertFalse(ScoutMotion.shouldCelebrateTransition(previous: 4, current: 4, target: 4))
        XCTAssertFalse(ScoutMotion.shouldCelebrateTransition(previous: 3, current: 3, target: 4))
        XCTAssertTrue(ScoutMotion.shouldCelebrateTransition(previous: 3, current: 4, target: 4))
        XCTAssertTrue(ScoutMotion.shouldCelebrateTransition(previous: 2, current: 5, target: 4))
        XCTAssertFalse(ScoutMotion.shouldCelebrateTransition(previous: 0, current: 0, target: 0))
    }

    func testFieldbookActivityIconsRecognizeOutdoorActivitiesAndClassificationFallbacks() {
        XCTAssertEqual(
            FieldbookActivityIcon.systemImage(for: "Fall Camporee", classification: .district),
            "tent.2.fill"
        )
        XCTAssertEqual(
            FieldbookActivityIcon.systemImage(for: "Trail Conservation Day", classification: .troop),
            "figure.hiking"
        )
        XCTAssertEqual(
            FieldbookActivityIcon.systemImage(for: "Aquatics Weekend", classification: .council),
            "building.2.fill"
        )
        XCTAssertEqual(
            FieldbookActivityIcon.systemImage(for: "National Gathering", classification: .national),
            "star.fill"
        )
    }

    // MARK: - Regression tests for the September 2026 security and bug audit

    func testCSVFormattingNeutralizesFormulaTriggersButKeepsNumbers() {
        XCTAssertEqual(CSVFormatting.field("=HYPERLINK(\"http://x\")"), "\"'=HYPERLINK(\"\"http://x\"\")\"")
        XCTAssertEqual(CSVFormatting.field("+1 617 555 0100"), "\"'+1 617 555 0100\"")
        XCTAssertEqual(CSVFormatting.field("@import"), "\"'@import\"")
        XCTAssertEqual(CSVFormatting.field("-1250"), "-1250")
        XCTAssertEqual(CSVFormatting.field("-12.50"), "-12.50")
        XCTAssertEqual(CSVFormatting.field("-cmd"), "\"'-cmd\"")
        XCTAssertEqual(CSVFormatting.field("Camp Green"), "Camp Green")
        XCTAssertEqual(CSVFormatting.field("Deposit, first"), "\"Deposit, first\"")
    }

    func testExportedRegisterNeutralizesFormulaPayee() {
        let transaction = LedgerTransaction(accountID: nil, date: Date(timeIntervalSince1970: 1_787_558_400), direction: .expense, amountCents: 100, payee: "=cmd|' /C calc'!A0", category: "Supplies")
        let csv = TreasurerReportService.registerCSV(transactions: [transaction], start: Date(timeIntervalSince1970: 1_787_000_000), end: Date(timeIntervalSince1970: 1_788_000_000))
        XCTAssertTrue(csv.contains("\"'=cmd|' /C calc'!A0\""))
        XCTAssertFalse(csv.contains(",=cmd"))
    }

    func testCalendarTextUnescapingKeepsEscapedBackslashesIntact() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:path-1
        DTSTART:20260915T190000
        SUMMARY:Files in C:\\\\Scouts\\\\notes
        DESCRIPTION:Line one\\nLine two\\, with comma
        END:VEVENT
        END:VCALENDAR
        """
        let event = try XCTUnwrap(ScoutbookCalendarService.parse(data: Data(ics.utf8)).first)
        XCTAssertEqual(event.title, "Files in C:\\Scouts\\notes")
        XCTAssertEqual(event.notes, "Line one\nLine two, with comma")
    }

    func testCalendarParserToleratesDuplicateRRULEKeys() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:dup-1
        DTSTART:20260915T190000
        RRULE:FREQ=WEEKLY;FREQ=DAILY;COUNT=2
        SUMMARY:Meeting
        END:VEVENT
        END:VCALENDAR
        """
        XCTAssertEqual(try ScoutbookCalendarService.parse(data: Data(ics.utf8)).count, 2)
    }

    func testCalendarParserCapsExpandedEventCount() {
        var ics = "BEGIN:VCALENDAR\n"
        for index in 0...(ScoutbookCalendarService.maximumExpandedEvents / 500) {
            ics += "BEGIN:VEVENT\nUID:flood-\(index)\nDTSTART:20260101T190000\nRRULE:FREQ=DAILY;COUNT=500\nSUMMARY:Flood\nEND:VEVENT\n"
        }
        ics += "END:VCALENDAR\n"
        XCTAssertThrowsError(try ScoutbookCalendarService.parse(data: Data(ics.utf8))) { error in
            XCTAssertEqual(error as? ScoutbookCalendarError, .tooManyEvents)
        }
    }

    func testGeneralSpreadsheetImportReadsTwoDigitYearsInCurrentCentury() throws {
        let csv = "Date,Amount,Payee\n1/15/24,25.00,Camp Store\n"
        let document = try GeneralSpreadsheetImporter.parse(data: Data(csv.utf8), sourceName: "register.csv")
        let preview = GeneralSpreadsheetImporter.preview(
            document: document,
            mapping: TransactionColumnMapping.detected(from: document.headers),
            accountID: UUID(),
            defaultDirection: .expense,
            defaultCategory: "Supplies",
            reconciliations: []
        )
        let draft = try XCTUnwrap(preview.validRows.first?.draft)
        XCTAssertEqual(Calendar.current.component(.year, from: draft.date), 2024)
    }

    @MainActor
    func testScoutbookImportReadsTwoDigitYearsInCurrentCentury() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let csv = "First Name,Last Name,Member ID,Join Date\nAva,Scout,1001,3/5/24\n"
        let document = try ScoutbookImporter.parse(data: Data(csv.utf8), sourceName: "members.csv")
        _ = try ScoutbookImporter.importDocument(document, kind: .members, into: context)
        let person = try XCTUnwrap(context.fetch(FetchDescriptor<PersonRecord>()).first)
        XCTAssertEqual(person.joinDate.map { Calendar.current.component(.year, from: $0) }, 2024)
    }

    func testScoutbookPaymentPreviewRejectsOutOfRangeAmount() throws {
        let csv = "Name,Date,Amount\nAva Scout,8/30/2026,99999999999999999999.00\n"
        let document = try ScoutbookImporter.parse(data: Data(csv.utf8), sourceName: "payment-log.csv")
        XCTAssertEqual(ScoutbookImporter.preview(document: document, kind: .paymentLog).validRowCount, 0)
    }

    func testScoutbookImporterRejectsOversizedFiles() {
        let oversized = Data(count: ScoutbookImporter.maximumFileBytes + 1)
        XCTAssertThrowsError(try ScoutbookImporter.parse(data: oversized, sourceName: "huge.csv")) { error in
            XCTAssertEqual(error as? ScoutbookImportError, .fileTooLarge)
        }
    }

    @MainActor
    func testReceiptAttachmentRejectsContentThatDoesNotMatchDeclaredType() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let request = ReimbursementRequest(requesterPersonID: UUID(), purchaseDate: Date(), purpose: "Supplies", category: "Program Supplies", amountCents: 500)
        context.insert(request)

        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>".utf8)
        XCTAssertThrowsError(try ReimbursementService.addAttachment(to: request, data: svg, filename: "receipt.svg", mediaType: "image/svg+xml", in: context)) { error in
            XCTAssertEqual(error as? ReimbursementError, .receiptTypeUnsupported)
        }
        let renamedPDF = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34])
        XCTAssertThrowsError(try ReimbursementService.addAttachment(to: request, data: renamedPDF, filename: "receipt.jpg", mediaType: "image/jpeg", in: context)) { error in
            XCTAssertEqual(error as? ReimbursementError, .receiptTypeUnsupported)
        }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
        XCTAssertEqual(try ReimbursementService.addAttachment(to: request, data: jpeg, filename: "receipt.jpg", mediaType: "image/jpeg", in: context).mediaType, "image/jpeg")
    }

    func testDisbursementControlsFlagRequesterActingAsApproverOrSigner() {
        let requesterID = UUID()
        let assessment = DisbursementControlEvaluator.assess(
            approver: .init(personID: requesterID, name: "Pat Parent", household: "Parent"),
            signerOne: .init(personID: nil, name: "pat parent", household: ""),
            signerTwo: .init(personID: UUID(), name: "Sam Signer", household: "Parent"),
            policy: DisbursementControlPolicy(),
            requester: DisbursementControlIdentity(personID: requesterID, name: "Pat Parent", household: "Parent")
        )
        XCTAssertTrue(assessment.warnings.contains("Approver is the person requesting this reimbursement."))
        XCTAssertTrue(assessment.warnings.contains("Signer 1 is the person requesting this reimbursement."))
        XCTAssertTrue(assessment.warnings.contains("Signer 2 shares the requester's household label."))
    }

    @MainActor
    func testBackupManifestRecomputesAttachmentHashesAndSanitizesPaths() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        context.insert(ReimbursementAttachment(requestID: UUID(), filename: "../../escape.png", mediaType: "image/png", byteCount: 1, sha256: "stale", data: data))

        let archive = try PlaintextBackupService.makeArchive(from: context)
        let manifest = try XCTUnwrap(String(data: XCTUnwrap(archive.files["attachments_manifest.csv"]), encoding: .utf8))
        XCTAssertTrue(manifest.contains("MISMATCH"))
        XCTAssertTrue(manifest.contains(",stale,"))
        let path = try XCTUnwrap(archive.files.keys.first { $0.hasPrefix("attachments/") })
        XCTAssertFalse(path.contains(".."))
        XCTAssertTrue(path.hasSuffix("-escape.png"))
    }

    func testExportFilenamesUseTheLocalCalendarDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        let localMidnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 30)))
        let report = TreasurerReportService.makeSnapshot(title: "Test", periodStart: localMidnight, periodEnd: localMidnight, profile: nil, accounts: [], transactions: [], people: [], memberEntries: [], reconciliations: [], calendar: calendar)
        XCTAssertEqual(CommitteeReportPackageService.defaultFilename(for: report, calendar: calendar), "TroopLedger Committee Snapshot 2026-09-30.troopledgercommittee")
        XCTAssertEqual(TreasurerReportService.defaultMonthlyFilename(for: report, calendar: calendar), "TroopLedger Treasurer Report 2026-09.pdf")
    }

    // MARK: - Regression tests for the second audit round

    func testMoneyAcceptsCurrencySymbolsAndRejectsAbsurdAmounts() {
        XCTAssertEqual(Money.cents(from: "$1,250.00"), 125_000)
        XCTAssertEqual(Money.cents(from: " $ 12.5 "), 1_250)
        XCTAssertNil(Money.cents(from: "999999999999.00"))
        XCTAssertNil(Money.cents(from: "92233720368547758.07"))
    }

    func testCalendarOverrideWinsRegardlessOfFeedOrder() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:series-1
        RECURRENCE-ID:20260922T190000Z
        DTSTART:20260922T200000Z
        DTEND:20260922T210000Z
        SUMMARY:Moved Meeting
        END:VEVENT
        BEGIN:VEVENT
        UID:series-1
        DTSTART:20260915T190000Z
        DTEND:20260915T203000Z
        RRULE:FREQ=WEEKLY;COUNT=2
        SUMMARY:Troop Meeting
        END:VEVENT
        END:VCALENDAR
        """
        let events = try ScoutbookCalendarService.parse(data: Data(ics.utf8))
        XCTAssertEqual(events.count, 2)
        let moved = try XCTUnwrap(events.first { $0.title == "Moved Meeting" })
        XCTAssertEqual(moved.startDate, Date(timeIntervalSince1970: 1_790_107_200))
        XCTAssertEqual(events.filter { $0.title == "Troop Meeting" }.count, 1)
    }

    func testCalendarURLRejectsEmbeddedCredentials() {
        XCTAssertThrowsError(try ScoutbookCalendarService.validatedURL("https://scout:secret@example.com/feed.ics")) { error in
            XCTAssertEqual(error as? ScoutbookCalendarError, .embeddedCredentials)
        }
        XCTAssertNoThrow(try ScoutbookCalendarService.validatedURL("https://example.com/feed.ics?token=abc"))
    }

    func testCalendarParserCapsTextLengths() throws {
        let longNotes = String(repeating: "x", count: ScoutbookCalendarService.maximumNotesLength + 5_000)
        let ics = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:long-1\nDTSTART:20260915T190000\nSUMMARY:Meeting\nDESCRIPTION:\(longNotes)\nEND:VEVENT\nEND:VCALENDAR\n"
        let event = try XCTUnwrap(ScoutbookCalendarService.parse(data: Data(ics.utf8)).first)
        XCTAssertEqual(event.notes.count, ScoutbookCalendarService.maximumNotesLength)
    }

    @MainActor
    func testCalendarSyncReattachesDetachedEventsInsteadOfDuplicating() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let subscription = ExternalCalendarSubscription(name: "Troop", feedURLString: "https://example.com/feed.ics")
        context.insert(subscription)
        let detached = EventRecord(name: "Old Campout", startDate: Date(), endDate: Date())
        detached.sourceSystem = "Scoutbook Calendar"
        detached.externalSourceID = "camp-1"
        detached.calendarSubscriptionID = nil
        detached.isReadOnly = false
        context.insert(detached)
        try context.save()

        let feed = [ScoutbookCalendarEvent(externalID: "camp-1", title: "Fall Campout", startDate: Date(), endDate: Date(), location: "", notes: "", isAllDay: true, modifiedAt: nil)]
        let result = try ScoutbookCalendarService.apply(feedEvents: feed, to: subscription, in: context)
        XCTAssertEqual(result.inserted, 0)
        XCTAssertEqual(result.updated, 1)
        let events = try context.fetch(FetchDescriptor<EventRecord>())
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.calendarSubscriptionID, subscription.id)
        XCTAssertEqual(events.first?.name, "Fall Campout")
    }

    func testReconciliationRejectsFutureStatementDate() {
        let account = AccountRecord(name: "Checking")
        XCTAssertThrowsError(try ReconciliationCompletionPolicy.validate(
            account: account,
            statementDate: Date().addingTimeInterval(3 * 86_400),
            statementBalanceCents: 0,
            clearedBalanceCents: 0,
            selectedTransactionIDs: [],
            transactions: [],
            reconciliations: []
        )) { error in
            XCTAssertEqual(error as? ReconciliationCompletionError, .statementDateInFuture)
        }
    }

    @MainActor
    func testWorkbookImportDetectsRecordsAlreadySyncedFromAnotherDevice() throws {
        let snapshot = try SpreadsheetImporter.loadBundledSnapshot()
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let synced = PersonRecord(firstName: "Synced", lastName: "Elsewhere", role: .scout)
        synced.id = try XCTUnwrap(snapshot.people.first?.id)
        context.insert(synced)
        try context.save()
        XCTAssertThrowsError(try SpreadsheetImporter.importSnapshot(snapshot, into: context)) { error in
            XCTAssertEqual(error as? SpreadsheetImportError, .alreadyImported)
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<AccountRecord>()).count, 0)
    }

    func testScoutbookParserAcceptsBareCarriageReturnLineEndings() throws {
        let document = try ScoutbookImporter.parse(data: Data("First Name,Last Name\rAva,Scout\rBen,Scout\r".utf8), sourceName: "members.csv")
        XCTAssertEqual(document.rows.count, 2)
        XCTAssertEqual(document.rows.last?.value(["First Name"]), "Ben")
    }

    func testImportersCapCellLength() throws {
        let memo = String(repeating: "m", count: GeneralSpreadsheetImporter.maximumCellLength * 2)
        let document = try GeneralSpreadsheetImporter.parse(data: Data("Date,Amount,Memo\n8/30/2026,25.00,\(memo)\n".utf8), sourceName: "register.csv")
        XCTAssertEqual(document.rows.first?.cells[2].count, GeneralSpreadsheetImporter.maximumCellLength)
        let scoutbook = try ScoutbookImporter.parse(data: Data("First Name,Last Name,Notes\nAva,Scout,\(memo)\n".utf8), sourceName: "members.csv")
        XCTAssertEqual(scoutbook.rows.first?.value(["Notes"]).count, ScoutbookImporter.maximumCellLength)
    }

    // MARK: - Regression tests for the third audit round

    func testMemberLedgerAdjustmentsRequireAnExplanation() {
        XCTAssertThrowsError(try MemberEntryPolicy.validate(kind: .adjustmentDecrease, amountCents: 500, category: "Dues", notes: "  ")) { error in
            XCTAssertEqual(error as? MemberEntryValidationError, .adjustmentReasonRequired)
        }
        XCTAssertNoThrow(try MemberEntryPolicy.validate(kind: .adjustmentIncrease, amountCents: 500, category: "Dues", notes: "Corrects double charge"))
        XCTAssertNoThrow(try MemberEntryPolicy.validate(kind: .charge, amountCents: 500, category: "Dues", notes: ""))
        XCTAssertThrowsError(try MemberEntryPolicy.validate(kind: .payment, amountCents: 0, category: "Dues", notes: ""))
    }

    func testPersonPolicyRejectsDuplicateScoutingMemberIDs() {
        let existing = PersonRecord(firstName: "Ava", lastName: "Scout", role: .scout)
        existing.scoutingMemberID = "1001"
        XCTAssertThrowsError(try PersonPolicy.validate(firstName: "Ben", lastName: "Scout", memberID: " 1001 ", editingPersonID: nil, people: [existing])) { error in
            XCTAssertEqual(error as? PersonValidationError, .duplicateMemberID("Ava Scout"))
        }
        XCTAssertNoThrow(try PersonPolicy.validate(firstName: "Ava", lastName: "Scout", memberID: "1001", editingPersonID: existing.id, people: [existing]))
        XCTAssertNoThrow(try PersonPolicy.validate(firstName: "Ben", lastName: "Scout", memberID: "", editingPersonID: nil, people: [existing]))
        XCTAssertThrowsError(try PersonPolicy.validate(firstName: " ", lastName: "", memberID: "", editingPersonID: nil, people: []))
    }

    func testPostingValidationRejectsInactiveAccounts() {
        let active = UUID()
        let archived = UUID()
        XCTAssertEqual(
            PeriodLocking.validatePosting(accountID: archived, date: Date(), isAdjustment: false, adjustsTransactionID: nil, adjustmentReason: "", reconciliations: [], activeAccountIDs: [active]),
            .inactiveAccount
        )
        XCTAssertEqual(
            PeriodLocking.validatePosting(accountID: active, date: Date(), isAdjustment: false, adjustsTransactionID: nil, adjustmentReason: "", reconciliations: [], activeAccountIDs: [active]),
            .valid
        )
    }

    @MainActor
    func testBatchDepositRejectsFutureDepositDates() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let undeposited = AccountRecord(name: "Undeposited Funds", kind: .undepositedFunds)
        let checking = AccountRecord(name: "Checking", kind: .checking)
        let receipt = LedgerTransaction(accountID: undeposited.id, date: Date(), direction: .income, amountCents: 1_000, payee: "Family", category: "Dues")
        context.insert(undeposited)
        context.insert(checking)
        context.insert(receipt)
        try context.save()
        XCTAssertThrowsError(try BatchDepositService.post(
            destinationAccountID: checking.id,
            depositDate: Date().addingTimeInterval(2 * 86_400),
            reference: "",
            notes: "",
            sourceTransactionIDs: [receipt.id],
            sourceCashReceiptIDs: [],
            reconciliations: [],
            in: context
        )) { error in
            XCTAssertEqual(error as? BatchDepositError, .depositDateInFuture)
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<DepositBatchRecord>()).count, 0)
    }

    @MainActor
    func testEventCloseoutRefusesEventsThatHaveNotEndedOrFutureCloseDates() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let event = EventRecord(name: "Campout", startDate: Date(), endDate: Date().addingTimeInterval(3 * 86_400))
        let participant = EventParticipant(eventID: event.id, personID: nil, status: .registered)
        participant.guestName = "Guest"
        context.insert(event)
        context.insert(participant)
        let preview = try EventCloseoutService.makePreview(event: event, participants: [participant], people: [], transactions: [], financialEntries: [])
        XCTAssertThrowsError(try EventCloseoutService.post(preview: preview, event: event, closeDate: Date(), notes: "", postMemberAdjustments: false, existingCloseouts: [], in: context)) { error in
            XCTAssertEqual(error as? EventCloseoutError, .eventNotEnded)
        }
        event.endDate = Date().addingTimeInterval(-86_400)
        XCTAssertThrowsError(try EventCloseoutService.post(preview: preview, event: event, closeDate: Date().addingTimeInterval(5 * 86_400), notes: "", postMemberAdjustments: false, existingCloseouts: [], in: context)) { error in
            XCTAssertEqual(error as? EventCloseoutError, .closeDateInFuture)
        }
        XCTAssertNil(event.closedAt)
    }

    func testFamilyStatementRejectsFutureAsOfDates() {
        let family = FamilyRecord(name: "Family")
        let member = PersonRecord(firstName: "Ava", lastName: "Scout", role: .scout)
        member.familyID = family.id
        XCTAssertThrowsError(try FamilyStatementService.makeSnapshot(
            family: family, people: [member], entries: [], events: [],
            periodStart: Date(), asOfDate: Date().addingTimeInterval(3 * 86_400)
        )) { error in
            XCTAssertEqual(error as? FamilyStatementError, .asOfDateInFuture)
        }
    }

    @MainActor
    func testAuditChangesListOnlyFieldsThatDiffer() {
        let before = [("Name", "Checking"), ("Opening balance", "$100.00"), ("Notes", "")]
        let after = [("Name", "Checking"), ("Opening balance", "$250.00"), ("Notes", "Moved bank")]
        let changes = AuditLogger.changes(from: before, to: after)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.first?.0, "Changed Opening balance")
        XCTAssertEqual(changes.first?.1, "$100.00 → $250.00")
        XCTAssertEqual(changes.last?.1, "(empty) → Moved bank")
    }

    func testTreasurerReportGroupsCategoriesIgnoringWhitespace() {
        let day = Date(timeIntervalSince1970: 1_756_800_000)
        let account = AccountRecord(name: "Checking")
        let first = LedgerTransaction(accountID: account.id, date: day, direction: .income, amountCents: 100, payee: "A", category: "Dues")
        let second = LedgerTransaction(accountID: account.id, date: day, direction: .income, amountCents: 200, payee: "B", category: " Dues ")
        let blank = LedgerTransaction(accountID: account.id, date: day, direction: .income, amountCents: 50, payee: "C", category: "   ")
        let report = TreasurerReportService.makeSnapshot(title: "Test", periodStart: day, periodEnd: day, profile: nil, accounts: [account], transactions: [first, second, blank], people: [], memberEntries: [], reconciliations: [])
        XCTAssertEqual(report.income.map(\.category).sorted(), ["Dues", "Uncategorized"])
        XCTAssertEqual(report.income.first { $0.category == "Dues" }?.amountCents, 300)
    }
}
