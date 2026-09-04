import Foundation
import SwiftData

struct SpreadsheetImportSnapshot: Decodable {
    struct Account: Decodable {
        let id: UUID
        let name: String
        let institution: String
        let kind: String
        let openingBalanceCents: Int64
        let openingDate: Date?
        let notes: String
    }

    struct Transaction: Decodable {
        let id: UUID
        let accountID: UUID
        let date: Date
        let direction: String
        let amountCents: Int64
        let checkNumber: String
        let payee: String
        let category: String
        let memo: String
        let isCleared: Bool
        let sourceSheet: String
        let sourceRow: Int
    }

    struct CashReceipt: Decodable {
        let id: UUID
        let date: Date
        let personName: String
        let purpose: String
        let amountCents: Int64
        let paymentKind: String
        let sourceSheet: String
        let sourceRow: Int
    }

    struct Person: Decodable {
        let id: UUID
        let firstName: String
        let lastName: String
        let role: String
        let patrol: String
        let scoutingMemberID: String
        let isActive: Bool
        let notes: String
    }

    struct Registration: Decodable {
        let id: UUID
        let personID: UUID
        let programYear: String
        let unitRole: String
        let status: String
        let registeredOn: Date
        let duesAssessedCents: Int64
        let notes: String
        let sourceSheet: String
        let sourceRow: Int
    }

    struct MemberEntry: Decodable {
        let id: UUID
        let personID: UUID
        let date: Date
        let kind: String
        let amountCents: Int64
        let category: String
        let eventID: UUID?
        let notes: String
        let sourceSheet: String
        let sourceRow: Int
    }

    struct Event: Decodable {
        let id: UUID
        let name: String
        let category: String
        let startDate: Date
        let endDate: Date
        let location: String
        let coordinator: String
        let status: String
        let capacity: Int
        let budgetIncomeCents: Int64
        let budgetExpenseCents: Int64
        let notes: String
        let dateIsApproximate: Bool
        let sourceSheet: String
    }

    struct EventLineItem: Decodable {
        let id: UUID
        let eventID: UUID
        let date: Date
        let direction: String
        let amountCents: Int64
        let description: String
        let isProjected: Bool
        let sourceSheet: String
        let sourceRow: Int
    }

    struct Checks: Decodable {
        let expectedCheckingEndingCents: Int64
        let importedCheckingEndingCents: Int64
        let checkingBalanceMatches: Bool
        let issues: [String]
    }

    let formatVersion: Int
    let sourceName: String
    let sourceFingerprint: String
    let generatedAt: Date
    let accounts: [Account]
    let transactions: [Transaction]
    let cashReceipts: [CashReceipt]
    let people: [Person]
    let registrations: [Registration]
    let memberEntries: [MemberEntry]
    let events: [Event]
    let eventLineItems: [EventLineItem]
    let checks: Checks

    var totalRecordCount: Int {
        accounts.count + transactions.count + cashReceipts.count + people.count + registrations.count + memberEntries.count + events.count + eventLineItems.count
    }
}

enum SpreadsheetImportError: LocalizedError, Equatable {
    case resourceMissing
    case unsupportedVersion(Int)
    case verificationFailed(String)
    case alreadyImported

    var errorDescription: String? {
        switch self {
        case .resourceMissing: "The bundled workbook import snapshot is missing."
        case .unsupportedVersion(let version): "Import format version \(version) is not supported."
        case .verificationFailed(let detail): "The workbook snapshot did not pass verification: \(detail)"
        case .alreadyImported: "This exact workbook snapshot has already been imported."
        }
    }
}

@MainActor
enum SpreadsheetImporter {
    static func loadBundledSnapshot() throws -> SpreadsheetImportSnapshot {
        guard let url = Bundle.main.url(forResource: "TroopFinanceImport", withExtension: "json") else {
            throw SpreadsheetImportError.resourceMissing
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(value)")
        }
        let snapshot = try decoder.decode(SpreadsheetImportSnapshot.self, from: data)
        guard snapshot.formatVersion == 1 else { throw SpreadsheetImportError.unsupportedVersion(snapshot.formatVersion) }
        guard snapshot.checks.checkingBalanceMatches, snapshot.checks.issues.isEmpty else {
            throw SpreadsheetImportError.verificationFailed(snapshot.checks.issues.joined(separator: " "))
        }
        return snapshot
    }

