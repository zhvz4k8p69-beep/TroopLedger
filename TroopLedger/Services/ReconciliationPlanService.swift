import Foundation
import SwiftData

// MARK: - Shared completion

/// Finishing a reconciliation — validating, clearing the chosen transactions, recording the lock, and writing the
/// audit trail — used to live only in `ReconciliationView.finish()`. The plan importer needs the identical steps, so
/// they live here and both callers go through one path.
@MainActor
enum ReconciliationCompletionService {
    @discardableResult
    static func complete(
        account: AccountRecord,
        statementDate: Date,
        statementBalanceCents: Int64,
        selectedTransactionIDs: Set<UUID>,
        notes: String,
        transactions: [LedgerTransaction],
        reconciliations: [ReconciliationRecord],
        source: String = "",
        calendar: Calendar = .current,
        now: Date = Date(),
        in modelContext: ModelContext
    ) throws -> ReconciliationRecord {
        let clearedBalance = FinanceEngine.clearedBalance(
            account: account,
            transactions: transactions,
            additionallyCleared: selectedTransactionIDs,
            through: statementDate,
            calendar: calendar
        )
        try ReconciliationCompletionPolicy.validate(
            account: account,
            statementDate: statementDate,
            statementBalanceCents: statementBalanceCents,
            clearedBalanceCents: clearedBalance,
            selectedTransactionIDs: selectedTransactionIDs,
            transactions: transactions,
            reconciliations: reconciliations,
            calendar: calendar,
            now: now
        )
        let record = ReconciliationRecord(
            accountID: account.id,
            statementDate: statementDate,
            statementEndingBalanceCents: statementBalanceCents,
            clearedBalanceCents: clearedBalance
        )
        record.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        modelContext.insert(record)
        var clearedDescriptions: [String] = []
        for transaction in transactions where selectedTransactionIDs.contains(transaction.id) {
            transaction.isCleared = true
            transaction.reconciledAt = now
            transaction.reconciliationID = record.id
            clearedDescriptions.append("\(transaction.id.uuidString.lowercased()) \(transaction.date.formatted(date: .numeric, time: .omitted)) \(Money.currency(cents: transaction.signedAmountCents))")
        }
        let statementLabel = statementDate.formatted(date: .long, time: .omitted)
        AuditLogger.record(
            .reconcile,
            recordType: "Reconciliation",
            recordID: record.id,
            summary: "Reconciled \(account.name) through \(statementLabel)",
            details: AuditLogger.details([
                ("Statement ending balance", Money.currency(cents: record.statementEndingBalanceCents)),
                ("Cleared balance", Money.currency(cents: record.clearedBalanceCents)),
                ("Transactions cleared", String(selectedTransactionIDs.count)),
                // An auditor needs to know which items this reconciliation cleared, not only how many.
                ("Cleared items", clearedDescriptions.sorted().joined(separator: "\n")),
                ("Source", source),
                ("Notes", record.notes),
            ]),
            at: now,
            in: modelContext
        )
        AuditLogger.record(
            .lockPeriod,
            recordType: "Account",
            recordID: account.id,
            summary: "Locked \(account.name) through \(statementLabel)",
            details: "Established by reconciliation \(record.id.uuidString)",
            at: now,
            in: modelContext
        )
        try modelContext.save()
        return record
    }
}

// MARK: - Plan file

/// A reconciliation plan written by the `troopledger` MCP server (`mcp/troopledger_mcp.py`): the statement's
/// ending balance, the ledger transactions the statement cleared, and the transactions (bank fees, interest,
/// corrections) that must be added for the ledger to tie. The server never writes to the store; the plan is
/// applied here, through the same validation as a hand-worked reconciliation, after the treasurer reviews it.
struct ReconciliationPlan: Decodable, Equatable {
    static let supportedFormat = "troopledger-reconciliation-plan/1"

    struct Addition: Decodable, Equatable {
        var date: String
        var direction: String
        var amountCents: Int64
        var payee: String
        var category: String
        var checkNumber: String?
        var memo: String?
        var adjustsTransactionId: String?
        var status: String?
    }

