import Foundation
import os

struct CategoryTotal: Identifiable, Equatable {
    var id: String { category }
    let category: String
    let amountCents: Int64
}

struct AnnualReport: Equatable {
    let income: [CategoryTotal]
    let expenses: [CategoryTotal]

    var totalIncomeCents: Int64 { income.reduce(0) { $0 + $1.amountCents } }
    var totalExpenseCents: Int64 { expenses.reduce(0) { $0 + $1.amountCents } }
    var netCents: Int64 { totalIncomeCents - totalExpenseCents }
}

struct CashPosition: Equatable {
    let bankAndCashOnHandCents: Int64
    let undepositedFundsCents: Int64

    var totalCents: Int64 { bankAndCashOnHandCents + undepositedFundsCents }
}

enum ReconciliationPolicy {
    static func statementEndExclusive(for statementDate: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: statementDate))
    }

    static func isEligible(
        _ transaction: LedgerTransaction,
        accountID: UUID?,
        statementDate: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let accountID, transaction.accountID == accountID, !transaction.isCleared else { return false }
        return statementEndExclusive(for: statementDate, calendar: calendar).map { transaction.date < $0 } ?? false
    }

    static func canEditOpeningBalance(_ account: AccountRecord, reconciliations: [ReconciliationRecord]) -> Bool {
        !reconciliations.contains { $0.accountID == account.id }
    }
}

enum ReconciliationCompletionError: LocalizedError, Equatable {
    case accountRequired
    case inactiveAccount
    case statementDateNotAfterLock(Date)
    case statementDateInFuture
    case outOfBalance
    case ineligibleSelection

    var errorDescription: String? {
        switch self {
        case .accountRequired: "Choose an account to reconcile."
        case .inactiveAccount: "Inactive accounts cannot receive a new reconciliation. Reactivate the account first."
        case .statementDateNotAfterLock(let date): "Choose a statement date after the existing lock through \(date.formatted(date: .long, time: .omitted))."
        case .statementDateInFuture: "A statement date cannot be in the future. Reconciling through a future date would lock the register until then."
        case .outOfBalance: "The reconciliation difference must be zero before finishing."
        case .ineligibleSelection: "The selected transactions changed or no longer belong to this account and statement period. Review the selection again."
        }
    }
}

enum ReconciliationCompletionPolicy {
    static func validate(
        account: AccountRecord?,
        statementDate: Date,
        statementBalanceCents: Int64,
        clearedBalanceCents: Int64,
        selectedTransactionIDs: Set<UUID>,
        transactions: [LedgerTransaction],
        reconciliations: [ReconciliationRecord],
        calendar: Calendar = .current,
        now: Date = Date()
    ) throws {
        guard let account else { throw ReconciliationCompletionError.accountRequired }
        guard account.isActive else { throw ReconciliationCompletionError.inactiveAccount }
        // A lock is irreversible in the app, so a mistyped future statement date would freeze posting
        // for every day up to that date.
        guard calendar.startOfDay(for: statementDate) <= calendar.startOfDay(for: now) else {
            throw ReconciliationCompletionError.statementDateInFuture
        }
        if let lockDate = PeriodLocking.latestLockDate(for: account.id, reconciliations: reconciliations, calendar: calendar),
           calendar.startOfDay(for: statementDate) <= lockDate {
            throw ReconciliationCompletionError.statementDateNotAfterLock(lockDate)
        }
        guard statementBalanceCents == clearedBalanceCents else { throw ReconciliationCompletionError.outOfBalance }
        let selectedTransactions = transactions.filter { selectedTransactionIDs.contains($0.id) }
        guard selectedTransactions.count == selectedTransactionIDs.count,
              selectedTransactions.allSatisfy({
                  ReconciliationPolicy.isEligible($0, accountID: account.id, statementDate: statementDate, calendar: calendar)
              }) else {
            throw ReconciliationCompletionError.ineligibleSelection
        }
    }
}

enum ReportingYearBasis: String, CaseIterable, Identifiable, Hashable {
    case schoolYear = "School Year"
    case calendarYear = "Calendar Year"

    var id: String { rawValue }

    var yearPickerLabel: String {
        switch self {
        case .schoolYear: "School year beginning"
        case .calendarYear: "Calendar year"
        }
    }

