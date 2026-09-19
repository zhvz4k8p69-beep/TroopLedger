import Foundation
import SwiftData

struct FundraiserBalance {
    var received: Int64 = 0
    var available: Int64 = 0
    var onHand: Int64 = 0
    var sold: Int64 = 0
    var lost: Int64 = 0
    var revenue: Int64 = 0
    var turnedIn: Int64 = 0
    var outstanding: Int64 { revenue - turnedIn }
}

struct FundraiserError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum FundraiserService {
    static func balance(_ activities: [FundraiserActivityRecord], personID: UUID? = nil) -> FundraiserBalance {
        var result = FundraiserBalance()
        for row in activities where row.voidedAt == nil {
            let matches = personID == nil || row.personID == personID
            switch FundraiserActivityKind(rawValue: row.kindRaw) {
            case .receive:
                if personID == nil { result.received += row.quantity; result.available += row.quantity }
            case .issue:
                result.available -= row.quantity
                if matches { result.onHand += row.quantity }
            case .returned:
                result.available += row.quantity
                if matches { result.onHand -= row.quantity }
            case .sale:
                if matches { result.onHand -= row.quantity; result.sold += row.quantity; result.revenue += row.amountCents }
            case .loss:
                if matches { result.onHand -= row.quantity; result.lost += row.quantity }
            case .remittance:
                if matches { result.turnedIn += row.amountCents }
            case nil: break
            }
        }
        return result
    }

    static func create(name: String, notes: String, in context: ModelContext) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FundraiserError(message: "Enter a fundraiser name.") }
        let record = FundraiserRecord(name: name, notes: notes)
        context.insert(record)
        try save("Created fundraiser \(name)", id: record.id, in: context)
    }

    static func addProduct(to fundraiser: FundraiserRecord, name: String, unit: String, cost: Int64, price: Int64, in context: ModelContext) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fundraiser.isArchived, !name.isEmpty, !unit.isEmpty, cost >= 0, price > 0,
              cost <= Money.maximumCents, price <= Money.maximumCents else {
            throw FundraiserError(message: "Enter a product, selling unit, nonnegative cost, and positive selling price in an active fundraiser.")
        }
        context.insert(FundraiserProductRecord(fundraiserID: fundraiser.id, name: name, unitName: unit, unitCostCents: cost, unitPriceCents: price))
        try save("Added \(name) to \(fundraiser.name)", id: fundraiser.id, in: context)
    }

    @discardableResult
    static func record(fundraiser: FundraiserRecord, product: FundraiserProductRecord, person: PersonRecord?, kind: FundraiserActivityKind,
                       quantity: Int64, amount: Int64, date: Date, notes: String, in context: ModelContext) throws -> FundraiserActivityRecord {
        guard !fundraiser.isArchived, product.fundraiserID == fundraiser.id else {
            throw FundraiserError(message: "Choose a product in this active fundraiser.")
        }
        guard !kind.needsSeller || person != nil else { throw FundraiserError(message: "Choose a seller.") }
        guard !kind.needsQuantity || (quantity > 0 && quantity <= 1_000_000) else {
            throw FundraiserError(message: "Enter a whole quantity from 1 to 1,000,000 selling units.")
        }
        guard date <= Date() else { throw FundraiserError(message: "Activity cannot be dated in the future.") }
        let q = kind.needsQuantity ? quantity : 0
        let calculated = q.multipliedReportingOverflow(by: product.unitCostCents)
        guard !calculated.overflow, calculated.partialValue <= Money.maximumCents else {
            throw FundraiserError(message: "This stock value exceeds the supported amount.")
        }
        let value: Int64 = kind == .receive ? calculated.partialValue : ([.sale, .remittance].contains(kind) ? amount : 0)
        guard value >= 0, value <= Money.maximumCents, kind != .remittance || value > 0 else {
            throw FundraiserError(message: "Enter a valid amount; money turned in must be positive.")
        }
        let row = FundraiserActivityRecord(fundraiserID: fundraiser.id, productID: product.id,
            personID: kind.needsSeller ? person?.id : nil, sellerName: kind.needsSeller ? person!.displayName : "Troop stock",
            kind: kind, quantity: q, amountCents: value, date: date, notes: notes)
        let existing = try context.fetch(FetchDescriptor<FundraiserActivityRecord>()).filter { $0.productID == product.id && $0.fundraiserID == fundraiser.id }
        try validate(existing + [row])
        context.insert(row)
        try save("\(fundraiser.name): \(kind.rawValue), \(product.name), \(row.sellerName), \(q) units, \(Money.currency(cents: value))", id: row.id, in: context)
        return row
    }

    /// Replay all dated activity so backdating or voiding cannot leave negative inventory or overpaid sellers.
    static func validate(_ activities: [FundraiserActivityRecord]) throws {
        let rows = activities.filter { $0.voidedAt == nil }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        var stock: Int64 = 0
        var sellers: [UUID: FundraiserBalance] = [:]
        for row in rows {
            guard let kind = FundraiserActivityKind(rawValue: row.kindRaw) else { throw FundraiserError(message: "Unknown activity type.") }
            if kind == .receive { stock += row.quantity; continue }
            guard let id = row.personID else { throw FundraiserError(message: "Activity is missing its seller.") }
            var seller = sellers[id, default: FundraiserBalance()]
            switch kind {
            case .receive: break
            case .issue: stock -= row.quantity; seller.onHand += row.quantity
            case .returned: stock += row.quantity; seller.onHand -= row.quantity
            case .sale: seller.onHand -= row.quantity; seller.revenue += row.amountCents
            case .loss: seller.onHand -= row.quantity
            case .remittance: seller.turnedIn += row.amountCents
            }
            guard stock >= 0, seller.onHand >= 0, seller.outstanding >= 0 else {
                throw FundraiserError(message: "This would leave insufficient stock or turn in more money than recorded sales. Check quantities, seller, product, and activity dates.")
            }
            sellers[id] = seller
        }
    }

    static func void(_ row: FundraiserActivityRecord, reason: String, in context: ModelContext) throws {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty, row.voidedAt == nil else { throw FundraiserError(message: "Enter a reason for voiding this activity.") }
        let campaigns = try context.fetch(FetchDescriptor<FundraiserRecord>())
        guard let campaign = campaigns.first(where: { $0.id == row.fundraiserID }), !campaign.isArchived else {
            throw FundraiserError(message: "Reopen the fundraiser before correcting activity.")
        }
        let rows = try context.fetch(FetchDescriptor<FundraiserActivityRecord>()).filter { $0.productID == row.productID && $0.fundraiserID == row.fundraiserID && $0.id != row.id }
        try validate(rows)
        row.voidedAt = Date()
        row.voidReason = reason
        try save("Voided fundraiser activity: \(row.kindRaw). Reason: \(reason)", id: row.id, in: context)
    }

    static func setArchived(_ fundraiser: FundraiserRecord, in context: ModelContext) throws {
        fundraiser.isArchived.toggle()
        try save("\(fundraiser.isArchived ? "Archived" : "Reopened") fundraiser \(fundraiser.name)", id: fundraiser.id, in: context)
    }

    private static func save(_ summary: String, id: UUID, in context: ModelContext) throws {
        AuditLogger.record(.edit, recordType: "Fundraiser", recordID: id, summary: summary, in: context)
        do { try context.save() } catch { context.rollback(); throw error }
    }
}