    var format: String
    var generatedAt: String?
    var accountId: String
    var accountName: String?
    var statementDate: String
    var statementEndingBalanceCents: Int64
    var statementBeginningBalanceCents: Int64?
    var clearTransactionIds: [String]
    var tentativeTransactionIds: [String]?
    var addTransactions: [Addition]?
    var tiesAfterAdjustments: Bool?
    var needsReview: Int?
    var notes: String?
}

enum ReconciliationPlanError: LocalizedError, Equatable {
    case fileTooLarge
    case unreadable(String)
    case unsupportedFormat(String)
    case accountNotFound(String)
    case invalidDate(String)
    case cannotApply

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: "That file is too large to be a reconciliation plan."
        case .unreadable(let detail): "The plan could not be read: \(detail)"
        case .unsupportedFormat(let format): "Unsupported plan format \"\(format)\". Expected \(ReconciliationPlan.supportedFormat)."
        case .accountNotFound(let name): "The plan is for \"\(name)\", which is not an account in this ledger."
        case .invalidDate(let value): "The plan contains an unreadable date: \"\(value)\"."
        case .cannotApply: "Resolve the listed problems before applying this plan."
        }
    }
}

struct ReconciliationPlanPreview: Identifiable {
    struct ClearItem: Identifiable {
        let transaction: LedgerTransaction
        let isTentative: Bool
        var id: UUID { transaction.id }
    }

    struct AddItem: Identifiable {
        let id = UUID()
        let date: Date
        let direction: TransactionDirection
        let amountCents: Int64
        let payee: String
        let category: String
        let checkNumber: String
        let memo: String
        let adjustsTransactionID: UUID?
        let isAccepted: Bool

        var signedAmountCents: Int64 { direction == .income ? amountCents : -amountCents }
    }

    let id = UUID()
    let plan: ReconciliationPlan
    let account: AccountRecord
    let statementDate: Date
    let clearItems: [ClearItem]
    let additions: [AddItem]
    let clearedBeforeCents: Int64
    let clearedAfterCents: Int64
    /// Blocks applying: the plan no longer matches the ledger, or would break a rule the app enforces.
    let problems: [String]
    /// Worth a look but not blocking: tentative matches, unresolved review items.
    let warnings: [String]

    var differenceCents: Int64 { plan.statementEndingBalanceCents - clearedAfterCents }
    var canApply: Bool { problems.isEmpty && differenceCents == 0 }
    var clearNetCents: Int64 { clearItems.reduce(0) { $0 + $1.transaction.signedAmountCents } }
    var additionsNetCents: Int64 { additions.reduce(0) { $0 + $1.signedAmountCents } }
}

@MainActor
enum ReconciliationPlanImporter {
    /// A plan for even a year of statements is a few hundred kilobytes; anything larger is not a plan.
    static let maximumFileBytes = 4_000_000
    static let sourceLabel = "Reconciliation plan"

    static func decode(_ data: Data) throws -> ReconciliationPlan {
        guard data.count <= maximumFileBytes else { throw ReconciliationPlanError.fileTooLarge }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let plan: ReconciliationPlan
        do {
            plan = try decoder.decode(ReconciliationPlan.self, from: data)
        } catch {
            throw ReconciliationPlanError.unreadable(error.localizedDescription)
        }
        guard plan.format == ReconciliationPlan.supportedFormat else {
            throw ReconciliationPlanError.unsupportedFormat(plan.format)
        }
        return plan
    }

