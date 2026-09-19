import Foundation
import SwiftData

@Model
final class FundraiserRecord {
    var id: UUID = UUID()
    var name: String = ""
    var notes: String = ""
    var createdAt: Date = Date()
    var isArchived: Bool = false

    init(name: String, notes: String = "") {
        self.name = name
        self.notes = notes
    }
}

/// Quantities always use the selling unit (one bar, bag, box, etc.), never an ambiguous case count.
/// A different cost or selling unit is represented by a separate product/lot to preserve historical margins.
@Model
final class FundraiserProductRecord {
    var id: UUID = UUID()
    var fundraiserID: UUID? = nil
    var name: String = ""
    var unitName: String = "item"
    var unitCostCents: Int64 = 0
    var unitPriceCents: Int64 = 0

    init(fundraiserID: UUID, name: String, unitName: String, unitCostCents: Int64, unitPriceCents: Int64) {
        self.fundraiserID = fundraiserID
        self.name = name
        self.unitName = unitName
        self.unitCostCents = unitCostCents
        self.unitPriceCents = unitPriceCents
    }
}

enum FundraiserActivityKind: String, CaseIterable, Identifiable {
    case receive = "Receive stock"
    case issue = "Issue to seller"
    case returned = "Return unsold stock"
    case sale = "Record sale"
    case remittance = "Money turned in"
    case loss = "Lost or damaged stock"
    var id: String { rawValue }
    var needsSeller: Bool { self != .receive }
    var needsQuantity: Bool { self != .remittance }
}

@Model
final class FundraiserActivityRecord {
    var id: UUID = UUID()
    var fundraiserID: UUID? = nil
    var productID: UUID? = nil
    var personID: UUID? = nil
    var sellerName: String = ""
    var kindRaw: String = ""
    var quantity: Int64 = 0
    var amountCents: Int64 = 0
    var date: Date = Date()
    var createdAt: Date = Date()
    var notes: String = ""
    var voidedAt: Date? = nil
    var voidReason: String = ""

    init(fundraiserID: UUID, productID: UUID, personID: UUID?, sellerName: String,
         kind: FundraiserActivityKind, quantity: Int64, amountCents: Int64, date: Date, notes: String) {
        self.fundraiserID = fundraiserID
        self.productID = productID
        self.personID = personID
        self.sellerName = sellerName
        self.kindRaw = kind.rawValue
        self.quantity = quantity
        self.amountCents = amountCents
        self.date = date
        self.notes = notes
    }
}
