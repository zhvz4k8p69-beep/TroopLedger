import Foundation
import SwiftData

struct StandardLedgerCategory: Equatable {
    let name: String
    let direction: TransactionDirection
}

enum CategoryCatalog {
    static let standardCategories: [StandardLedgerCategory] = [
        .init(name: "Dues", direction: .income),
        .init(name: "Registration Fees", direction: .income),
        .init(name: "Event Fees", direction: .income),
        .init(name: "Fundraising", direction: .income),
        .init(name: "Donations", direction: .income),
        .init(name: "Interest", direction: .income),
        .init(name: "Refunds and Rebates", direction: .income),
        .init(name: "Other Income", direction: .income),
        .init(name: "Registration and Recharter", direction: .expense),
        .init(name: "Camping and Activities", direction: .expense),
        .init(name: "Awards and Advancement", direction: .expense),
        .init(name: "Program Supplies", direction: .expense),
        .init(name: "Equipment", direction: .expense),
        .init(name: "Training", direction: .expense),
        .init(name: "Insurance", direction: .expense),
        .init(name: "Administrative", direction: .expense),
        .init(name: "Bank Fees", direction: .expense),
        .init(name: "Fundraising Expense", direction: .expense),
        .init(name: "Refunds", direction: .expense),
        .init(name: "Other Expense", direction: .expense),
    ]

    /// Adds the standard catalog and preserves distinct categories already used by imported or entered transactions.
    @discardableResult
    @MainActor
    static func seedMissingDefinitions(in context: ModelContext) throws -> Int {
        let existing = try context.fetch(FetchDescriptor<LedgerCategoryRecord>())
        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())
        var known = Set(existing.map { key(name: $0.name, direction: $0.direction) })
        var definitions = standardCategories.map { ($0.name, $0.direction, true) }

        let usedDefinitions = transactions.compactMap { transaction -> (String, TransactionDirection, Bool)? in
            let name = transaction.category.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return (name, transaction.direction, false)
        }
        .sorted {
            if $0.1.rawValue != $1.1.rawValue { return $0.1.rawValue < $1.1.rawValue }
            return $0.0.localizedStandardCompare($1.0) == .orderedAscending
        }
        definitions.append(contentsOf: usedDefinitions)

        var inserted = 0
        for (index, definition) in definitions.enumerated() {
            let definitionKey = key(name: definition.0, direction: definition.1)
            guard !known.contains(definitionKey) else { continue }
            context.insert(LedgerCategoryRecord(
                name: definition.0,
                direction: definition.1,
                isStandard: definition.2,
                sortOrder: index
            ))
            known.insert(definitionKey)
            inserted += 1
        }

        if inserted > 0 {
            AuditLogger.record(
                .create,
                recordType: "Category Catalog",
                recordID: nil,
                summary: "Added (inserted) missing ledger category definitions",
                in: context
            )
            try context.save()
        }
        return inserted
    }

    static func key(name: String, direction: TransactionDirection) -> String {
        "\(direction.rawValue.lowercased())|\(normalizedCategoryName(name))"
    }
}

struct BudgetVarianceLine: Identifiable, Equatable {
    let categoryName: String
    let direction: TransactionDirection
    let budgetCents: Int64
    let actualCents: Int64

    var id: String { CategoryCatalog.key(name: categoryName, direction: direction) }

    /// Positive is favorable: income above plan or expenses below plan.
    var varianceCents: Int64 {
        direction == .income ? actualCents - budgetCents : budgetCents - actualCents
    }
}

struct BudgetVarianceReport: Equatable {
    let income: [BudgetVarianceLine]
    let expenses: [BudgetVarianceLine]

    var budgetIncomeCents: Int64 { income.reduce(0) { $0 + $1.budgetCents } }
    var actualIncomeCents: Int64 { income.reduce(0) { $0 + $1.actualCents } }
    var budgetExpenseCents: Int64 { expenses.reduce(0) { $0 + $1.budgetCents } }
    var actualExpenseCents: Int64 { expenses.reduce(0) { $0 + $1.actualCents } }
    var budgetNetCents: Int64 { budgetIncomeCents - budgetExpenseCents }
    var actualNetCents: Int64 { actualIncomeCents - actualExpenseCents }
    var netVarianceCents: Int64 { actualNetCents - budgetNetCents }
}

enum BudgetEngine {
    static func varianceReport(
        period: ReportingPeriod,
        transactions: [LedgerTransaction],
        budgetLines: [BudgetLineRecord]
    ) -> BudgetVarianceReport {
        struct Accumulator {
            var name: String
            var direction: TransactionDirection
            var budgetCents: Int64 = 0
            var actualCents: Int64 = 0
        }

        var values: [String: Accumulator] = [:]
        for line in budgetLines {
            let name = displayCategoryName(line.categoryName)
            let key = CategoryCatalog.key(name: name, direction: line.direction)
            var value = values[key] ?? Accumulator(name: name, direction: line.direction)
            value.budgetCents += line.amountCents
            values[key] = value
        }
        for transaction in transactions where period.contains(transaction.date) && !transaction.isTransfer {
            let name = displayCategoryName(transaction.category)
            let key = CategoryCatalog.key(name: name, direction: transaction.direction)
            var value = values[key] ?? Accumulator(name: name, direction: transaction.direction)
            value.actualCents += transaction.amountCents
            values[key] = value
        }

        let lines = values.values.map {
            BudgetVarianceLine(
                categoryName: $0.name,
                direction: $0.direction,
                budgetCents: $0.budgetCents,
                actualCents: $0.actualCents
            )
        }
        let sorted: ([BudgetVarianceLine]) -> [BudgetVarianceLine] = { lines in
            lines.sorted { $0.categoryName.localizedStandardCompare($1.categoryName) == .orderedAscending }
        }
        return BudgetVarianceReport(
            income: sorted(lines.filter { $0.direction == .income }),
            expenses: sorted(lines.filter { $0.direction == .expense })
        )
    }

    private static func displayCategoryName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Uncategorized" : trimmed
    }
}

private func normalizedCategoryName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
}
