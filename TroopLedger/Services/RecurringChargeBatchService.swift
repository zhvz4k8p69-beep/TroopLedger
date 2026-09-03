import Foundation
import SwiftData

struct RecurringChargeBatchDraft {
    var name: String
    var kind: RecurringChargeBatchKind
    var chargeDate: Date
    var category: String
    var fixedAmountCents: Int64?
    var programYear: String
    var notes: String
    var selectedPersonIDs: Set<UUID>
}

struct RecurringChargeBatchProposal: Identifiable {
    struct Row: Identifiable {
        let id: UUID
        let personID: UUID
        let personName: String
        let registrationID: UUID?
        let amountCents: Int64
    }

    let id = UUID()
    let name: String
    let kind: RecurringChargeBatchKind
    let chargeDate: Date
    let category: String
    let programYear: String
    let notes: String
    let rows: [Row]

    var totalCents: Int64 { rows.reduce(0) { $0 + $1.amountCents } }
}

enum RecurringChargeBatchError: LocalizedError, Equatable {
    case nameRequired
    case categoryRequired
    case amountRequired
    case programYearRequired
    case noPeopleSelected
    case personNoLongerAvailable
    case missingRegistrationAssessments([String])
    case duplicateCharge(String)

    var errorDescription: String? {
        switch self {
        case .nameRequired: "Provide a name that will identify this charge batch in history."
        case .categoryRequired: "Provide the member-ledger category for these charges."
        case .amountRequired: "Enter a fixed charge greater than zero."
        case .programYearRequired: "Choose a registration program year."
        case .noPeopleSelected: "Select at least one person to charge."
        case .personNoLongerAvailable: "One of the selected people no longer exists. Return to selection and review the batch."
        case .missingRegistrationAssessments(let names):
            "No positive assessed dues were found for \(names.joined(separator: ", ")) in the selected program year."
        case .duplicateCharge(let name):
            "A matching batch-created charge already exists for \(name) on this date. Change the date, amount, or category before posting again."
        }
    }
}

@MainActor
enum RecurringChargeBatchService {
    static func preview(
        draft: RecurringChargeBatchDraft,
        people: [PersonRecord],
        registrations: [RegistrationRecord],
        existingAllocations: [RecurringChargeAllocationRecord],
        calendar: Calendar = .current
    ) throws -> RecurringChargeBatchProposal {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = draft.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let programYear = draft.programYear.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RecurringChargeBatchError.nameRequired }
        guard !category.isEmpty else { throw RecurringChargeBatchError.categoryRequired }
        guard !draft.selectedPersonIDs.isEmpty else { throw RecurringChargeBatchError.noPeopleSelected }
        if draft.kind == .dues {
            guard let amount = draft.fixedAmountCents, amount > 0 else {
                throw RecurringChargeBatchError.amountRequired
            }
        } else if programYear.isEmpty {
            throw RecurringChargeBatchError.programYearRequired
        }

        let selectedPeople = people
            .filter { draft.selectedPersonIDs.contains($0.id) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        guard selectedPeople.count == draft.selectedPersonIDs.count else {
            throw RecurringChargeBatchError.personNoLongerAvailable
        }

        var missingAssessments: [String] = []
        let rows: [RecurringChargeBatchProposal.Row] = selectedPeople.compactMap { person in
            let registration: RegistrationRecord?
            let amount: Int64
            switch draft.kind {
            case .dues:
                registration = nil
                amount = draft.fixedAmountCents ?? 0
            case .registration:
                registration = preferredRegistration(
                    for: person.id,
                    programYear: programYear,
                    registrations: registrations
                )
                amount = registration?.duesAssessedCents ?? 0
            }
            guard amount > 0 else {
                missingAssessments.append(person.displayName)
                return nil
            }
            return RecurringChargeBatchProposal.Row(
                id: person.id,
                personID: person.id,
                personName: person.displayName,
                registrationID: registration?.id,
                amountCents: amount
            )
        }
        guard missingAssessments.isEmpty else {
            throw RecurringChargeBatchError.missingRegistrationAssessments(missingAssessments)
        }

        for row in rows {
            if existingAllocations.contains(where: {
                $0.personID == row.personID
                    && calendar.isDate($0.chargeDate, inSameDayAs: draft.chargeDate)
                    && normalized($0.categorySnapshot) == normalized(category)
                    && $0.amountCents == row.amountCents
            }) {
                throw RecurringChargeBatchError.duplicateCharge(row.personName)
            }
        }

        return RecurringChargeBatchProposal(
            name: name,
            kind: draft.kind,
            chargeDate: draft.chargeDate,
            category: category,
            programYear: programYear,
            notes: draft.notes.trimmingCharacters(in: .whitespacesAndNewlines),
            rows: rows
        )
    }