    func startingYear(containing date: Date, calendar: Calendar = ReportingPeriod.localCalendar) -> Int {
        // One decomposition instead of two; this runs once per transaction when the report year list is built.
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 0
        switch self {
        case .schoolYear:
            return (components.month ?? 1) >= 9 ? year : year - 1
        case .calendarYear:
            return year
        }
    }
}

struct ReportingPeriod: Equatable {
    let basis: ReportingYearBasis
    let startingYear: Int
    let startDate: Date
    let endDateExclusive: Date

    /// Stored rather than computed: this is the default argument on per-transaction paths, and building a
    /// Calendar plus a time-zone lookup on every call was measurable on large registers.
    static let localCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    init(basis: ReportingYearBasis, startingYear: Int, calendar: Calendar = localCalendar) {
        let startingMonth = basis == .schoolYear ? 9 : 1
        guard let startDate = calendar.date(from: DateComponents(year: startingYear, month: startingMonth, day: 1)),
              let endDateExclusive = calendar.date(byAdding: .year, value: 1, to: startDate) else {
            preconditionFailure("Unable to construct a 12-month reporting period")
        }
        self.basis = basis
        self.startingYear = startingYear
        self.startDate = startDate
        self.endDateExclusive = endDateExclusive
    }

    static func containing(
        _ date: Date,
        basis: ReportingYearBasis = .schoolYear,
        calendar: Calendar = localCalendar
    ) -> ReportingPeriod {
        ReportingPeriod(basis: basis, startingYear: basis.startingYear(containing: date, calendar: calendar), calendar: calendar)
    }

    var label: String {
        switch basis {
        case .schoolYear: "\(startingYear)–\(startingYear + 1) School Year"
        case .calendarYear: "\(startingYear) Calendar Year"
        }
    }

    var pickerLabel: String {
        switch basis {
        case .schoolYear: "\(startingYear)–\(startingYear + 1)"
        case .calendarYear: String(startingYear)
        }
    }

    func contains(_ date: Date) -> Bool {
        date >= startDate && date < endDateExclusive
    }

    func dateRangeLabel(calendar: Calendar = localCalendar) -> String {
        let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: endDateExclusive) ?? endDateExclusive
        let formatter = Self.rangeFormatter(for: calendar)
        return "\(formatter.string(from: startDate)) – \(formatter.string(from: inclusiveEnd))"
    }

    /// Cached per calendar and zone: the Reports, Budget, and treasurer-report screens call `dateRangeLabel`
    /// from their view bodies, and a fresh DateFormatter (ICU pattern generation plus locale data) was built
    /// on every render. DateFormatter is safe to share for formatting; the lock guards the dictionary.
    private static let rangeFormatters = OSAllocatedUnfairLock<[String: DateFormatter]>(initialState: [:])

    private static func rangeFormatter(for calendar: Calendar) -> DateFormatter {
        let key = "\(calendar.identifier)|\(calendar.timeZone.identifier)|\(calendar.locale?.identifier ?? "")"
        return rangeFormatters.withLock { cache in
            if let cached = cache[key] { return cached }
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateStyle = .long
            formatter.timeStyle = .none
            cache[key] = formatter
            return formatter
        }
    }
}

enum FinanceEngine {
    static func bookBalance(account: AccountRecord, transactions: [LedgerTransaction]) -> Int64 {
        return account.openingBalanceCents + transactions
            .filter { $0.accountID == account.id }
            .reduce(0) { $0 + $1.signedAmountCents }
    }

    static func clearedBalance(
        account: AccountRecord,
        transactions: [LedgerTransaction],
        additionallyCleared: Set<UUID> = [],
        through statementDate: Date? = nil,
        calendar: Calendar = .current
    ) -> Int64 {
        let endExclusive = statementDate.flatMap {
            ReconciliationPolicy.statementEndExclusive(for: $0, calendar: calendar)
        }
        return account.openingBalanceCents + transactions
            .filter { transaction in
                guard transaction.accountID == account.id,
                      transaction.isCleared || additionallyCleared.contains(transaction.id) else {
                    return false
                }
                return endExclusive.map { transaction.date < $0 } ?? true
            }
            .reduce(0) { $0 + $1.signedAmountCents }
    }

    static func memberBalance(personID: UUID, entries: [MemberLedgerEntry]) -> Int64 {
        entries
            .filter { $0.personID == personID }
            .reduce(0) { $0 + $1.balanceEffectCents }
    }

