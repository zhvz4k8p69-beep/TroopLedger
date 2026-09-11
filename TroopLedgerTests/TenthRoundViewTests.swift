import MapKit
import XCTest
@testable import TroopLedger

// Tenth audit round regressions.
@MainActor
final class TenthRoundViewTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    // MARK: Reconciliation

    func testNextStatementDateAdvancesToEndOfFollowingMonth() {
        let next = ReconciliationView.nextStatementDate(after: date(2026, 1, 31), now: date(2026, 3, 15), calendar: calendar)
        XCTAssertTrue(calendar.isDate(next, inSameDayAs: date(2026, 2, 28)))
        // A leap year still lands on the last day.
        let leap = ReconciliationView.nextStatementDate(after: date(2028, 1, 31), now: date(2028, 6, 1), calendar: calendar)
        XCTAssertTrue(calendar.isDate(leap, inSameDayAs: date(2028, 2, 29)))
    }

    func testNextStatementDateNeverMovesIntoTheFuture() {
        let today = date(2026, 9, 10)
        let next = ReconciliationView.nextStatementDate(after: date(2026, 8, 31), now: today, calendar: calendar)
        XCTAssertTrue(calendar.isDate(next, inSameDayAs: today))
        XCTAssertLessThanOrEqual(next, today)
    }

    // MARK: Accounts

    func testHoldingAccountsCannotOpenOverdrawn() {
        XCTAssertNotNil(AccountFormView.openingBalanceIssue(kind: .cash, cents: -1))
        XCTAssertNotNil(AccountFormView.openingBalanceIssue(kind: .undepositedFunds, cents: -5_000))
        XCTAssertNil(AccountFormView.openingBalanceIssue(kind: .cash, cents: 0))
        XCTAssertNil(AccountFormView.openingBalanceIssue(kind: .undepositedFunds, cents: 2_500))
        // A bank account may legitimately start overdrawn.
        XCTAssertNil(AccountFormView.openingBalanceIssue(kind: .checking, cents: -12_000))
    }

    // MARK: Events

    func testCalendarOpensOnTodayWhenThisMonthHasEvents() {
        let today = date(2026, 9, 10)
        let earlier = EventRecord(name: "Court of Honor", startDate: date(2026, 9, 3), endDate: date(2026, 9, 3))
        let later = EventRecord(name: "Fall Campout", startDate: date(2026, 9, 26), endDate: date(2026, 9, 27))
        // Newest first, the way the list query delivers them.
        let selection = EventCalendarView.initialSelection(events: [later, earlier], today: today, calendar: calendar)
        XCTAssertTrue(calendar.isDate(selection, inSameDayAs: today), "Opened on \(selection) instead of today")
    }

    func testCalendarFallsBackToNearestFutureEventThenToday() {
        let today = date(2026, 9, 10)
        let past = EventRecord(name: "Summer Camp", startDate: date(2026, 7, 12), endDate: date(2026, 7, 18))
        let november = EventRecord(name: "Klondike", startDate: date(2026, 11, 14), endDate: date(2026, 11, 15))
        let december = EventRecord(name: "Holiday Party", startDate: date(2026, 12, 12), endDate: date(2026, 12, 12))
        let selection = EventCalendarView.initialSelection(events: [december, november, past], today: today, calendar: calendar)
        XCTAssertTrue(calendar.isDate(selection, inSameDayAs: november.startDate))
        XCTAssertTrue(calendar.isDate(EventCalendarView.initialSelection(events: [past], today: today, calendar: calendar), inSameDayAs: today))
    }

    func testCalendarBucketsEachCoveredDayInsideTheVisibleMonth() throws {
        let interval = try XCTUnwrap(calendar.dateInterval(of: .month, for: date(2026, 9, 1)))
        let campout = EventRecord(name: "Campout", startDate: date(2026, 8, 30), endDate: date(2026, 9, 2))
        let meeting = EventRecord(name: "Meeting", startDate: date(2026, 9, 2, hour: 19), endDate: date(2026, 9, 2, hour: 20))
        let october = EventRecord(name: "October", startDate: date(2026, 10, 3), endDate: date(2026, 10, 3))
        let buckets = EventCalendarView.eventsByDay([campout, meeting, october], in: interval, calendar: calendar)

        XCTAssertEqual(buckets[calendar.startOfDay(for: date(2026, 9, 1))]?.map(\.name), ["Campout"])
        XCTAssertEqual(Set(buckets[calendar.startOfDay(for: date(2026, 9, 2))]?.map(\.name) ?? []), ["Campout", "Meeting"])
        XCTAssertNil(buckets[calendar.startOfDay(for: date(2026, 9, 3))])
        XCTAssertNil(buckets[calendar.startOfDay(for: date(2026, 8, 31))], "Days outside the visible month are not bucketed")
        XCTAssertFalse(buckets.values.joined().contains { $0.name == "October" })
    }

    func testEventNetPrefersImportedActualsPerEvent() {
        let withImports = UUID()
        let ledgerOnly = UUID()
        let projected = EventFinancialEntry(eventID: withImports, date: Date(), direction: .expense, amountCents: 99_900, description: "Projected food")
        projected.isProjected = true
        let actualIncome = EventFinancialEntry(eventID: withImports, date: Date(), direction: .income, amountCents: 40_000, description: "Fees")
        let actualExpense = EventFinancialEntry(eventID: withImports, date: Date(), direction: .expense, amountCents: 15_000, description: "Food")
        let projectedOnly = EventFinancialEntry(eventID: ledgerOnly, date: Date(), direction: .expense, amountCents: 5_000, description: "Projected")
        projectedOnly.isProjected = true
        let ignoredTransaction = LedgerTransaction(accountID: nil, date: Date(), direction: .expense, amountCents: 1_000, payee: "Ignored", category: "Food")
        ignoredTransaction.eventID = withImports
        let income = LedgerTransaction(accountID: nil, date: Date(), direction: .income, amountCents: 12_000, payee: "Fees", category: "Events")
        income.eventID = ledgerOnly
        let expense = LedgerTransaction(accountID: nil, date: Date(), direction: .expense, amountCents: 2_000, payee: "Council", category: "Events")
        expense.eventID = ledgerOnly

        let net = EventListView.netByEvent(entries: [projected, actualIncome, actualExpense, projectedOnly], transactions: [ignoredTransaction, income, expense])
        XCTAssertEqual(net[withImports], 25_000, "Non-projected imports win over linked transactions")
        XCTAssertEqual(net[ledgerOnly], 10_000, "Projected-only worksheets fall back to the ledger")
        XCTAssertNil(net[UUID()])
    }

    func testRosterHeadcountExcludesCancelledParticipants() {
        let eventID = UUID()
        let registered = EventParticipant(eventID: eventID, personID: UUID(), status: .registered)
        let attended = EventParticipant(eventID: eventID, personID: UUID(), status: .attended)
        let cancelled = EventParticipant(eventID: eventID, personID: UUID(), status: .cancelled)
        XCTAssertEqual(EventListView.rosterHeadcount([registered, cancelled, attended]), 2)
        XCTAssertEqual(EventListView.rosterHeadcount([cancelled]), 0)
    }

    func testParticipantsAreOrderedDeterministically() {
        let eventID = UUID()
        let first = EventParticipant(eventID: eventID, personID: UUID())
        first.createdAt = date(2026, 9, 1)
        let second = EventParticipant(eventID: eventID, personID: UUID())
        second.createdAt = date(2026, 9, 2)
        let tieA = EventParticipant(eventID: eventID, personID: UUID())
        tieA.createdAt = date(2026, 9, 3)
        let tieB = EventParticipant(eventID: eventID, personID: UUID())
        tieB.createdAt = date(2026, 9, 3)

        let forward = EventDetailView.ordered([tieB, second, tieA, first]).map(\.id)
        let backward = EventDetailView.ordered([first, tieA, second, tieB]).map(\.id)
        XCTAssertEqual(forward, backward)
        XCTAssertEqual(Array(forward.prefix(2)), [first.id, second.id])
        XCTAssertEqual(Set(forward.suffix(2)), [tieA.id, tieB.id])
    }

    func testCloseDateRangeStartsWhenTheEventEndedAndEndsToday() {
        let now = date(2026, 9, 10, hour: 15)
        let range = EventCloseoutView.closeDateRange(eventEnd: date(2026, 9, 6, hour: 11), now: now, calendar: calendar)
        XCTAssertTrue(calendar.isDate(range.lowerBound, inSameDayAs: date(2026, 9, 6)))
        XCTAssertFalse(range.contains(date(2026, 9, 5)))
        XCTAssertTrue(range.contains(date(2026, 9, 6, hour: 0)))
        XCTAssertTrue(range.contains(now))
        XCTAssertFalse(range.contains(date(2026, 9, 11)))
        // An event that has not ended yet still yields a valid (single-day) range so the picker cannot crash.
        let future = EventCloseoutView.closeDateRange(eventEnd: date(2026, 10, 1), now: now, calendar: calendar)
        XCTAssertLessThanOrEqual(future.lowerBound, future.upperBound)
    }

    // MARK: People

    func testRegistrationExpirationFollowsRegisteredDate() {
        let registered = date(2026, 9, 1)
        XCTAssertEqual(RegistrationFormView.adjustedExpiration(date(2026, 3, 1), registeredOn: registered, calendar: calendar), registered)
        let later = date(2027, 8, 31)
        XCTAssertEqual(RegistrationFormView.adjustedExpiration(later, registeredOn: registered, calendar: calendar), later)
        // Same day counts as valid, regardless of the time of day on either side.
        let sameDayMorning = date(2026, 9, 1, hour: 6)
        XCTAssertEqual(RegistrationFormView.adjustedExpiration(sameDayMorning, registeredOn: registered, calendar: calendar), sameDayMorning)
    }

    func testMemberPaymentsCannotBeFutureDated() {
        let now = date(2026, 9, 10)
        XCTAssertNotNil(MemberEntryFormView.dateIssue(kind: .payment, date: date(2026, 9, 11), now: now, calendar: calendar))
        XCTAssertNil(MemberEntryFormView.dateIssue(kind: .payment, date: date(2026, 9, 10, hour: 23), now: now, calendar: calendar))
        XCTAssertNil(MemberEntryFormView.dateIssue(kind: .payment, date: date(2026, 9, 1), now: now, calendar: calendar))
        // Charges and adjustments may carry a future due date.
        XCTAssertNil(MemberEntryFormView.dateIssue(kind: .charge, date: date(2026, 10, 1), now: now, calendar: calendar))
        XCTAssertNil(MemberEntryFormView.dateIssue(kind: .adjustmentDecrease, date: date(2026, 10, 1), now: now, calendar: calendar))
    }

    func testInactiveBalanceSummaryKeepsAmountsDueApartFromCredits() {
        let owes = PersonRecord(firstName: "Owen", lastName: "Owes", role: .scout)
        owes.isActive = false
        let credit = PersonRecord(firstName: "Cara", lastName: "Credit", role: .scout)
        credit.isActive = false
        let settled = PersonRecord(firstName: "Sam", lastName: "Settled", role: .scout)
        settled.isActive = false
        let activeDebtor = PersonRecord(firstName: "Al", lastName: "Active", role: .scout)
        let balances: [UUID: Int64] = [owes.id: 5_000, credit.id: -5_000, settled.id: 0, activeDebtor.id: 9_000]

        let summary = PeopleListView.inactiveBalanceSummary(people: [owes, credit, settled, activeDebtor], balances: balances)
        XCTAssertEqual(summary, PeopleListView.InactiveBalanceSummary(count: 2, dueCents: 5_000, creditCents: 5_000))
        let message = PeopleListView.inactiveBalanceMessage(summary)
        XCTAssertTrue(message.contains("2 inactive people"))
        XCTAssertTrue(message.contains("$50.00 due"))
        XCTAssertTrue(message.contains("$50.00 in credits"))
        XCTAssertFalse(message.contains("$0.00"), "Netting a debt against a credit hid both: \(message)")
    }

    // MARK: Deposits

    func testReceiptsDatedAfterTheDepositAreFlagged() {
        let deposit = date(2026, 9, 10, hour: 9)
        XCTAssertTrue(BatchDepositBuilderView.isReceivedAfterDeposit(received: date(2026, 9, 11, hour: 8), depositDate: deposit, calendar: calendar))
        XCTAssertFalse(BatchDepositBuilderView.isReceivedAfterDeposit(received: date(2026, 9, 10, hour: 22), depositDate: deposit, calendar: calendar), "Same calendar day is fine even when the receipt's time is later")
        XCTAssertFalse(BatchDepositBuilderView.isReceivedAfterDeposit(received: date(2026, 9, 1), depositDate: deposit, calendar: calendar))
    }

    // MARK: Dashboard

    func testDashboardMetricsFlagEveryOpenCloseTask() {
        let now = date(2026, 9, 10)
        let checking = AccountRecord(name: "Checking", kind: .checking, openingBalanceCents: 100_000)
        let undeposited = AccountRecord(name: "Undeposited Funds", kind: .undepositedFunds)
        let cashBox = AccountRecord(name: "Cash Box", kind: .cash, openingBalanceCents: 2_000)
        let unclearedCheck = LedgerTransaction(accountID: checking.id, date: date(2026, 8, 20), direction: .expense, amountCents: 4_000, payee: "Council", category: "Registration")
        let clearedDeposit = LedgerTransaction(accountID: checking.id, date: date(2026, 9, 1), direction: .income, amountCents: 10_000, payee: "Family", category: "Dues")
        clearedDeposit.isCleared = true
        let unclearedCash = LedgerTransaction(accountID: cashBox.id, date: date(2026, 8, 1), direction: .income, amountCents: 500, payee: "Popcorn", category: "Fundraising")
        let waitingCheck = LedgerTransaction(accountID: undeposited.id, date: date(2026, 8, 21), direction: .income, amountCents: 7_500, payee: "Family", category: "Dues")
        let scout = PersonRecord(firstName: "Test", lastName: "Scout", role: .scout)
        let charge = MemberLedgerEntry(personID: scout.id, date: now, kind: .charge, amountCents: 6_000, category: "Dues")
        let request = ReimbursementRequest(requesterPersonID: scout.id, purchaseDate: now, purpose: "Rope", category: "Supplies", amountCents: 1_200)
        let upcoming = EventRecord(name: "Campout", startDate: date(2026, 9, 20), endDate: date(2026, 9, 21))
        let cancelled = EventRecord(name: "Cancelled", startDate: date(2026, 9, 22), endDate: date(2026, 9, 22))
        cancelled.status = .cancelled
        let past = EventRecord(name: "Past", startDate: date(2026, 8, 1), endDate: date(2026, 8, 2))

        let metrics = DashboardMetrics(
            accounts: [checking, undeposited, cashBox],
            transactions: [unclearedCheck, clearedDeposit, unclearedCash, waitingCheck],
            people: [scout],
            memberEntries: [charge],
            events: [past, upcoming, cancelled],
            reconciliations: [],
            reimbursements: [request],
            attachments: [],
            depositAllocations: [],
            budgets: [],
            budgetLines: [],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(metrics.primaryAccount?.id, checking.id)
        XCTAssertEqual(metrics.unclearedBankTransactionCount, 1, "Cash-box entries never clear")
        XCTAssertTrue(calendar.isDate(metrics.oldestUnclearedDate ?? .distantPast, inSameDayAs: date(2026, 8, 20)))
        XCTAssertEqual(metrics.oldestUndepositedAgeDays, 20)
        XCTAssertTrue(metrics.undepositedIsStale)
        XCTAssertEqual(metrics.cashPosition.undepositedFundsCents, 7_500)
        XCTAssertEqual(metrics.outstandingMemberBalancesCents, 6_000)
        XCTAssertEqual(metrics.activeMemberCount, 1)
        XCTAssertEqual(metrics.missingReceiptCount, 1)
        XCTAssertNil(metrics.currentBudgetRemainingCents)
        XCTAssertFalse(metrics.reconciliationIsCurrent)
        XCTAssertEqual(metrics.closeTasksComplete, 0)
        XCTAssertEqual(metrics.attentionCount, 5)
        XCTAssertEqual(metrics.upcomingEvents.map(\.name), ["Campout"])
    }

    func testDashboardMetricsRecogniseACaughtUpMonth() {
        let now = date(2026, 9, 10)
        let checking = AccountRecord(name: "Checking", kind: .checking, openingBalanceCents: 100_000)
        let period = ReportingPeriod.containing(now)
        let spent = LedgerTransaction(accountID: checking.id, date: date(2026, 9, 3), direction: .expense, amountCents: 30_000, payee: "Camp", category: "Camping")
        spent.isCleared = true
        let transfer = LedgerTransaction(accountID: checking.id, date: date(2026, 9, 4), direction: .expense, amountCents: 50_000, payee: "Transfer", category: "Transfer")
        transfer.isCleared = true
        transfer.isTransfer = true
        let budget = OperatingBudgetRecord(reportingYearStart: period.startingYear, status: .approved, revision: 1)
        let staleWorking = OperatingBudgetRecord(reportingYearStart: period.startingYear, status: .working)
        let line = BudgetLineRecord(budgetID: budget.id, categoryID: nil, categoryName: "Camping", direction: .expense, amountCents: 120_000)
        let incomeLine = BudgetLineRecord(budgetID: budget.id, categoryID: nil, categoryName: "Dues", direction: .income, amountCents: 500_000)
        let request = ReimbursementRequest(requesterPersonID: nil, purchaseDate: now, purpose: "Rope", category: "Supplies", amountCents: 1_200)
        let attachment = ReimbursementAttachment(requestID: request.id, filename: "receipt.jpg", mediaType: "image/jpeg", byteCount: 1, sha256: "x", data: Data([0]))
        let reconciliation = ReconciliationRecord(accountID: checking.id, statementDate: date(2026, 8, 31), statementEndingBalanceCents: 70_000, clearedBalanceCents: 70_000)

        let metrics = DashboardMetrics(
            accounts: [checking],
            transactions: [spent, transfer],
            people: [],
            memberEntries: [],
            events: [],
            reconciliations: [reconciliation],
            reimbursements: [request],
            attachments: [attachment],
            depositAllocations: [],
            budgets: [staleWorking, budget],
            budgetLines: [line, incomeLine],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(metrics.currentBudgetRemainingCents, 90_000, "Transfers are not spending")
        XCTAssertTrue(metrics.reconciliationIsCurrent)
        XCTAssertEqual(metrics.missingReceiptCount, 0)
        XCTAssertNil(metrics.oldestUndepositedAgeDays)
        XCTAssertFalse(metrics.undepositedIsStale)
        XCTAssertEqual(metrics.closeTasksComplete, 4)
        XCTAssertEqual(metrics.attentionCount, 0)
    }

    // MARK: Location cache

    func testLocationSearchCacheNormalisesQueriesAndRemembersMisses() {
        let cache = EventLocationSearchCache(limit: 2)
        XCTAssertNil(cache.result(for: "Camp Squanto"))
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 41.9, longitude: -70.7)))
        cache.store(item, for: "  Camp Squanto ")
        XCTAssertTrue(cache.result(for: "camp squanto") == .some(item))
        cache.store(nil, for: "Nowhere Field")
        // A miss is remembered as "looked up, nothing found" rather than "never looked up".
        XCTAssertNotNil(cache.result(for: "nowhere field"))
        XCTAssertTrue(cache.result(for: "nowhere field") == .some(nil))
        cache.store(item, for: "Third Place")
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.result(for: "Camp Squanto"), "Oldest entry is evicted first")
    }

    // MARK: App lock

    func testEnablingTheLockDoesNotLockTheNextWindowOnTheSameLaunch() {
        let lock = AppLockState()
        XCTAssertTrue(AppLockGate.shouldLockOnAppear(isEnabled: true, hasUnlockedThisLaunch: lock.hasUnlockedThisLaunch, isLocked: lock.isLocked))
        lock.acknowledgePresentUser()
        XCTAssertFalse(AppLockGate.shouldLockOnAppear(isEnabled: true, hasUnlockedThisLaunch: lock.hasUnlockedThisLaunch, isLocked: lock.isLocked))
        XCTAssertFalse(AppLockGate.shouldLockOnAppear(isEnabled: false, hasUnlockedThisLaunch: false, isLocked: false))
        XCTAssertFalse(AppLockGate.shouldLockOnAppear(isEnabled: true, hasUnlockedThisLaunch: false, isLocked: true), "An already-locked gate does not prompt twice")
    }
}