    @discardableResult
    static func post(
        draft: RecurringChargeBatchDraft,
        calendar: Calendar = .current,
        in modelContext: ModelContext
    ) throws -> RecurringChargeBatchRecord {
        let people = try modelContext.fetch(FetchDescriptor<PersonRecord>())
        let registrations = try modelContext.fetch(FetchDescriptor<RegistrationRecord>())
        let existingAllocations = try modelContext.fetch(FetchDescriptor<RecurringChargeAllocationRecord>())
        let proposal = try preview(
            draft: draft,
            people: people,
            registrations: registrations,
            existingAllocations: existingAllocations,
            calendar: calendar
        )

        let batch = RecurringChargeBatchRecord(
            name: proposal.name,
            kind: proposal.kind,
            chargeDate: proposal.chargeDate,
            category: proposal.category
        )
        batch.programYear = proposal.programYear
        batch.fixedAmountCents = proposal.kind == .dues ? (draft.fixedAmountCents ?? 0) : 0
        batch.totalCents = proposal.totalCents
        batch.allocationCount = proposal.rows.count
        batch.notes = proposal.notes
        modelContext.insert(batch)

        for row in proposal.rows {
            let entry = MemberLedgerEntry(
                personID: row.personID,
                date: proposal.chargeDate,
                kind: .charge,
                amountCents: row.amountCents,
                category: proposal.category
            )
            entry.chargeBatchID = batch.id
            entry.sourceSystem = "TroopLedger Charge Batch"
            entry.externalSourceID = batch.id.uuidString.lowercased()
            entry.notes = [
                proposal.notes,
                proposal.kind == .registration ? "Registration program year: \(proposal.programYear)" : "Batch: \(proposal.name)",
            ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            modelContext.insert(entry)

            let allocation = RecurringChargeAllocationRecord(
                batchID: batch.id,
                personID: row.personID,
                chargeDate: proposal.chargeDate,
                amountCents: row.amountCents
            )
            allocation.memberEntryID = entry.id
            allocation.registrationID = row.registrationID
            allocation.personNameSnapshot = row.personName
            allocation.categorySnapshot = proposal.category
            modelContext.insert(allocation)
        }

        AuditLogger.record(
            .create,
            recordType: "Recurring Charge Batch",
            recordID: batch.id,
            summary: "Posted charge batch \(batch.name)",
            details: AuditLogger.details([
                ("Type", batch.kind.rawValue),
                ("Charge date", batch.chargeDate.formatted(date: .numeric, time: .omitted)),
                ("Category", batch.category),
                ("Program year", batch.programYear),
                ("People charged", String(batch.allocationCount)),
                ("Total", Money.currency(cents: batch.totalCents)),
            ]),
            in: modelContext
        )
        try modelContext.save()
        return batch
    }

    static func assessedDues(
        for personID: UUID,
        programYear: String,
        registrations: [RegistrationRecord]
    ) -> Int64? {
        preferredRegistration(for: personID, programYear: programYear, registrations: registrations)?.duesAssessedCents
    }

    private static func preferredRegistration(
        for personID: UUID,
        programYear: String,
        registrations: [RegistrationRecord]
    ) -> RegistrationRecord? {
        registrations
            .filter {
                $0.personID == personID
                    && $0.programYear.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(programYear) == .orderedSame
                    && $0.duesAssessedCents > 0
            }
            .sorted {
                let leftCurrent = $0.status == .current
                let rightCurrent = $1.status == .current
                if leftCurrent != rightCurrent { return leftCurrent }
                if $0.registeredOn != $1.registeredOn { return $0.registeredOn > $1.registeredOn }
                return $0.id.uuidString < $1.id.uuidString
            }
            .first
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