    static func importSnapshot(_ snapshot: SpreadsheetImportSnapshot, into modelContext: ModelContext) throws -> ImportRecord {
        let priorImports = try modelContext.fetch(FetchDescriptor<ImportRecord>())
        guard !priorImports.contains(where: { $0.sourceFingerprint == snapshot.sourceFingerprint }) else {
            throw SpreadsheetImportError.alreadyImported
        }
        // The import record alone is not enough: two devices can each run the import before CloudKit has
        // delivered the other's ImportRecord, doubling every balance. The snapshot carries fixed record IDs,
        // so any of them already present means the workbook is in the database.
        let snapshotIDs = Set(snapshot.accounts.map(\.id) + snapshot.people.map(\.id) + snapshot.transactions.map(\.id))
        let existingIDs = Set(
            try modelContext.fetch(FetchDescriptor<AccountRecord>()).map(\.id)
                + modelContext.fetch(FetchDescriptor<PersonRecord>()).map(\.id)
                + modelContext.fetch(FetchDescriptor<LedgerTransaction>()).map(\.id)
        )
        guard snapshotIDs.isDisjoint(with: existingIDs) else { throw SpreadsheetImportError.alreadyImported }

        // rollback() below discards every unsaved change in the shared context, so persist unrelated
        // pending edits first; a failed import must only undo the import itself.
        if modelContext.hasChanges { try modelContext.save() }

        do {
            for source in snapshot.accounts {
                let record = AccountRecord(name: source.name, institution: source.institution, kind: AccountKind(rawValue: source.kind) ?? .other, openingBalanceCents: source.openingBalanceCents)
                record.id = source.id
                record.notes = [source.notes, source.openingDate.map { "Opening date: \($0.formatted(date: .abbreviated, time: .omitted))." }]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                modelContext.insert(record)
            }

            for source in snapshot.transactions {
                let record = LedgerTransaction(accountID: source.accountID, date: source.date, direction: TransactionDirection(rawValue: source.direction) ?? .expense, amountCents: source.amountCents, payee: source.payee, category: source.category)
                record.id = source.id
                record.checkNumber = source.checkNumber
                record.memo = source.memo
                record.isCleared = source.isCleared
                record.sourceSheet = source.sourceSheet
                record.sourceRow = source.sourceRow
                modelContext.insert(record)
            }

            for source in snapshot.cashReceipts {
                let record = CashReceiptRecord(date: source.date, personName: source.personName, purpose: source.purpose, amountCents: source.amountCents, paymentKind: source.paymentKind)
                record.id = source.id
                record.sourceSheet = source.sourceSheet
                record.sourceRow = source.sourceRow
                modelContext.insert(record)
            }

            for source in snapshot.people {
                let record = PersonRecord(firstName: source.firstName, lastName: source.lastName, role: PersonRole(rawValue: source.role) ?? .other)
                record.id = source.id
                record.patrol = source.patrol
                record.scoutingMemberID = source.scoutingMemberID
                record.isActive = source.isActive
                record.notes = source.notes
                modelContext.insert(record)
            }

            for source in snapshot.registrations {
                let record = RegistrationRecord(personID: source.personID, programYear: source.programYear, unitRole: source.unitRole, status: RegistrationStatus(rawValue: source.status) ?? .pending)
                record.id = source.id
                record.registeredOn = source.registeredOn
                record.duesAssessedCents = source.duesAssessedCents
                record.notes = source.notes
                record.sourceSheet = source.sourceSheet
                record.sourceRow = source.sourceRow
                modelContext.insert(record)
            }

            for source in snapshot.memberEntries {
                let record = MemberLedgerEntry(personID: source.personID, date: source.date, kind: MemberEntryKind(rawValue: source.kind) ?? .charge, amountCents: source.amountCents, category: source.category)
                record.id = source.id
                record.eventID = source.eventID
                record.notes = source.notes
                record.sourceSheet = source.sourceSheet
                record.sourceRow = source.sourceRow
                modelContext.insert(record)
            }

            for source in snapshot.events {
                let record = EventRecord(name: source.name, startDate: source.startDate, endDate: source.endDate)
                record.id = source.id
                record.category = source.category
                record.location = source.location
                record.coordinator = source.coordinator
                record.status = EventStatus(rawValue: source.status) ?? .planning
                record.capacity = source.capacity
                record.budgetIncomeCents = source.budgetIncomeCents
                record.budgetExpenseCents = source.budgetExpenseCents
                record.notes = source.notes
                record.dateIsApproximate = source.dateIsApproximate
                record.sourceSheet = source.sourceSheet
                modelContext.insert(record)
            }

            for source in snapshot.eventLineItems {
                let record = EventFinancialEntry(eventID: source.eventID, date: source.date, direction: TransactionDirection(rawValue: source.direction) ?? .expense, amountCents: source.amountCents, description: source.description)
                record.id = source.id
                record.isProjected = source.isProjected
                record.sourceSheet = source.sourceSheet
                record.sourceRow = source.sourceRow
                modelContext.insert(record)
            }

            let importRecord = ImportRecord(sourceName: snapshot.sourceName, sourceFingerprint: snapshot.sourceFingerprint)
            importRecord.accountCount = snapshot.accounts.count
            importRecord.transactionCount = snapshot.transactions.count
            importRecord.cashReceiptCount = snapshot.cashReceipts.count
            importRecord.peopleCount = snapshot.people.count
            importRecord.registrationCount = snapshot.registrations.count
            importRecord.memberEntryCount = snapshot.memberEntries.count
            importRecord.eventCount = snapshot.events.count
            importRecord.eventLineItemCount = snapshot.eventLineItems.count
            modelContext.insert(importRecord)
            AuditLogger.record(
                .importData,
                recordType: "Workbook Import",
                recordID: importRecord.id,
                summary: "Imported \(snapshot.sourceName)",
                details: AuditLogger.details([
                    ("Fingerprint", snapshot.sourceFingerprint),
                    ("Total records", String(snapshot.totalRecordCount)),
                    ("Accounts", String(importRecord.accountCount)),
                    ("Transactions", String(importRecord.transactionCount)),
                    ("Cash receipts", String(importRecord.cashReceiptCount)),
                    ("People", String(importRecord.peopleCount)),
                    ("Registrations", String(importRecord.registrationCount)),
                    ("Member ledger entries", String(importRecord.memberEntryCount)),
                    ("Events", String(importRecord.eventCount)),
                    ("Event financial lines", String(importRecord.eventLineItemCount)),
                ]),
                in: modelContext
            )
            try modelContext.save()
            return importRecord
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