    /// Every member's balance in one pass. Rosters and dashboards used to call `memberBalance` per person,
    /// which rescanned the whole entry list for each row.
    static func memberBalances(entries: [MemberLedgerEntry]) -> [UUID: Int64] {
        entries.reduce(into: [:]) { result, entry in
            guard let personID = entry.personID else { return }
            result[personID, default: 0] += entry.balanceEffectCents
        }
    }

    /// Every account's book balance in one pass over the register.
    static func bookBalances(accounts: [AccountRecord], transactions: [LedgerTransaction]) -> [UUID: Int64] {
        var totals = transactions.reduce(into: [UUID: Int64]()) { result, transaction in
            guard let accountID = transaction.accountID else { return }
            result[accountID, default: 0] += transaction.signedAmountCents
        }
        for account in accounts { totals[account.id, default: 0] += account.openingBalanceCents }
        return totals
    }

    static func cashPosition(accounts: [AccountRecord], transactions: [LedgerTransaction]) -> CashPosition {
        let balanceByAccount = bookBalances(accounts: accounts, transactions: transactions)
        let balances = accounts.map { account in
            (account: account, balance: balanceByAccount[account.id] ?? account.openingBalanceCents)
        }
        // An archived account can still hold historical cash. Keep it in reports until its balance is zero.
        let reportable = balances.filter { $0.account.isActive || $0.balance != 0 }
        let undeposited = reportable
            .filter { $0.account.kind == .undepositedFunds }
            .reduce(0) { $0 + $1.balance }
        let bankAndCash = reportable
            .filter { $0.account.kind != .undepositedFunds }
            .reduce(0) { $0 + $1.balance }
        return CashPosition(bankAndCashOnHandCents: bankAndCash, undepositedFundsCents: undeposited)
    }

    static func annualReport(year: Int, transactions: [LedgerTransaction], calendar: Calendar = ReportingPeriod.localCalendar) -> AnnualReport {
        annualReport(
            period: ReportingPeriod(basis: .calendarYear, startingYear: year, calendar: calendar),
            transactions: transactions
        )
    }

    static func annualReport(period: ReportingPeriod, transactions: [LedgerTransaction]) -> AnnualReport {
        let included = transactions.filter { period.contains($0.date) && !$0.isTransfer }
        return AnnualReport(
            income: totals(for: included.filter { $0.direction == .income }),
            expenses: totals(for: included.filter { $0.direction == .expense })
        )
    }

    private static func totals(for transactions: [LedgerTransaction]) -> [CategoryTotal] {
        categoryTotals(for: transactions)
            .sorted {
                if $0.amountCents == $1.amountCents { return $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending }
                return $0.amountCents > $1.amountCents
            }
    }

    /// One total per category, grouped on the same folded key the budget variance report uses, so "Dues",
    /// " Dues" and "dues" are one line instead of three. Shared by the Reports screen and the treasurer
    /// report so both documents show the same category lines; callers choose the sort order.
    static func categoryTotals(for transactions: [LedgerTransaction]) -> [CategoryTotal] {
        Dictionary(grouping: transactions, by: { CategoryCatalog.key(name: $0.category, direction: $0.direction) })
            .map { _, group in
                let name = group[0].category.trimmingCharacters(in: .whitespacesAndNewlines)
                return CategoryTotal(category: name.isEmpty ? "Uncategorized" : name, amountCents: group.reduce(0) { $0 + $1.amountCents })
            }
    }
}

enum RegistrationValidationError: LocalizedError, Equatable {
    case programYearRequired
    case negativeDues
    case expirationBeforeRegistration
    case duplicateProgramYear

    var errorDescription: String? {
        switch self {
        case .programYearRequired: "Enter a registration program year."
        case .negativeDues: "Dues assessed cannot be negative."
        case .expirationBeforeRegistration: "The expiration date cannot be before the registration date."
        case .duplicateProgramYear: "This person already has a registration for that program year. Edit the existing registration instead."
        }
    }
}