    /// "2026-03-31" → noon that day in the given calendar, so the value stays on the intended day regardless of
    /// the zone SwiftData round-trips it through.
    static func parseDate(_ text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: components),
              calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day else {
            return nil
        }
        return date
    }

    static func preview(
        _ plan: ReconciliationPlan,
        accounts: [AccountRecord],
        transactions: [LedgerTransaction],
        reconciliations: [ReconciliationRecord],
        calendar: Calendar = .current,
        now: Date = Date()
    ) throws -> ReconciliationPlanPreview {
        let accountID = UUID(uuidString: plan.accountId)
        guard let account = accounts.first(where: { $0.id == accountID })
                ?? accounts.first(where: { $0.isActive && $0.name == plan.accountName }) else {
            throw ReconciliationPlanError.accountNotFound(plan.accountName ?? plan.accountId)
        }
        guard let statementDate = parseDate(plan.statementDate, calendar: calendar) else {
            throw ReconciliationPlanError.invalidDate(plan.statementDate)
        }

        var problems: [String] = []
        var warnings: [String] = []
        if !account.isActive {
            problems.append("\(account.name) is inactive; reactivate it before reconciling.")
        }
        if calendar.startOfDay(for: statementDate) > calendar.startOfDay(for: now) {
            problems.append("The statement date \(statementDate.formatted(date: .long, time: .omitted)) is in the future.")
        }
        if let lockDate = PeriodLocking.latestLockDate(for: account.id, reconciliations: reconciliations, calendar: calendar),
           calendar.startOfDay(for: statementDate) <= lockDate {
            problems.append("\(account.name) is already reconciled through \(lockDate.formatted(date: .long, time: .omitted)); this plan's statement date is not after it.")
        }

        let byID = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tentative = Set((plan.tentativeTransactionIds ?? []).compactMap(UUID.init(uuidString:)))
        var clearItems: [ReconciliationPlanPreview.ClearItem] = []
        var seen = Set<UUID>()
        for raw in plan.clearTransactionIds {
            guard let id = UUID(uuidString: raw) else {
                problems.append("\"\(raw)\" is not a transaction ID.")
                continue
            }
            guard seen.insert(id).inserted else { continue }
            guard let transaction = byID[id] else {
                problems.append("Transaction \(raw) is no longer in the ledger.")
                continue
            }
            let label = "\(transaction.date.formatted(date: .numeric, time: .omitted)) \(transaction.payee.isEmpty ? transaction.category : transaction.payee) \(Money.currency(cents: transaction.signedAmountCents))"
            if transaction.accountID != account.id {
                problems.append("\(label) belongs to a different account.")
            } else if transaction.isCleared {
                problems.append("\(label) was already cleared by an earlier reconciliation.")
            } else if !ReconciliationPolicy.isEligible(transaction, accountID: account.id, statementDate: statementDate, calendar: calendar) {
                problems.append("\(label) is dated after the statement date and cannot be cleared by this statement.")
            } else {
                clearItems.append(.init(transaction: transaction, isTentative: tentative.contains(id)))
            }
        }
        let tentativeCount = clearItems.filter(\.isTentative).count
        if tentativeCount > 0 {
            warnings.append("\(tentativeCount) of the items to clear were tentative matches in the plan (marked ?). Confirm them before applying.")
        }

        var additions: [ReconciliationPlanPreview.AddItem] = []
        for (index, raw) in (plan.addTransactions ?? []).enumerated() {
            let label = "Addition \(index + 1) (\(raw.payee))"
            guard let date = parseDate(raw.date, calendar: calendar) else {
                problems.append("\(label) has an unreadable date \"\(raw.date)\".")
                continue
            }
            guard let direction = TransactionDirection(rawValue: raw.direction) else {
                problems.append("\(label) has an unknown direction \"\(raw.direction)\".")
                continue
            }
            guard raw.amountCents > 0, Money.isWithinLimit(raw.amountCents) else {
                problems.append("\(label) has an invalid amount.")
                continue
            }
            if PeriodLocking.isLocked(accountID: account.id, date: date, reconciliations: reconciliations, calendar: calendar) {
                problems.append("\(label) is dated inside a locked period.")
                continue
            }
            if let endExclusive = ReconciliationPolicy.statementEndExclusive(for: statementDate, calendar: calendar), date >= endExclusive {
                problems.append("\(label) is dated after the statement date, so this statement could not clear it.")
                continue
            }
            var adjusts: UUID?
            if let target = raw.adjustsTransactionId, !target.isEmpty {
                guard let targetID = UUID(uuidString: target), let targetTransaction = byID[targetID] else {
                    problems.append("\(label) corrects a transaction that is no longer in the ledger.")
                    continue
                }
                if targetTransaction.accountID != account.id {
                    problems.append("\(label) corrects a transaction on a different account.")
                    continue
                }
                adjusts = targetID
            }
            let isAccepted = (raw.status ?? "").lowercased() == "accepted"
            if !isAccepted {
                warnings.append("\(label) was proposed by the matcher but not confirmed in the plan; it will still be added.")
            }
            additions.append(.init(
                date: date,
                direction: direction,
                amountCents: raw.amountCents,
                payee: raw.payee.trimmingCharacters(in: .whitespacesAndNewlines),
                category: raw.category.isEmpty ? "Uncategorized" : raw.category,
                checkNumber: raw.checkNumber ?? "",
                memo: raw.memo ?? "",
                adjustsTransactionID: adjusts,
                isAccepted: isAccepted
            ))
        }
        if let needsReview = plan.needsReview, needsReview > 0 {
            warnings.append("The plan still had \(needsReview) item\(needsReview == 1 ? "" : "s") awaiting review when it was written.")
        }

        let clearedBefore = FinanceEngine.clearedBalance(account: account, transactions: transactions, through: statementDate, calendar: calendar)
        let clearedAfter = clearedBefore
            + clearItems.reduce(0) { $0 + $1.transaction.signedAmountCents }
            + additions.reduce(0) { $0 + $1.signedAmountCents }
        if clearItems.isEmpty && additions.isEmpty {
            problems.append("The plan has nothing to clear or add.")
        }
        if problems.isEmpty && plan.statementEndingBalanceCents != clearedAfter {
            problems.append("After clearing and adding everything in the plan the ledger would show \(Money.currency(cents: clearedAfter)), not the statement's \(Money.currency(cents: plan.statementEndingBalanceCents)). The ledger has changed since the plan was written, or the plan was written with items still unresolved.")
        }
        return ReconciliationPlanPreview(
            plan: plan,
            account: account,
            statementDate: statementDate,
            clearItems: clearItems,
            additions: additions,
            clearedBeforeCents: clearedBefore,
            clearedAfterCents: clearedAfter,
            problems: problems,
            warnings: warnings
        )
    }

    /// Adds the plan's transactions, then completes the reconciliation over them plus the items to clear. Nothing
    /// is saved unless every step succeeds; a failure rolls the context back so a half-applied plan cannot
    /// leave stray fee entries behind.
    @discardableResult
    static func apply(
        _ preview: ReconciliationPlanPreview,
        transactions: [LedgerTransaction],
        reconciliations: [ReconciliationRecord],
        calendar: Calendar = .current,
        now: Date = Date(),
        in modelContext: ModelContext
    ) throws -> ReconciliationRecord {
        guard preview.canApply else { throw ReconciliationPlanError.cannotApply }
        let statementLabel = preview.statementDate.formatted(date: .long, time: .omitted)
        var inserted: [LedgerTransaction] = []
        do {
            for item in preview.additions {
                let record = LedgerTransaction(
                    accountID: preview.account.id,
                    date: item.date,
                    direction: item.direction,
                    amountCents: item.amountCents,
                    payee: item.payee,
                    category: item.category
                )
                record.checkNumber = item.checkNumber
                record.memo = item.memo
                record.createdAt = now
                record.modifiedAt = now
                if let target = item.adjustsTransactionID {
                    record.isAdjustment = true
                    record.adjustsTransactionID = target
                    record.adjustmentReason = item.memo.isEmpty ? "Per bank statement \(statementLabel)" : item.memo
                }
                modelContext.insert(record)
                inserted.append(record)
                AuditLogger.record(
                    .create,
                    recordType: "Transaction",
                    recordID: record.id,
                    summary: record.isAdjustment
                        ? "Created adjustment for \(record.payee) from reconciliation plan"
                        : "Created transaction \(record.payee) from reconciliation plan",
                    details: AuditLogger.details([
                        ("Date", record.date.formatted(date: .numeric, time: .omitted)),
                        ("Amount", Money.currency(cents: record.signedAmountCents)),
                        ("Category", record.category),
                        ("Corrects transaction ID", record.adjustsTransactionID?.uuidString),
                        ("Adjustment reason", record.adjustmentReason),
                        ("Source", "\(sourceLabel) for statement \(statementLabel)"),
                    ]),
                    at: now,
                    in: modelContext
                )
            }
            let selected = Set(preview.clearItems.map(\.id)).union(inserted.map(\.id))
            return try ReconciliationCompletionService.complete(
                account: preview.account,
                statementDate: preview.statementDate,
                statementBalanceCents: preview.plan.statementEndingBalanceCents,
                selectedTransactionIDs: selected,
                notes: preview.plan.notes ?? "",
                transactions: transactions + inserted,
                reconciliations: reconciliations,
                source: sourceLabel,
                calendar: calendar,
                now: now,
                in: modelContext
            )
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
