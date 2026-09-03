import Foundation

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
        let year = calendar.component(.year, from: date)
        switch self {
        case .schoolYear:
            return calendar.component(.month, from: date) >= 9 ? year : year - 1
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

    static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

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
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return "\(formatter.string(from: startDate)) – \(formatter.string(from: inclusiveEnd))"
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

    static func cashPosition(accounts: [AccountRecord], transactions: [LedgerTransaction]) -> CashPosition {
        let balances = accounts.map { account in
            (account: account, balance: bookBalance(account: account, transactions: transactions))
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

    static func annualReport(year: Int, transactions: [LedgerTransaction], calendar: Calendar = .current) -> AnnualReport {
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
        Dictionary(grouping: transactions, by: { $0.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Uncategorized" : $0.category })
            .map { CategoryTotal(category: $0.key, amountCents: $0.value.reduce(0) { $0 + $1.amountCents }) }
            .sorted {
                if $0.amountCents == $1.amountCents { return $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending }
                return $0.amountCents > $1.amountCents
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
            $0.personID == personID
                && $0.programYear.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedYear
        }) else {
            throw RegistrationValidationError.duplicateProgramYear
        }
    }
}

enum LedgerPostingValidation: Equatable {
    case valid
    case accountRequired
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
        calendar: Calendar = .current
    ) -> LedgerPostingValidation {
        guard accountID != nil else { return .accountRequired }
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

enum Money {
    /// Largest single amount the app accepts, in cents ($1 billion). Int64 arithmetic traps on overflow, so
    /// two imported rows near `Int64.max` would crash every balance calculation; a sane per-amount ceiling
    /// keeps sums of any realistic register far from the limit.
    static let maximumCents: Int64 = 100_000_000_000

    static func isWithinLimit(_ cents: Int64) -> Bool {
        cents >= -maximumCents && cents <= maximumCents
    }

    static func cents(from text: String) -> Int64? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        // Treasurers type what a bank statement shows: "$1,250.00". Strip the currency symbol before parsing.
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for symbol in Set(["$", Locale.current.currencySymbol ?? "$", formatter.currencySymbol ?? "$"]) where !symbol.isEmpty {
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