enum RegistrationPolicy {
    static func validate(
        personID: UUID,
        programYear: String,
        registeredOn: Date,
        expiresOn: Date?,
        duesAssessedCents: Int64,
        registrations: [RegistrationRecord],
        excluding editingRegistrationID: UUID? = nil,
        calendar: Calendar = .current
    ) throws {
        let normalizedYear = programYear.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedYear.isEmpty else { throw RegistrationValidationError.programYearRequired }
        guard duesAssessedCents >= 0 else { throw RegistrationValidationError.negativeDues }
        if let expiresOn {
            guard calendar.startOfDay(for: expiresOn) >= calendar.startOfDay(for: registeredOn) else {
                throw RegistrationValidationError.expirationBeforeRegistration
            }
        }
        guard !registrations.contains(where: {
            $0.id != editingRegistrationID
                && $0.personID == personID
                && $0.programYear.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedYear
        }) else {
            throw RegistrationValidationError.duplicateProgramYear
        }
    }

    /// A registration that a posted charge batch used as its dues source must stay so the batch's history holds.
    static func canDelete(_ registration: RegistrationRecord, allocations: [RecurringChargeAllocationRecord]) -> Bool {
        !allocations.contains { $0.registrationID == registration.id }
    }
}

enum HoldingAccountValidationError: LocalizedError, Equatable {
    case wouldOverdraw(accountName: String, shortfallCents: Int64)

    var errorDescription: String? {
        switch self {
        case .wouldOverdraw(let name, let shortfall):
            "\(name) would go \(Money.currency(cents: shortfall)) below zero. Cash boxes and Undeposited Funds can only pay out money that was received."
        }
    }
}

enum HoldingAccountPolicy {
    /// Undeposited Funds and Cash on Hand hold physical money; an entry that spends more than they contain
    /// records cash that never existed. Bank accounts may legitimately overdraw and are not checked.
    static func validate(
        account: AccountRecord,
        transactions: [LedgerTransaction],
        editing editedTransactionID: UUID?,
        direction: TransactionDirection,
        amountCents: Int64
    ) throws {
        guard account.kind == .cash || account.kind == .undepositedFunds else { return }
        // Shrinking or re-directing an existing receipt can overdraw the box just as a new expense can, so the
        // projection is computed for both directions rather than only for expenses.
        let others = transactions.filter { $0.id != editedTransactionID }
        let delta: Int64 = direction == .income ? amountCents : -amountCents
        let projected = FinanceEngine.bookBalance(account: account, transactions: others) + delta
        if projected < 0 {
            throw HoldingAccountValidationError.wouldOverdraw(accountName: account.name, shortfallCents: -projected)
        }
    }

    /// Deleting a receipt, or moving it to another account, must not leave the account it came from negative.
    static func validateRemoval(of transaction: LedgerTransaction, from account: AccountRecord, transactions: [LedgerTransaction]) throws {
        guard account.kind == .cash || account.kind == .undepositedFunds else { return }
        let projected = FinanceEngine.bookBalance(account: account, transactions: transactions.filter { $0.id != transaction.id })
        if projected < 0 {
            throw HoldingAccountValidationError.wouldOverdraw(accountName: account.name, shortfallCents: -projected)
        }
    }
}

enum LinkedTransactionValidationError: LocalizedError, Equatable {
    case linkedToReimbursement
    case linkedToMemberPayment

    var errorDescription: String? {
        switch self {
        case .linkedToReimbursement: "This entry pays a reimbursement request. Its account, type, and amount are fixed; reopen or re-record the reimbursement instead."
        case .linkedToMemberPayment: "This entry is the bank receipt behind a member-ledger payment. Its account, type, and amount are fixed while that link exists."
        }
    }
}

enum LinkedTransactionPolicy {
    /// A transaction that another money record points at (a paid reimbursement, a member payment's bank
    /// receipt) may still get a better memo or category, but its money fields must not drift away from the
    /// record that relies on them.
    static func validateEdit(
        of transaction: LedgerTransaction,
        newAccountID: UUID?,
        newDirection: TransactionDirection,
        newAmountCents: Int64,
        reimbursements: [ReimbursementRequest],
        memberEntries: [MemberLedgerEntry]
    ) throws {
        let moneyChanged = transaction.accountID != newAccountID
            || transaction.direction != newDirection
            || transaction.amountCents != newAmountCents
        guard moneyChanged else { return }
        if reimbursements.contains(where: { $0.linkedTransactionID == transaction.id }) {
            throw LinkedTransactionValidationError.linkedToReimbursement
        }
        if memberEntries.contains(where: { $0.accountTransactionID == transaction.id }) {
            throw LinkedTransactionValidationError.linkedToMemberPayment
        }
    }
}

