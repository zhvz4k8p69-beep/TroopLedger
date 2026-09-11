import CoreText
import SwiftData
import XCTest
@testable import TroopLedger

// Tenth audit round regressions.
final class TenthRoundServiceTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
    }

    // MARK: - Holding accounts

    @MainActor
    func testDeletingTransferIntoCashBoxCannotOverdrawIt() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let checking = AccountRecord(name: "Checking", kind: .checking, openingBalanceCents: 50_000)
        let cashBox = AccountRecord(name: "Cash Box", kind: .cash)
        context.insert(checking)
        context.insert(cashBox)
        try context.save()
        let pair = try AccountTransferService.post(fromAccountID: checking.id, toAccountID: cashBox.id, date: Date(), amountCents: 10_000, reference: "", memo: "Float", reconciliations: [], in: context)
        let spent = LedgerTransaction(accountID: cashBox.id, date: Date(), direction: .expense, amountCents: 8_000, payee: "Camp store", category: "Camping and Activities")
        context.insert(spent)
        try context.save()
        let groupID = try XCTUnwrap(pair.incoming.transferGroupID)

        XCTAssertThrowsError(try AccountTransferService.delete(transferGroupID: groupID, reconciliations: [], in: context)) { error in
            guard case .wouldOverdraw(let message)? = error as? AccountTransferError else {
                return XCTFail("Expected wouldOverdraw, got \(error)")
            }
            XCTAssertTrue(message.contains("Cash Box"))
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<LedgerTransaction>()).count, 3, "A refused deletion must leave both legs in place")

        context.delete(spent)
        try context.save()
        try AccountTransferService.delete(transferGroupID: groupID, reconciliations: [], in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LedgerTransaction>()).count, 0)
    }

    @MainActor
    func testSpreadsheetImportIntoCashBoxCannotOverdrawIt() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let cashBox = AccountRecord(name: "Cash Box", kind: .cash, openingBalanceCents: 1_000)
        context.insert(cashBox)
        try context.save()

        func importCSV(_ csv: String, name: String) throws -> GeneralSpreadsheetImportResult {
            let document = try GeneralSpreadsheetImporter.parse(data: Data(csv.utf8), sourceName: name)
            let mapping = TransactionColumnMapping.detected(from: document.headers)
            return try GeneralSpreadsheetImporter.importDocument(document, mapping: mapping, accountID: cashBox.id, defaultDirection: .expense, defaultCategory: "Supplies", reconciliations: [], skipExceptions: false, calendar: calendar, into: context)
        }

        XCTAssertThrowsError(try importCSV("Date,Amount,Payee\n8/30/2026,-50.00,Camp store\n", name: "cash-a.csv")) { error in
            guard case .holdingAccountOverdrawn(let message)? = error as? GeneralSpreadsheetImportError else {
                return XCTFail("Expected holdingAccountOverdrawn, got \(error)")
            }
            XCTAssertTrue(message.contains("Cash Box"))
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<LedgerTransaction>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<GeneralSpreadsheetImportRecord>()).count, 0)

        let result = try importCSV("Date,Amount,Payee\n8/30/2026,-5.00,Camp store\n", name: "cash-b.csv")
        XCTAssertEqual(result, GeneralSpreadsheetImportResult(inserted: 1, skipped: 0))
        XCTAssertEqual(FinanceEngine.bookBalance(account: cashBox, transactions: try context.fetch(FetchDescriptor<LedgerTransaction>())), 500)
    }

    @MainActor
    func testReimbursementPaymentFromBankAccountDoesNotNeedTheHoldingCheck() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let checking = AccountRecord(name: "Checking", kind: .checking)
        let cashBox = AccountRecord(name: "Cash Box", kind: .cash, openingBalanceCents: 1_000)
        let requester = PersonRecord(firstName: "Pat", lastName: "Leader", role: .leader)
        let paidFromBank = ReimbursementRequest(requesterPersonID: requester.id, purchaseDate: Date(), purpose: "Rope", category: "Equipment", amountCents: 4_000)
        let paidFromCash = ReimbursementRequest(requesterPersonID: requester.id, purchaseDate: Date(), purpose: "Snacks", category: "Program Supplies", amountCents: 4_000)
        [checking, cashBox].forEach(context.insert)
        context.insert(requester)
        context.insert(paidFromBank)
        context.insert(paidFromCash)
        try context.save()
        for request in [paidFromBank, paidFromCash] {
            try ReimbursementService.review(request, approve: true, reviewerName: "Chair", notes: "Receipt seen", in: context)
        }

        // A bank account may overdraw; the payment posts without touching the holding-account rule.
        let payment = try ReimbursementService.createAndLinkPayment(for: paidFromBank, accountID: checking.id, paymentDate: Date(), reference: "1001", payee: "Pat", reconciliations: [], in: context)
        XCTAssertEqual(payment.accountID, checking.id)
        XCTAssertEqual(paidFromBank.status, .paid)
        // The cash box still refuses to pay out more than it holds.
        XCTAssertThrowsError(try ReimbursementService.createAndLinkPayment(for: paidFromCash, accountID: cashBox.id, paymentDate: Date(), reference: "", payee: "Pat", reconciliations: [], in: context)) { error in
            XCTAssertTrue(error is HoldingAccountValidationError, "got \(error)")
        }
        XCTAssertEqual(paidFromCash.status, .approved)
    }

    // MARK: - Reports

    @MainActor
    func testTreasurerReportFoldsCategorySpellingsLikeTheReportsScreen() throws {
        let checking = AccountRecord(name: "Checking", kind: .checking, openingBalanceCents: 10_000)
        let day = try date(2026, 9, 3)
        let transactions = [
            LedgerTransaction(accountID: checking.id, date: day, direction: .income, amountCents: 1_000, payee: "A", category: "Dues"),
            LedgerTransaction(accountID: checking.id, date: day, direction: .income, amountCents: 2_000, payee: "B", category: "dues "),
            LedgerTransaction(accountID: checking.id, date: day, direction: .income, amountCents: 4_000, payee: "C", category: " DUES"),
            LedgerTransaction(accountID: checking.id, date: day, direction: .expense, amountCents: 300, payee: "D", category: "Awards"),
        ]
        let owing = PersonRecord(firstName: "Owes", lastName: "Money", role: .scout)
        let credited = PersonRecord(firstName: "Has", lastName: "Credit", role: .scout)
        let entries = [
            MemberLedgerEntry(personID: owing.id, date: day, kind: .charge, amountCents: 5_000, category: "Dues"),
            MemberLedgerEntry(personID: owing.id, date: day, kind: .payment, amountCents: 1_500, category: "Dues"),
            MemberLedgerEntry(personID: credited.id, date: day, kind: .credit, amountCents: 700, category: "Dues"),
        ]
        let report = TreasurerReportService.makeSnapshot(
            title: "Monthly",
            periodStart: try date(2026, 9, 1),
            periodEnd: try date(2026, 9, 30),
            profile: nil,
            accounts: [checking],
            transactions: transactions,
            people: [owing, credited],
            memberEntries: entries,
            reconciliations: [],
            calendar: calendar
        )
        XCTAssertEqual(report.income.map(\.category), ["Dues"])
        XCTAssertEqual(report.income.first?.amountCents, 7_000)
        XCTAssertEqual(report.totalIncomeCents, 7_000)
        let screen = FinanceEngine.annualReport(period: ReportingPeriod.containing(day), transactions: transactions)
        XCTAssertEqual(screen.income.map(\.category), report.income.map(\.category))
        XCTAssertEqual(report.outstandingMemberCents, 3_500)
        XCTAssertEqual(report.memberCreditCents, -700)
        XCTAssertEqual(report.reconciliationStatus.map(\.accountName), ["Checking"])
    }

    func testReportingPeriodDateRangeLabelIsStableAcrossCalls() {
        let period = ReportingPeriod(basis: .schoolYear, startingYear: 2026)
        let first = period.dateRangeLabel()
        XCTAssertEqual(first, period.dateRangeLabel())
        XCTAssertTrue(first.contains("2026") && first.contains("2027"), first)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let utcPeriod = ReportingPeriod(basis: .calendarYear, startingYear: 2025, calendar: utc)
        XCTAssertTrue(utcPeriod.dateRangeLabel(calendar: utc).contains("2025"))
    }

    func testPDFFontCacheReturnsSharedFonts() {
        let first = PDFFontCache.font(size: 9, bold: true)
        XCTAssertTrue(first === PDFFontCache.font(size: 9, bold: true))
        XCTAssertFalse(first === PDFFontCache.font(size: 9, bold: false))
        XCTAssertEqual(CTFontGetSize(PDFFontCache.font(size: 7.5, bold: false)), 7.5)
    }

    // MARK: - Approval report

    func testApprovalReportCountsAuditEntriesThatMentionTheRequestOnce() throws {
        let requester = PersonRecord(firstName: "Pat", lastName: "Leader", role: .leader)
        let request = ReimbursementRequest(requesterPersonID: requester.id, purchaseDate: Date(), purpose: "Rope", category: "Equipment", amountCents: 4_000)
        let identity = ("Mac", "macOS", "Tester")
        let direct = AuditLogEntry(action: .edit, recordType: "Reimbursement Request", recordID: request.id, summary: "Approved", details: "Request ID: \(request.id.uuidString)", deviceName: identity.0, operatingSystem: identity.1, userIdentity: identity.2)
        let mention = AuditLogEntry(action: .create, recordType: "Transaction", recordID: UUID(), summary: "Paid", details: "Request ID: \(request.id.uuidString.uppercased())\nAgain: \(request.id.uuidString.lowercased())", deviceName: identity.0, operatingSystem: identity.1, userIdentity: identity.2)
        let unrelated = AuditLogEntry(action: .create, recordType: "Transaction", recordID: UUID(), summary: "Other", details: "Request ID: \(UUID().uuidString)", deviceName: identity.0, operatingSystem: identity.1, userIdentity: identity.2)
        let report = ReimbursementApprovalReportService.makeReport(
            requests: [request],
            attachments: [],
            transactions: [],
            people: [requester],
            auditEntries: [unrelated, mention, direct],
            policy: DisbursementControlPolicy(isEnabled: false)
        )
        let row = try XCTUnwrap(report.rows.first)
        XCTAssertEqual(row.auditEntryCount, 2)
        XCTAssertEqual(ReimbursementApprovalReportService.mentionedUUIDs(in: mention.details), [request.id])
        XCTAssertEqual(report.exceptionRows, report.rows.filter(\.hasExceptions))
        XCTAssertEqual(report.exceptionCount(for: .receipt), 1)
    }

    @MainActor
    func testApprovalAuditEntryNamesTheApprover() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let requester = PersonRecord(firstName: "Pat", lastName: "Leader", role: .leader)
        let approver = PersonRecord(firstName: "Jane", lastName: "Chair", role: .leader)
        let request = ReimbursementRequest(requesterPersonID: requester.id, purchaseDate: Date(), purpose: "Rope", category: "Equipment", amountCents: 4_000)
        context.insert(requester)
        context.insert(approver)
        context.insert(request)
        try context.save()
        try ReimbursementService.review(
            request,
            approve: true,
            reviewerName: "Treasurer",
            notes: "Receipt seen",
            approver: DisbursementControlIdentity(personID: approver.id, name: " Jane Chair ", household: "Chair"),
            in: context
        )
        let entry = try XCTUnwrap(context.fetch(FetchDescriptor<AuditLogEntry>()).first { $0.summary == "Approved reimbursement request" })
        XCTAssertTrue(entry.details.contains("Approver: Jane Chair"), entry.details)
        XCTAssertTrue(entry.details.contains("Approver person ID: \(approver.id.uuidString)"), entry.details)
    }

    // MARK: - Audit log

    @MainActor
    func testAuditCSVOrdersSameTimestampEntriesByID() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let a = AuditLogEntry(timestamp: stamp, action: .create, recordType: "T", recordID: nil, summary: "a", deviceName: "", operatingSystem: "", userIdentity: "")
        let b = AuditLogEntry(timestamp: stamp, action: .create, recordType: "T", recordID: nil, summary: "b", deviceName: "", operatingSystem: "", userIdentity: "")
        let forward = AuditLogger.csv(for: [a, b])
        XCTAssertEqual(forward, AuditLogger.csv(for: [b, a]))
        let lines = forward.components(separatedBy: "\r\n").dropFirst().filter { !$0.isEmpty }
        let expected = [a, b].sorted { $0.id.uuidString < $1.id.uuidString }.map { $0.id.uuidString.lowercased() }
        XCTAssertEqual(lines.map { String($0.prefix(36)) }, expected)
    }

    @MainActor
    func testStartOverForgetsTheCachedTreasurerIdentity() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let profile = TroopProfileRecord()
        profile.treasurerName = "Old Treasurer"
        context.insert(profile)
        try context.save()
        let anonymous = AuditIdentity(deviceName: "iPad", operatingSystem: "iOS", userIdentity: "")
        let before = AuditLogger.record(.create, recordType: "Test", recordID: nil, summary: "before", identity: anonymous, in: context)
        XCTAssertEqual(before.userIdentity, "Old Treasurer (troop profile)")
        try context.save()

        _ = try DataResetService.deleteAllRecords(from: context)
        let after = AuditLogger.record(.create, recordType: "Test", recordID: nil, summary: "after", identity: anonymous, in: context)
        XCTAssertEqual(after.userIdentity, "", "The deleted profile's treasurer must not be named on entries written after the reset")
    }

    // MARK: - Deterministic ordering

    func testCloseoutPreviewAndRosterOrderSameNameParticipantsDeterministically() throws {
        let event = EventRecord(name: "Camp", startDate: Date(), endDate: Date())
        let guests = (0..<3).map { _ -> EventParticipant in
            let participant = EventParticipant(eventID: event.id, personID: nil)
            participant.guestName = "Guest"
            participant.feeCents = 1_000
            return participant
        }
        let expected = guests.map(\.id).sorted { $0.uuidString < $1.uuidString }
        for order in [guests, guests.reversed(), [guests[1], guests[2], guests[0]]] {
            let preview = try EventCloseoutService.makePreview(event: event, participants: order, people: [], transactions: [], financialEntries: [])
            XCTAssertEqual(preview.participants.map(\.participantID), expected)
            let roster = EventRosterSnapshot(event: event, participants: order, people: [])
            XCTAssertEqual(roster.rows.map(\.id), expected)
        }
    }

    // MARK: - Scoutbook import

    func testScoutbookProgramYearUsesTheGregorianYear() throws {
        XCTAssertEqual(ScoutbookImporter.registrationProgramYear(for: try date(2026, 3, 5)), "2026")
        XCTAssertEqual(ScoutbookImporter.registrationProgramYear(for: try date(2027, 12, 31, hour: 23)), "2027")
    }

    @MainActor
    func testScoutbookReimportWithoutExpirationOrPositionKeepsExistingValues() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let first = try ScoutbookImporter.parse(data: Data("First Name,Last Name,Member ID,Registration Date,Expiration Date,Position,Program Year\nAva,Scout,1001,3/5/2026,12/31/2026,Patrol Leader,2026\n".utf8), sourceName: "members.csv")
        _ = try ScoutbookImporter.importDocument(first, kind: .members, into: context)
        let registration = try XCTUnwrap(context.fetch(FetchDescriptor<RegistrationRecord>()).first)
        let expiration = try XCTUnwrap(registration.expiresOn)
        XCTAssertEqual(registration.unitRole, "Patrol Leader")

        let second = try ScoutbookImporter.parse(data: Data("First Name,Last Name,Member ID,Status,Program Year\nAva,Scout,1001,Active,2026\n".utf8), sourceName: "members-later.csv")
        let result = try ScoutbookImporter.importDocument(second, kind: .members, into: context)
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RegistrationRecord>()).count, 1)
        XCTAssertEqual(registration.expiresOn, expiration)
        XCTAssertEqual(registration.unitRole, "Patrol Leader")

        // A file that does carry the columns still updates them.
        let third = try ScoutbookImporter.parse(data: Data("First Name,Last Name,Member ID,Expiration Date,Position,Program Year\nAva,Scout,1001,12/31/2027,Scribe,2026\n".utf8), sourceName: "members-latest.csv")
        _ = try ScoutbookImporter.importDocument(third, kind: .members, into: context)
        XCTAssertEqual(registration.unitRole, "Scribe")
        XCTAssertEqual(registration.expiresOn.map { calendar.component(.year, from: $0) }, 2027)
    }

    @MainActor
    func testScoutbookMemberIDWithStrayWhitespaceMatchesTheExistingPerson() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let existing = PersonRecord(firstName: "Ava", lastName: "Scout", role: .scout)
        existing.scoutingMemberID = " 1001 "
        context.insert(existing)
        try context.save()
        let document = try ScoutbookImporter.parse(data: Data("First Name,Last Name,Member ID\nAva,Scout,1001\n".utf8), sourceName: "members.csv")
        let result = try ScoutbookImporter.importDocument(document, kind: .members, into: context)
        XCTAssertEqual(result.inserted, 0)
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PersonRecord>()).count, 1)
    }

    @MainActor
    func testScoutbookImportNotesAndAuditDetailsAreBounded() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        var csv = "First Name,Last Name,Date,Amount\nAva,Scout,3/5/2026,25.00\n"
        for index in 0..<300 { csv += "Ben,Scout\(index),not a date,10.00\n" }
        let document = try ScoutbookImporter.parse(data: Data(csv.utf8), sourceName: "payment-log.csv")
        let result = try ScoutbookImporter.importDocument(document, kind: .paymentLog, into: context)
        XCTAssertEqual(result.inserted, 1)
        XCTAssertEqual(result.skipped, 300)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<ScoutbookImportRecord>()).first)
        XCTAssertLessThanOrEqual(record.notes.components(separatedBy: "\n").count, 201)
        XCTAssertTrue(record.notes.contains("and 100 more"), record.notes.suffix(80).description)
        let audit = try XCTUnwrap(context.fetch(FetchDescriptor<AuditLogEntry>()).first { $0.recordType == "Scoutbook Import" })
        XCTAssertTrue(audit.details.contains("and 200 more"))
        XCTAssertLessThan(audit.details.count, 20_000)
    }

    @MainActor
    func testScoutbookPositionColumnDecidesRoleBeforeGenericWords() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let csv = "First Name,Last Name,Member ID,Position\nAva,Scout,1,Patrol Leader\nBen,Scout,2,Senior Patrol Leader\nCal,Adult,3,Scoutmaster\nDee,Adult,4,Assistant Scoutmaster\nEve,Parent,5,Parent\nFay,Scout,6,\n"
        let document = try ScoutbookImporter.parse(data: Data(csv.utf8), sourceName: "members.csv")
        _ = try ScoutbookImporter.importDocument(document, kind: .members, into: context)
        let roles = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<PersonRecord>()).map { ($0.firstName, $0.role) })
        XCTAssertEqual(roles["Ava"], .scout)
        XCTAssertEqual(roles["Ben"], .scout)
        XCTAssertEqual(roles["Cal"], .leader)
        XCTAssertEqual(roles["Dee"], .leader)
        XCTAssertEqual(roles["Eve"], .parent)
        XCTAssertEqual(roles["Fay"], .scout)
    }

    func testTroopPositionMatchingStillResolvesAliasesAndContainment() {
        XCTAssertEqual(TroopPosition.matching("SPL"), .seniorPatrolLeader)
        XCTAssertEqual(TroopPosition.matching("Committee Chairman"), .committeeChair)
        XCTAssertEqual(TroopPosition.matching("Assistant Scoutmaster (ASM)"), .assistantScoutmaster)
        XCTAssertEqual(TroopPosition.matching("Scoutmaster"), .scoutmaster)
        XCTAssertNil(TroopPosition.matching(""))
        XCTAssertNil(TroopPosition.matching("Cookie Coordinator"))
    }

    // MARK: - Deposits

    @MainActor
    func testDepositCreditsReceiptWrittenLastNameFirst() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let undeposited = AccountRecord(name: "Undeposited Funds", kind: .undepositedFunds)
        let checking = AccountRecord(name: "Checking", kind: .checking)
        let john = PersonRecord(firstName: "John", lastName: "Smith", role: .parent)
        let receipt = CashReceiptRecord(date: Date(), personName: "Smith,  John", purpose: "Dues", amountCents: 1_000, paymentKind: "Check")
        [undeposited, checking].forEach(context.insert)
        context.insert(john)
        context.insert(receipt)
        try context.save()
        XCTAssertEqual(BatchDepositService.normalized("Smith,  John"), BatchDepositService.normalized("john smith"))
        let batch = try BatchDepositService.post(destinationAccountID: checking.id, depositDate: Date(), reference: "", notes: "", sourceTransactionIDs: [], sourceCashReceiptIDs: [receipt.id], reconciliations: [], in: context)
        let allocation = try XCTUnwrap(context.fetch(FetchDescriptor<DepositAllocationRecord>()).first { $0.batchID == batch.id })
        XCTAssertEqual(allocation.personID, john.id)
        let receiptTransaction = try XCTUnwrap(context.fetch(FetchDescriptor<LedgerTransaction>()).first { $0.id == allocation.sourceTransactionID })
        XCTAssertEqual(receiptTransaction.personID, john.id)
    }

    // MARK: - Bank spreadsheet import

    func testBankTypeLabelsNamingDepositsOrInterestAreIncome() throws {
        let csv = """
        Date,Type,Amount,Description
        8/3/2026,Interest Payment,1.25,Interest
        8/4/2026,Mobile Check Deposit,250.00,Dues check
        8/5/2026,Credit Card Payment,50.00,Card
        8/6/2026,Returned Deposit Item,20.00,Bounced
        8/7/2026,POS Purchase,12.00,Store
        8/8/2026,Monthly Service Fee,5.00,Fee
        """
        let document = try GeneralSpreadsheetImporter.parse(data: Data(csv.utf8), sourceName: "bank.csv")
        let mapping = TransactionColumnMapping.detected(from: document.headers)
        XCTAssertNotNil(mapping[.direction])
        let preview = GeneralSpreadsheetImporter.preview(document: document, mapping: mapping, accountID: UUID(), defaultDirection: .expense, defaultCategory: "Uncategorized", reconciliations: [])
        XCTAssertEqual(preview.invalidRows.map(\.sourceRow), [])
        XCTAssertEqual(preview.validRows.compactMap { $0.draft?.direction }, [.income, .income, .expense, .expense, .expense, .expense])
        XCTAssertEqual(preview.totalIncomeCents, 25_125)
        XCTAssertEqual(preview.totalExpenseCents, 8_700)
    }

    func testSpreadsheetPreviewPartitionsRowsAndFlagsLockedDatesOnce() throws {
        let accountID = UUID()
        let lock = ReconciliationRecord(accountID: accountID, statementDate: try date(2026, 8, 31), statementEndingBalanceCents: 0, clearedBalanceCents: 0)
        let csv = "Date,Amount,Payee\n8/30/2026,-10.00,Locked\n9/2/2026,-20.00,Open\n9/3/2026,15.00,Refund\n9/4/2026,zero,Bad amount\n"
        let document = try GeneralSpreadsheetImporter.parse(data: Data(csv.utf8), sourceName: "register.csv")
        let mapping = TransactionColumnMapping.detected(from: document.headers)
        let preview = GeneralSpreadsheetImporter.preview(document: document, mapping: mapping, accountID: accountID, defaultDirection: .income, defaultCategory: "Uncategorized", reconciliations: [lock], calendar: calendar)
        XCTAssertEqual(preview.rows.count, preview.validRows.count + preview.invalidRows.count)
        XCTAssertEqual(preview.validRows.map(\.sourceRow), [3, 4])
        XCTAssertEqual(preview.invalidRows.map(\.sourceRow), [2, 5])
        XCTAssertTrue(preview.invalidRows[0].issues.contains { $0.contains("locked") })
        XCTAssertEqual(preview.totalIncomeCents, 1_500)
        XCTAssertEqual(preview.totalExpenseCents, 2_000)
        let unlocked = GeneralSpreadsheetImporter.preview(document: document, mapping: mapping, accountID: UUID(), defaultDirection: .income, defaultCategory: "Uncategorized", reconciliations: [lock], calendar: calendar)
        XCTAssertEqual(unlocked.validRows.map(\.sourceRow), [2, 3, 4], "A lock on another account must not apply")
    }

    // MARK: - Calendar feeds

    @MainActor
    func testReattachedCalendarEventKeepsLocalLocationAndStatus() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let subscription = ExternalCalendarSubscription(name: "Troop", feedURLString: "https://example.com/feed.ics")
        context.insert(subscription)
        let detached = EventRecord(name: "Old Campout", startDate: Date(), endDate: Date())
        detached.sourceSystem = "Scoutbook Calendar"
        detached.externalSourceID = "camp-1"
        detached.location = "Camp Green"
        detached.status = .open
        context.insert(detached)
        let attached = EventRecord(name: "Meeting", startDate: Date(), endDate: Date())
        attached.sourceSystem = "Scoutbook Calendar"
        attached.externalSourceID = "meeting-1"
        attached.calendarSubscriptionID = subscription.id
        attached.location = "Church hall"
        attached.status = .open
        context.insert(attached)
        try context.save()

        let feed = [
            ScoutbookCalendarEvent(externalID: "camp-1", title: "Fall Campout", startDate: Date(), endDate: Date(), location: "", notes: "", isAllDay: true, modifiedAt: nil),
            ScoutbookCalendarEvent(externalID: "meeting-1", title: "Meeting", startDate: Date(), endDate: Date(), location: "", notes: "", isAllDay: false, modifiedAt: nil),
        ]
        _ = try ScoutbookCalendarService.apply(feedEvents: feed, to: subscription, in: context)
        XCTAssertEqual(detached.location, "Camp Green")
        XCTAssertEqual(detached.status, .open)
        XCTAssertEqual(detached.calendarSubscriptionID, subscription.id)
        // An event that was never detached follows the feed as before.
        XCTAssertEqual(attached.location, "")
        XCTAssertEqual(attached.status, .planning)
    }

    func testRecurrenceWithEveryOccurrenceExcludedProducesNoEvents() throws {
        let ics = """
        begin:vcalendar
        BEGIN:VEVENT
        UID:camp-1
        DTSTART;VALUE=DATE:20260912
        DTEND;VALUE=DATE:20260914
        SUMMARY:Fall Campout
        END:VEVENT
        BEGIN:VEVENT
        UID:meeting-1
        DTSTART:20260915T190000
        DTEND:20260915T203000
        RRULE:FREQ=WEEKLY;COUNT=2
        EXDATE:20260915T190000,20260922T190000
        SUMMARY:Troop Meeting
        END:VEVENT
        END:VCALENDAR
        """
        let events = try ScoutbookCalendarService.parse(data: Data(ics.utf8))
        XCTAssertEqual(events.map(\.externalID), ["camp-1"])
    }

    func testMonthlyRecurrenceExpandsOnGregorianMonths() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:committee
        DTSTART:20260115T190000
        DTEND:20260115T200000
        RRULE:FREQ=MONTHLY;BYMONTHDAY=15;COUNT=3
        SUMMARY:Committee Meeting
        END:VEVENT
        END:VCALENDAR
        """
        let events = try ScoutbookCalendarService.parse(data: Data(ics.utf8))
        let components = events.map { calendar.dateComponents([.year, .month, .day, .hour], from: $0.startDate) }
        XCTAssertEqual(components.map(\.month), [1, 2, 3])
        XCTAssertEqual(Set(components.map(\.day)), [15])
        XCTAssertEqual(Set(components.map(\.year)), [2026])
        XCTAssertEqual(Set(components.map(\.hour)), [19])
    }
}
