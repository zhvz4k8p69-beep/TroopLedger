import XCTest
import SwiftData
@testable import TroopLedger

@MainActor
final class FundraiserTests: XCTestCase {
    private func fixture() throws -> (ModelContainer, ModelContext, FundraiserRecord, FundraiserProductRecord, PersonRecord) {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let fundraiser = FundraiserRecord(name: "Candy sale")
        let product = FundraiserProductRecord(fundraiserID: fundraiser.id, name: "Chocolate", unitName: "bar", unitCostCents: 50, unitPriceCents: 100)
        let person = PersonRecord(firstName: "Test", lastName: "Scout", role: .scout)
        context.insert(fundraiser); context.insert(product); context.insert(person)
        try context.save()
        return (container, context, fundraiser, product, person)
    }

    @discardableResult
    private func post(_ kind: FundraiserActivityKind, _ q: Int64, _ amount: Int64 = 0,
                      _ f: (ModelContainer, ModelContext, FundraiserRecord, FundraiserProductRecord, PersonRecord),
                      date: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> FundraiserActivityRecord {
        try FundraiserService.record(fundraiser: f.2, product: f.3, person: f.4, kind: kind, quantity: q, amount: amount, date: date, notes: "", in: f.1)
    }
    private func rows(_ context: ModelContext) throws -> [FundraiserActivityRecord] { try context.fetch(FetchDescriptor<FundraiserActivityRecord>()) }

    func testCandyCaseLifecycle() throws {
        let f = try fixture()
        try post(.receive, 120, 0, f)
        try post(.issue, 60, 0, f)
        try post(.sale, 40, 4_000, f)
        try post(.remittance, 0, 3_000, f)
        try post(.returned, 10, 0, f)
        try post(.loss, 2, 0, f)
        let total = FundraiserService.balance(try rows(f.1))
        XCTAssertEqual(total.received, 120)
        XCTAssertEqual(total.available, 70)
        XCTAssertEqual(total.onHand, 8)
        XCTAssertEqual(total.sold, 40)
        XCTAssertEqual(total.lost, 2)
        XCTAssertEqual(total.outstanding, 1_000)
        XCTAssertEqual(total.revenue - total.sold * f.3.unitCostCents, 2_000)
        XCTAssertEqual(try rows(f.1).first { $0.kindRaw == FundraiserActivityKind.receive.rawValue }?.amountCents, 6_000)
        XCTAssertEqual(try f.1.fetchCount(FetchDescriptor<LedgerTransaction>()), 0)
    }

    func testCannotOversellOverissueReturnOrOverRemit() throws {
        let f = try fixture()
        try post(.receive, 60, 0, f)
        XCTAssertThrowsError(try post(.issue, 61, 0, f))
        try post(.issue, 30, 0, f)
        XCTAssertThrowsError(try post(.sale, 31, 3_100, f))
        XCTAssertThrowsError(try post(.returned, 31, 0, f))
        XCTAssertThrowsError(try post(.loss, 31, 0, f))
        try post(.sale, 10, 1_000, f)
        XCTAssertThrowsError(try post(.remittance, 0, 1_001, f))
        XCTAssertEqual(try rows(f.1).count, 3)
    }

    func testScoutsAndLeadersKeepSeparateBalances() throws {
        let f = try fixture()
        let leader = PersonRecord(firstName: "Test", lastName: "Leader", role: .leader)
        f.1.insert(leader)
        try post(.receive, 120, 0, f)
        try post(.issue, 60, 0, f)
        let other = (f.0, f.1, f.2, f.3, leader)
        try post(.issue, 60, 0, other)
        try post(.sale, 10, 1_000, other)
        XCTAssertEqual(FundraiserService.balance(try rows(f.1), personID: f.4.id).onHand, 60)
        XCTAssertEqual(FundraiserService.balance(try rows(f.1), personID: leader.id).onHand, 50)
        XCTAssertEqual(FundraiserService.balance(try rows(f.1), personID: f.4.id).revenue, 0)
    }

    func testVoidingPreservesHistoryAndRejectsDependentChanges() throws {
        let f = try fixture()
        let receive = try post(.receive, 60, 0, f)
        let issue = try post(.issue, 60, 0, f)
        let sale = try post(.sale, 20, 2_000, f)
        let payment = try post(.remittance, 0, 1_000, f)
        XCTAssertThrowsError(try FundraiserService.void(receive, reason: "Wrong case count", in: f.1))
        XCTAssertThrowsError(try FundraiserService.void(issue, reason: "Wrong seller", in: f.1))
        XCTAssertThrowsError(try FundraiserService.void(sale, reason: "Wrong sale", in: f.1))
        XCTAssertNil(sale.voidedAt)
        try FundraiserService.void(payment, reason: "Duplicate payment", in: f.1)
        try FundraiserService.void(sale, reason: "Wrong quantity", in: f.1)
        XCTAssertEqual(try rows(f.1).count, 4)
        XCTAssertEqual(FundraiserService.balance(try rows(f.1)).onHand, 60)
        XCTAssertEqual(payment.voidReason, "Duplicate payment")
    }

    func testBackdatingCannotSpendStockBeforeReceipt() throws {
        let f = try fixture()
        try post(.receive, 60, 0, f)
        XCTAssertThrowsError(try post(.issue, 10, 0, f, date: Date(timeIntervalSince1970: 1_600_000_000)))
    }

    func testProductsAndCampaignsCannotBorrowStock() throws {
        let f = try fixture()
        try post(.receive, 60, 0, f)
        let another = FundraiserProductRecord(fundraiserID: f.2.id, name: "Caramel", unitName: "bar", unitCostCents: 50, unitPriceCents: 100)
        f.1.insert(another)
        XCTAssertThrowsError(try post(.issue, 10, 0, (f.0, f.1, f.2, another, f.4)))
        let campaign = FundraiserRecord(name: "Other")
        f.1.insert(campaign)
        XCTAssertThrowsError(try post(.receive, 10, 0, (f.0, f.1, campaign, f.3, f.4)))
    }

    func testInvalidInputsAndArchivedCampaignAreRejected() throws {
        let f = try fixture()
        XCTAssertThrowsError(try post(.receive, -1, 0, f))
        XCTAssertThrowsError(try post(.receive, Int64.max, 0, f))
        XCTAssertThrowsError(try post(.receive, 1, 0, f, date: Date().addingTimeInterval(1000)))
        try post(.receive, 10, 0, f)
        try post(.issue, 10, 0, f)
        XCTAssertThrowsError(try post(.sale, 1, -1, f))
        XCTAssertThrowsError(try post(.remittance, 0, 0, f))
        try FundraiserService.setArchived(f.2, in: f.1)
        XCTAssertThrowsError(try post(.sale, 1, 100, f))
    }

    func testBackupContainsInventoryAndCorrectionHistory() throws {
        let f = try fixture()
        let receipt = try post(.receive, 60, 0, f)
        try FundraiserService.void(receipt, reason: "Wrong delivery", in: f.1)
        let archive = try PlaintextBackupService.makeArchive(from: f.1)
        XCTAssertEqual(archive.recordCounts["fundraisers"], 1)
        XCTAssertEqual(archive.recordCounts["fundraiser_products"], 1)
        XCTAssertEqual(archive.recordCounts["fundraiser_activities"], 1)
        let csv = String(decoding: try XCTUnwrap(archive.files["fundraiser_activities.csv"]), as: UTF8.self)
        XCTAssertTrue(csv.contains("Wrong delivery"))
        XCTAssertTrue(csv.contains(receipt.id.uuidString.lowercased()))
    }
    func testIntegrityCheckFindsConflictingMergedActivity() throws {
        let f = try fixture()
        try post(.receive, 10, 0, f)
        try post(.issue, 10, 0, f)
        // Simulate an offline device merging an issue which could not pass local validation.
        f.1.insert(FundraiserActivityRecord(fundraiserID: f.2.id, productID: f.3.id, personID: f.4.id,
            sellerName: f.4.displayName, kind: .issue, quantity: 5, amountCents: 0, date: Date(), notes: ""))
        try f.1.save()
        let issues = try DataIntegrityService.check(in: f.1)
        XCTAssertTrue(issues.contains { $0.area == "Fundraisers" && $0.severity == .problem })
    }

    func testArchivedHistoryCannotBeVoidedUntilReopened() throws {
        let f = try fixture()
        let receipt = try post(.receive, 60, 0, f)
        try FundraiserService.setArchived(f.2, in: f.1)
        XCTAssertThrowsError(try FundraiserService.void(receipt, reason: "Correction", in: f.1))
        try FundraiserService.setArchived(f.2, in: f.1)
        try FundraiserService.void(receipt, reason: "Correction", in: f.1)
        XCTAssertNotNil(receipt.voidedAt)
    }

}