/// Decides when the optional device lock engages. Kept free of UI so the rule can be tested.
enum AppLockPolicy {
    static let storageKey = "security.requiresDeviceAuthentication"
    /// A Mac left unattended never moves the app to the background; lock after this long without focus.
    static let inactivityTimeout: TimeInterval = 5 * 60

    static func shouldLock(isEnabled: Bool, movedToBackground: Bool, alreadyLocked: Bool) -> Bool {
        guard isEnabled else { return false }
        return alreadyLocked || movedToBackground
    }

    static func shouldLockAfterInactivity(isEnabled: Bool, inactiveSince: Date?, now: Date = Date()) -> Bool {
        guard isEnabled, let inactiveSince else { return false }
        return now.timeIntervalSince(inactiveSince) >= inactivityTimeout
    }
}

/// Picks the account a money screen should start on. Alphabetical order put "Cash Box" ahead of
/// "Troop 51 Checking", so bank imports, deposits, and reimbursement payments defaulted to the cash box.
enum AccountSelectionPolicy {
    static func defaultOperatingAccount(in accounts: [AccountRecord]) -> AccountRecord? {
        let active = accounts.filter(\.isActive)
        return active.first { $0.kind == .checking }
            ?? active.first { $0.kind == .savings }
            ?? active.first { $0.kind == .other }
            ?? active.first { $0.kind == .cash }
    }
}

enum LedgerPostingValidation: Equatable {
    case valid
    case accountRequired
    case inactiveAccount
    case locked(through: Date)
    case adjustmentTargetRequired
    case adjustmentReasonRequired
}

enum PeriodLocking {
    static func latestLockDate(
        for accountID: UUID?,
        reconciliations: [ReconciliationRecord],
        calendar: Calendar = .current
    ) -> Date? {
        guard let accountID else { return nil }
        return reconciliations
            .filter { $0.accountID == accountID }
            .map { calendar.startOfDay(for: $0.statementDate) }
            .max()
    }

    static func isLocked(
        accountID: UUID?,
        date: Date,
        reconciliations: [ReconciliationRecord],
        calendar: Calendar = .current
    ) -> Bool {
        guard let lockDate = latestLockDate(for: accountID, reconciliations: reconciliations, calendar: calendar) else {
            return false
        }
        return calendar.startOfDay(for: date) <= lockDate
    }

    static func isLocked(
        _ transaction: LedgerTransaction,
        reconciliations: [ReconciliationRecord],
        calendar: Calendar = .current
    ) -> Bool {
        isLocked(
            accountID: transaction.accountID,
            date: transaction.date,
            reconciliations: reconciliations,
            calendar: calendar
        )
    }

    /// The latest lock date per account, computed once so a register of thousands of rows does not rescan
    /// every reconciliation for each row it draws.
    static func lockDates(reconciliations: [ReconciliationRecord], calendar: Calendar = .current) -> [UUID: Date] {
        reconciliations.reduce(into: [:]) { result, reconciliation in
            guard let accountID = reconciliation.accountID else { return }
            let day = calendar.startOfDay(for: reconciliation.statementDate)
            if let existing = result[accountID], existing >= day { return }
            result[accountID] = day
        }
    }

    static func isLocked(_ transaction: LedgerTransaction, lockDates: [UUID: Date], calendar: Calendar = .current) -> Bool {
        guard let accountID = transaction.accountID, let lockDate = lockDates[accountID] else { return false }
        return calendar.startOfDay(for: transaction.date) <= lockDate
    }

    static func firstUnlockedDate(
        for accountID: UUID?,
        reconciliations: [ReconciliationRecord],
        relativeTo proposedDate: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        guard let lockDate = latestLockDate(for: accountID, reconciliations: reconciliations, calendar: calendar),
              let dayAfterLock = calendar.date(byAdding: .day, value: 1, to: lockDate),
              calendar.startOfDay(for: proposedDate) <= lockDate else {
            return proposedDate
        }
        return dayAfterLock
    }

