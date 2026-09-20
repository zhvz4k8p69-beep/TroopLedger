import SwiftData
import XCTest
@testable import TroopLedger

/// Importing a reconciliation plan written by the `troopledger` MCP server.
final class ReconciliationPlanTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
    }

    // MARK: - Fixture

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let account: AccountRecord
        let deposit: LedgerTransaction
        let check: LedgerTransaction
        let older: LedgerTransaction
        let march: LedgerTransaction
        let alreadyCleared: LedgerTransaction

        var transactions: [LedgerTransaction] { [deposit, check, older, march, alreadyCleared] }
        var reconciliations: [ReconciliationRecord] {
            (try? context.fetch(FetchDescriptor<ReconciliationRecord>())) ?? []
        }
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let account = AccountRecord(name: "Checking Account", institution: "Test Bank", kind: .checking, openingBalanceCents: 10_000)
        context.insert(account)
        let alreadyCleared = LedgerTransaction(accountID: account.id, date: try date(2026, 1, 10), direction: .income, amountCents: 5_000, payee: "Deposit", category: "Camping")
        alreadyCleared.isCleared = true
        let deposit = LedgerTransaction(accountID: account.id, date: try date(2026, 2, 3), direction: .income, amountCents: 4_000, payee: "Deposit", category: "Camping")
        let check = LedgerTransaction(accountID: account.id, date: try date(2026, 2, 17), direction: .expense, amountCents: 1_272, payee: "Scout Shop", category: "Advancement")
        check.checkNumber = "202"
        let older = LedgerTransaction(accountID: account.id, date: try date(2026, 1, 27), direction: .income, amountCents: 12_000, payee: "Deposit", category: "Camping")
        let march = LedgerTransaction(accountID: account.id, date: try date(2026, 3, 2), direction: .expense, amountCents: 999, payee: "Future", category: "Camping")
        for transaction in [alreadyCleared, deposit, check, older, march] { context.insert(transaction) }
        try context.save()
        return Fixture(container: container, context: context, account: account, deposit: deposit, check: check, older: older, march: march, alreadyCleared: alreadyCleared)
    }

    /// The exact shape `mcp/troopledger_mcp.py` writes (`render_plan`).
    private func planJSON(
        account: AccountRecord,
        clear: [UUID],
        tentative: [UUID] = [],
        ending: Int64,
        additions: [[String: Any]] = [],
        format: String = ReconciliationPlan.supportedFormat,
        statementDate: String = "2026-02-28",
        needsReview: Int = 0
    ) throws -> Data {
        let object: [String: Any] = [
            "format": format,
            "generated_at": "2026-09-20T09:00:00-04:00",
            "account_id": account.id.uuidString.lowercased(),
            "account_name": account.name,
            "statement_date": statementDate,
            "statement_ending_balance_cents": ending,
            "statement_beginning_balance_cents": NSNull(),
            "clear_transaction_ids": clear.map { $0.uuidString.lowercased() },
            "tentative_transaction_ids": tentative.map { $0.uuidString.lowercased() },
            "add_transactions": additions,
            "ties_after_adjustments": true,
            "needs_review": needsReview,
            "notes": "February statement",
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func fee(_ payee: String = "Test Bank", status: String = "accepted") -> [String: Any] {
        ["date": "2026-02-28", "direction": "Expense", "amount_cents": 500, "payee": payee, "category": "Bank Fees",
         "check_number": "", "memo": "Per bank statement 2026-02-28", "status": status]
    }

    // MARK: - Decoding

    @MainActor
    func testDecodesSnakeCasePlan() throws {
        let account = AccountRecord(name: "Checking Account")
        let data = try planJSON(account: account, clear: [UUID()], ending: 100, additions: [fee()])
        let plan = try ReconciliationPlanImporter.decode(data)
        XCTAssertEqual(plan.accountId, account.id.uuidString.lowercased())
        XCTAssertEqual(plan.statementEndingBalanceCents, 100)
        XCTAssertNil(plan.statementBeginningBalanceCents)
        XCTAssertEqual(plan.addTransactions?.first?.amountCents, 500)
        XCTAssertEqual(plan.addTransactions?.first?.checkNumber, "")
        XCTAssertEqual(plan.notes, "February statement")
    }

    @MainActor
    func testRejectsUnknownFormatAndGarbage() throws {
        let account = AccountRecord(name: "Checking Account")
        XCTAssertThrowsError(try ReconciliationPlanImporter.decode(try planJSON(account: account, clear: [], ending: 0, format: "troopledger-reconciliation-plan/9"))) { error in
            XCTAssertEqual(error as? ReconciliationPlanError, .unsupportedFormat("troopledger-reconciliation-plan/9"))
        }
        XCTAssertThrowsError(try ReconciliationPlanImporter.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try ReconciliationPlanImporter.decode(Data(count: ReconciliationPlanImporter.maximumFileBytes + 1))) { error in
            XCTAssertEqual(error as? ReconciliationPlanError, .fileTooLarge)
        }
    }

    @MainActor
    func testParseDateLandsOnTheIntendedDay() throws {
        let parsed = try XCTUnwrap(ReconciliationPlanImporter.parseDate("2026-02-28", calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: parsed), DateComponents(year: 2026, month: 2, day: 28))
        XCTAssertNil(ReconciliationPlanImporter.parseDate("2026-02-30", calendar: calendar))
        XCTAssertNil(ReconciliationPlanImporter.parseDate("02/28/2026", calendar: calendar))
    }

    // MARK: - Preview

    @MainActor
    func testPreviewComputesBalancesAndFlagsTentativeItems() throws {
        let f = try makeFixture()
        // 10,000 opening + 5,000 cleared = 15,000 before; +4,000 -1,272 cleared, -500 fee = 17,228.
        let plan = try ReconciliationPlanImporter.decode(try planJSON(account: f.account, clear: [f.deposit.id, f.check.id], tentative: [f.check.id], ending: 17_228, additions: [fee()]))
        let preview = try ReconciliationPlanImporter.preview(plan, accounts: [f.account], transactions: f.transactions, reconciliations: [], calendar: calendar, now: try date(2026, 9, 20))
        XCTAssertEqual(preview.clearedBeforeCents, 15_000)
        XCTAssertEqual(preview.clearedAfterCents, 17_228)
        XCTAssertEqual(preview.differenceCents, 0)
        XCTAssertTrue(preview.problems.isEmpty, preview.problems.joined(separator: "\n"))
        XCTAssertTrue(preview.canApply)
        XCTAssertEqual(preview.clearItems.map(\.isTentative), [false, true])
        XCTAssertEqual(preview.warnings.count, 1)
        XCTAssertTrue(preview.warnings[0].contains("tentative"))
        XCTAssertEqual(preview.additions.first?.signedAmountCents, -500)
    }

    @MainActor
    func testPreviewReportsEveryLedgerMismatchAsAProblem() throws {
        let f = try makeFixture()
        let other = AccountRecord(name: "Savings", kind: .savings)
        f.context.insert(other)
        let foreign = LedgerTransaction(accountID: other.id, date: try date(2026, 2, 5), direction: .income, amountCents: 100, payee: "x", category: "y")
        f.context.insert(foreign)
        let ghost = UUID()
        let plan = try ReconciliationPlanImporter.decode(try planJSON(
            account: f.account,
            clear: [f.deposit.id, f.alreadyCleared.id, f.march.id, foreign.id, ghost],
            ending: 19_000
        ))
        let preview = try ReconciliationPlanImporter.preview(plan, accounts: [f.account, other], transactions: f.transactions + [foreign], reconciliations: [], calendar: calendar, now: try date(2026, 9, 20))
        XCTAssertEqual(preview.clearItems.map(\.id), [f.deposit.id])
        XCTAssertEqual(preview.problems.count, 4, preview.problems.joined(separator: "\n"))
        XCTAssertTrue(preview.problems.contains { $0.contains("already cleared") })
        XCTAssertTrue(preview.problems.contains { $0.contains("after the statement date") })
        XCTAssertTrue(preview.problems.contains { $0.contains("different account") })
        XCTAssertTrue(preview.problems.contains { $0.contains("no longer in the ledger") })
        XCTAssertFalse(preview.canApply)
    }

    @MainActor
    func testPreviewRejectsLockedFutureAndOutOfBalancePlans() throws {
        let f = try makeFixture()
        let lock = ReconciliationRecord(accountID: f.account.id, statementDate: try date(2026, 2, 28), statementEndingBalanceCents: 0, clearedBalanceCents: 0)
        f.context.insert(lock)
        let locked = try ReconciliationPlanImporter.decode(try planJSON(account: f.account, clear: [f.deposit.id], ending: 19_000))
        var preview = try ReconciliationPlanImporter.preview(locked, accounts: [f.account], transactions: f.transactions, reconciliations: [lock], calendar: calendar, now: try date(2026, 9, 20))
        XCTAssertTrue(preview.problems.contains { $0.contains("already reconciled through") })

        let future = try ReconciliationPlanImporter.decode(try planJSON(account: f.account, clear: [f.deposit.id], ending: 19_000, statementDate: "2026-03-31"))
        preview = try ReconciliationPlanImporter.preview(future, accounts: [f.account], transactions: f.transactions, reconciliations: [], calendar: calendar, now: try date(2026, 3, 15))
        XCTAssertTrue(preview.problems.contains { $0.contains("in the future") })

        let stale = try ReconciliationPlanImporter.decode(try planJSON(account: f.account, clear: [f.deposit.id], ending: 19_001))
        preview = try ReconciliationPlanImporter.preview(stale, accounts: [f.account], transactions: f.transactions, reconciliations: [], calendar: calendar, now: try date(2026, 9, 20))
        XCTAssertEqual(preview.differenceCents, 1)
        XCTAssertTrue(preview.problems.contains { $0.contains("would show") })
        XCTAssertFalse(preview.canApply)
    }

    @MainActor
    func testPreviewFallsBackToAccountNameAndRejectsUnknownAccounts() throws {
        let f = try makeFixture()
        var data = try planJSON(account: f.account, clear: [f.deposit.id], ending: 19_000)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["account_id"] = UUID().uuidString
        data = try JSONSerialization.data(withJSONObject: object)
        let byName = try ReconciliationPlanImporter.preview(try ReconciliationPlanImporter.decode(data), accounts: [f.account], transactions: f.transactions, reconciliations: [], calendar: calendar, now: try date(2026, 9, 20))
        XCTAssertEqual(byName.account.id, f.account.id)

        object["account_name"] = "Nobody's Account"
        data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try ReconciliationPlanImporter.preview(try ReconciliationPlanImporter.decode(data), accounts: [f.account], transactions: f.transactions, reconciliations: [])) { error in
            XCTAssertEqual(error as? ReconciliationPlanError, .accountNotFound("Nobody's Account"))
        }
    }

    // MARK: - Apply

    @MainActor
    func testApplyAddsClearsLocksAndLogs() throws {
        let f = try makeFixture()
        let adjustment: [String: Any] = [
            "date": "2026-02-21", "direction": "Expense", "amount_cents": 900, "payee": "Scout Shop", "category": "Advancement",
            "check_number": "", "memo": "Adjust check #202 to bank amount -$21.72",
            "adjusts_transaction_id": f.check.id.uuidString.lowercased(), "status": "proposed",
        ]
        // 15,000 + 4,000 - 1,272 - 500 - 900 = 16,328
        let plan = try ReconciliationPlanImporter.decode(try planJSON(account: f.account, clear: [f.deposit.id, f.check.id], ending: 16_328, additions: [fee(), adjustment]))
        let now = try date(2026, 9, 20)
        let preview = try ReconciliationPlanImporter.preview(plan, accounts: [f.account], transactions: f.transactions, reconciliations: [], calendar: calendar, now: now)
        XCTAssertTrue(preview.canApply, preview.problems.joined(separator: "\n"))

        let record = try ReconciliationPlanImporter.apply(preview, transactions: f.transactions, reconciliations: [], calendar: calendar, now: now, in: f.context)
        XCTAssertEqual(record.statementEndingBalanceCents, 16_328)
        XCTAssertEqual(record.clearedBalanceCents, 16_328)
        XCTAssertEqual(record.notes, "February statement")

        let all = try f.context.fetch(FetchDescriptor<LedgerTransaction>())
        XCTAssertEqual(all.count, 7)
        let added = all.filter { $0.payee == "Test Bank" || $0.isAdjustment }
        XCTAssertEqual(added.count, 2)
        let feeRecord = try XCTUnwrap(added.first { $0.payee == "Test Bank" })
        XCTAssertEqual(feeRecord.category, "Bank Fees")
        XCTAssertEqual(feeRecord.signedAmountCents, -500)
        XCTAssertTrue(feeRecord.isCleared)
        XCTAssertEqual(feeRecord.reconciliationID, record.id)
        let adjustmentRecord = try XCTUnwrap(added.first { $0.isAdjustment })
        XCTAssertEqual(adjustmentRecord.adjustsTransactionID, f.check.id)
        XCTAssertEqual(adjustmentRecord.adjustmentReason, "Adjust check #202 to bank amount -$21.72")
        XCTAssertTrue(f.deposit.isCleared)
        XCTAssertTrue(f.check.isCleared)
        XCTAssertFalse(f.older.isCleared)
        XCTAssertFalse(f.march.isCleared)

        let audit = try f.context.fetch(FetchDescriptor<AuditLogEntry>())
        XCTAssertEqual(audit.filter { $0.actionRaw == AuditAction.create.rawValue }.count, 2)
        let reconcile = try XCTUnwrap(audit.first { $0.actionRaw == AuditAction.reconcile.rawValue })
        XCTAssertTrue(reconcile.details.contains("Source: Reconciliation plan"))
        XCTAssertTrue(reconcile.details.contains("Transactions cleared: 4"))
        XCTAssertEqual(audit.filter { $0.actionRaw == AuditAction.lockPeriod.rawValue }.count, 1)
        XCTAssertEqual(PeriodLocking.latestLockDate(for: f.account.id, reconciliations: f.reconciliations, calendar: calendar), calendar.startOfDay(for: try date(2026, 2, 28)))
    }

    @MainActor
    func testApplyRollsBackWhenCompletionFails() throws {
        let f = try makeFixture()
        let plan = try ReconciliationPlanImporter.decode(try planJSON(account: f.account, clear: [f.deposit.id], ending: 18_500, additions: [fee()]))
        let preview = try ReconciliationPlanImporter.preview(plan, accounts: [f.account], transactions: f.transactions, reconciliations: [], calendar: calendar, now: try date(2026, 9, 20))
        XCTAssertTrue(preview.canApply)
        // The ledger moves on after the preview: someone clears the deposit by hand, so the plan's selection is
        // no longer eligible and completion must refuse — and the fee it had already inserted must not survive.
        f.deposit.isCleared = true
        try f.context.save()
        XCTAssertThrowsError(try ReconciliationPlanImporter.apply(preview, transactions: f.transactions, reconciliations: [], calendar: calendar, now: try date(2026, 9, 20), in: f.context)) { error in
            XCTAssertEqual(error as? ReconciliationCompletionError, .ineligibleSelection)
        }
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<LedgerTransaction>()).count, 5)
        XCTAssertTrue(f.reconciliations.isEmpty)
        XCTAssertTrue(try f.context.fetch(FetchDescriptor<AuditLogEntry>()).isEmpty)
    }

    @MainActor
    func testApplyRefusesAPreviewWithProblems() throws {
        let f = try makeFixture()
        let plan = try ReconciliationPlanImporter.decode(try planJSON(account: f.account, clear: [f.deposit.id], ending: 1))
        let preview = try ReconciliationPlanImporter.preview(plan, accounts: [f.account], transactions: f.transactions, reconciliations: [], calendar: calendar, now: try date(2026, 9, 20))
        XCTAssertThrowsError(try ReconciliationPlanImporter.apply(preview, transactions: f.transactions, reconciliations: [], in: f.context)) { error in
            XCTAssertEqual(error as? ReconciliationPlanError, .cannotApply)
        }
        XCTAssertFalse(f.deposit.isCleared)
    }

    // MARK: - Shared completion (the hand-worked path uses the same service)

    @MainActor
    func testCompletionServiceValidatesBeforeWriting() throws {
        let f = try makeFixture()
        XCTAssertThrowsError(try ReconciliationCompletionService.complete(
            account: f.account, statementDate: try date(2026, 2, 28), statementBalanceCents: 1, selectedTransactionIDs: [f.deposit.id],
            notes: "", transactions: f.transactions, reconciliations: [], calendar: calendar, now: try date(2026, 9, 20), in: f.context
        )) { error in
            XCTAssertEqual(error as? ReconciliationCompletionError, .outOfBalance)
        }
        XCTAssertTrue(f.reconciliations.isEmpty)
        let record = try ReconciliationCompletionService.complete(
            account: f.account, statementDate: try date(2026, 2, 28), statementBalanceCents: 19_000, selectedTransactionIDs: [f.deposit.id],
            notes: "  by hand  ", transactions: f.transactions, reconciliations: [], calendar: calendar, now: try date(2026, 9, 20), in: f.context
        )
        XCTAssertEqual(record.notes, "by hand")
        XCTAssertTrue(f.deposit.isCleared)
        XCTAssertEqual(f.deposit.reconciliationID, record.id)
    }
}