    static func validatePosting(
        accountID: UUID?,
        date: Date,
        isAdjustment: Bool,
        adjustsTransactionID: UUID?,
        adjustmentReason: String,
        reconciliations: [ReconciliationRecord],
        calendar: Calendar = .current,
        activeAccountIDs: Set<UUID>? = nil
    ) -> LedgerPostingValidation {
        guard let accountID else { return .accountRequired }
        // Deposits and reimbursement payments already refuse archived accounts; manual entries must too.
        if let activeAccountIDs, !activeAccountIDs.contains(accountID) { return .inactiveAccount }
        if let lockDate = latestLockDate(for: accountID, reconciliations: reconciliations, calendar: calendar),
           calendar.startOfDay(for: date) <= lockDate {
            return .locked(through: lockDate)
        }
        if isAdjustment {
            guard adjustsTransactionID != nil else { return .adjustmentTargetRequired }
            guard !adjustmentReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .adjustmentReasonRequired
            }
        }
        return .valid
    }
}

enum MemberEntryValidationError: LocalizedError, Equatable {
    case invalidAmount
    case categoryRequired
    case adjustmentReasonRequired

    var errorDescription: String? {
        switch self {
        case .invalidAmount: "Enter an amount greater than zero."
        case .categoryRequired: "Enter a member-ledger category."
        case .adjustmentReasonRequired: "Explain why this balance adjustment is needed. Adjustments change what a family owes without a charge or payment behind them."
        }
    }
}

enum MemberEntryPolicy {
    static func validate(kind: MemberEntryKind, amountCents: Int64?, category: String, notes: String) throws {
        guard let amountCents, amountCents > 0 else { throw MemberEntryValidationError.invalidAmount }
        guard !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MemberEntryValidationError.categoryRequired }
        if kind == .adjustmentIncrease || kind == .adjustmentDecrease,
           notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MemberEntryValidationError.adjustmentReasonRequired
        }
    }
}

enum PersonValidationError: LocalizedError, Equatable {
    case nameRequired
    case duplicateMemberID(String)

    var errorDescription: String? {
        switch self {
        case .nameRequired: "Enter a first or last name."
        case .duplicateMemberID(let name): "That Scouting Member ID already belongs to \(name). Each person needs a distinct ID so imports update the right record."
        }
    }
}

enum PersonPolicy {
    static func validate(firstName: String, lastName: String, memberID: String, editingPersonID: UUID?, people: [PersonRecord]) throws {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty || !last.isEmpty else { throw PersonValidationError.nameRequired }
        let id = memberID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if let other = people.first(where: {
            $0.id != editingPersonID && $0.scoutingMemberID.trimmingCharacters(in: .whitespacesAndNewlines) == id
        }) {
            throw PersonValidationError.duplicateMemberID(other.displayName)
        }
    }
}

enum Money {
    /// Largest single amount the app accepts, in cents ($1 billion). Int64 arithmetic traps on overflow, so
    /// two imported rows near `Int64.max` would crash every balance calculation; a sane per-amount ceiling
    /// keeps sums of any realistic register far from the limit.
    static let maximumCents: Int64 = 100_000_000_000

    static func isWithinLimit(_ cents: Int64) -> Bool {
        cents >= -maximumCents && cents <= maximumCents
    }

    /// Built once: `cents(from:)` runs from `canSave` on every keystroke of every money field, and a fresh
    /// NumberFormatter costs an ICU formatter plus locale data each time. NumberFormatter is safe to share
    /// for non-mutating use.
    nonisolated(unsafe) private static let parsingFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        formatter.generatesDecimalNumbers = true
        return formatter
    }()

    private static let currencySymbols: Set<String> = {
        let formatter = parsingFormatter
        return Set(["$", Locale.current.currencySymbol ?? "$", formatter.currencySymbol ?? "$"]).filter { !$0.isEmpty }
    }()

    static func cents(from text: String) -> Int64? {
        let formatter = parsingFormatter
        // Treasurers type what a bank statement shows: "$1,250.00". Strip the currency symbol before parsing.
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for symbol in currencySymbols {
            cleaned = cleaned.replacingOccurrences(of: symbol, with: "")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = formatter.number(from: cleaned) else { return nil }
        var scaled = number.decimalValue * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded <= Decimal(maximumCents), rounded >= Decimal(-maximumCents) else { return nil }
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    static func editableString(cents: Int64) -> String {
        let amount = Decimal(cents) / 100
        return amount.formatted(.number.precision(.fractionLength(2)))
    }

    static func currency(cents: Int64) -> String {
        let amount = Decimal(cents) / 100
        return amount.formatted(.currency(code: "USD"))
    }
}
