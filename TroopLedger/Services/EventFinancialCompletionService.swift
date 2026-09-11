import Foundation
import SwiftData

struct EventFeeCalculation: Equatable {
    let fixedCostsCents: Int64
    let perPersonCostsCents: Int64
    let expectedParticipants: Int
    let contingencyBasisPoints: Int
    let baseTotalCents: Int64
    let contingencyCents: Int64
    let totalCostCents: Int64
    let exactBreakEvenFeeCents: Int64
    let suggestedFeeCents: Int64
}

enum EventFeeCalculator {
    static func calculate(
        fixedCostsCents: Int64,
        perPersonCostsCents: Int64,
        expectedParticipants: Int,
        contingencyBasisPoints: Int,
        roundUpToCents: Int64 = 100
    ) -> EventFeeCalculation {
        let fixed = max(0, fixedCostsCents)
        let perPerson = max(0, perPersonCostsCents)
        let count = max(0, expectedParticipants)
        let basisPoints = max(0, contingencyBasisPoints)
        let base = addClamped(fixed, multiplyClamped(perPerson, Int64(count)))
        let contingency = divideRoundingUp(multiplyClamped(base, Int64(basisPoints)), by: 10_000)
        let total = addClamped(base, contingency)
        let exact = count == 0 ? 0 : divideRoundingUp(total, by: Int64(count))
        let increment = max(1, roundUpToCents)
        let suggested = exact == 0 ? 0 : multiplyClamped(divideRoundingUp(exact, by: increment), increment)
        return EventFeeCalculation(
            fixedCostsCents: fixed,
            perPersonCostsCents: perPerson,
            expectedParticipants: count,
            contingencyBasisPoints: basisPoints,
            baseTotalCents: base,
            contingencyCents: contingency,
            totalCostCents: total,
            exactBreakEvenFeeCents: exact,
            suggestedFeeCents: suggested
        )
    }

    private static func divideRoundingUp(_ value: Int64, by divisor: Int64) -> Int64 {
        guard value > 0, divisor > 0 else { return 0 }
        return value / divisor + (value % divisor == 0 ? 0 : 1)
    }

    private static func addClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }

    private static func multiplyClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? .max : result.partialValue
    }
}

enum EventFeeScheduleValidationError: LocalizedError, Equatable {
    case notEditable
    case wrongEvent
    case nameRequired
    case negativeFee
    case duplicateName
    case scheduleInUse

    var errorDescription: String? {
        switch self {
        case .notEditable: "This event is read-only or already closed."
        case .wrongEvent: "This fee schedule belongs to a different event."
        case .nameRequired: "Enter a fee schedule name."
        case .negativeFee: "Participant fees cannot be negative."
        case .duplicateName: "This event already has a fee schedule with that name."
        case .scheduleInUse: "This fee schedule is assigned to one or more participants and cannot be deleted."
        }
    }
}

enum EventFeeSchedulePolicy {
    static func validate(
        event: EventRecord,
        schedule: EventFeeScheduleRecord?,
        name: String,
        feeCents: Int64,
        schedules: [EventFeeScheduleRecord]
    ) throws {
        guard EventMutationPolicy.canEdit(event) else { throw EventFeeScheduleValidationError.notEditable }
        if let schedule, schedule.eventID != event.id { throw EventFeeScheduleValidationError.wrongEvent }
        let normalizedName = normalized(name)
        guard !normalizedName.isEmpty else { throw EventFeeScheduleValidationError.nameRequired }
        guard feeCents >= 0 else { throw EventFeeScheduleValidationError.negativeFee }
        guard !schedules.contains(where: {
            $0.eventID == event.id && $0.id != schedule?.id && normalized($0.name) == normalizedName
        }) else {
            throw EventFeeScheduleValidationError.duplicateName
        }
    }

    static func validateDeletion(_ schedule: EventFeeScheduleRecord, participants: [EventParticipant]) throws {
        guard !participants.contains(where: { $0.feeScheduleID == schedule.id }) else {
            throw EventFeeScheduleValidationError.scheduleInUse
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

enum EventParticipantValidationError: LocalizedError, Equatable {
    case notEditable
    case wrongEvent
    case nameRequired
    case negativeFee
    case negativePaid
    case feeScheduleWrongEvent
    case hasRecordedPayment(String)

    var errorDescription: String? {
        switch self {
        case .notEditable: "This event is read-only or already closed."
        case .wrongEvent: "This participant belongs to a different event."
        case .nameRequired: "Enter a guest name."
        case .negativeFee: "Participant fees cannot be negative."
        case .negativePaid: "Participant payments cannot be negative."
        case .feeScheduleWrongEvent: "The selected fee schedule belongs to a different event or no longer exists."
        case .hasRecordedPayment(let amount): "\(amount) was recorded as paid for this participant. Mark them Cancelled instead of removing the record of the payment."
        }
    }
}

enum EventParticipantPolicy {
    /// A roster row with a recorded payment is a money record; deleting it erases the only trace of that cash.
    static func validateDeletion(_ participant: EventParticipant) throws {
        guard participant.paidCents == 0 else {
            throw EventParticipantValidationError.hasRecordedPayment(Money.currency(cents: participant.paidCents))
        }
    }

    static func validate(
        event: EventRecord,
        participant: EventParticipant,
        guestName: String,
        feeCents: Int64,
        paidCents: Int64,
        feeScheduleID: UUID?,
        schedules: [EventFeeScheduleRecord]
    ) throws {
        guard EventMutationPolicy.canEdit(event) else { throw EventParticipantValidationError.notEditable }
        guard participant.eventID == event.id else { throw EventParticipantValidationError.wrongEvent }
        if participant.personID == nil, guestName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw EventParticipantValidationError.nameRequired
        }
        guard feeCents >= 0 else { throw EventParticipantValidationError.negativeFee }
        guard paidCents >= 0 else { throw EventParticipantValidationError.negativePaid }
        if let feeScheduleID {
            guard schedules.contains(where: { $0.id == feeScheduleID && $0.eventID == event.id }) else {
                throw EventParticipantValidationError.feeScheduleWrongEvent
            }
        }
    }
}

struct EventCloseoutPreview: Equatable {
    struct Participant: Identifiable, Equatable {
        let participantID: UUID
        let personID: UUID?
        let name: String
        let status: ParticipantStatus
        let feeScheduleName: String
        let feeCents: Int64
        let paidCents: Int64
        let balanceCents: Int64
        let proposedAdjustmentCents: Int64
        var id: UUID { participantID }
    }

    let eventID: UUID
    let actualIncomeCents: Int64
    let actualExpenseCents: Int64
    let actualParticipantCostCents: Int64
    let finalVarianceCents: Int64
    let unpaidCents: Int64
    let refundDueCents: Int64
    let participants: [Participant]
}

enum EventCloseoutError: LocalizedError, Equatable {
    case alreadyClosed
    case noFinancialParticipants
    case readOnly
    case previewEventMismatch
    case eventNotEnded
    case closeDateInFuture
    case closeDateBeforeEventEnd

    var errorDescription: String? {
        switch self {
        case .alreadyClosed: "This event already has a posted close-out and its roster is frozen."
        case .eventNotEnded: "This event has not ended yet. Closing it now would freeze the roster and totals before attendance and costs are final."
        case .closeDateInFuture: "The close date cannot be in the future."
        case .closeDateBeforeEventEnd: "The close date cannot be earlier than the day the event ended."
        case .noFinancialParticipants: "Add at least one registered, attended, or no-show participant before closing the event."
        case .readOnly: "Scoutbook-synchronized events must be detached from the calendar before changing their roster or financial plan."
        case .previewEventMismatch: "The close-out preview belongs to a different event. Refresh the close-out before posting."
        }
    }
}

enum EventDraftValidationError: LocalizedError, Equatable {
    case nameRequired
    case endBeforeStart
    case negativeBudget
    case deadlineAfterStart
    case notEditable

    var errorDescription: String? {
        switch self {
        case .nameRequired: "Enter an event name."
        case .endBeforeStart: "The event end cannot be before its start."
        case .negativeBudget: "Budgeted income and expenses cannot be negative."
        case .deadlineAfterStart: "The registration deadline cannot be after the event starts."
        case .notEditable: "This event is read-only or already closed."
        }
    }
}

enum EventDraftPolicy {
    static func validate(
        event: EventRecord?,
        name: String,
        startDate: Date,
        endDate: Date,
        registrationDeadline: Date?,
        budgetIncomeCents: Int64,
        budgetExpenseCents: Int64
    ) throws {
        if let event, !EventMutationPolicy.canEdit(event) { throw EventDraftValidationError.notEditable }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EventDraftValidationError.nameRequired }
        guard endDate >= startDate else { throw EventDraftValidationError.endBeforeStart }
        guard budgetIncomeCents >= 0, budgetExpenseCents >= 0 else { throw EventDraftValidationError.negativeBudget }
        if let registrationDeadline, registrationDeadline > startDate {
            throw EventDraftValidationError.deadlineAfterStart
        }
    }
}

enum EventMutationPolicy {
    static func canEdit(_ event: EventRecord) -> Bool {
        !event.isReadOnly && event.closedAt == nil
    }
}

enum EventCloseoutService {
    /// Participant statuses that carry money: fees, balances due, and close-out allocations all use this set.
    static let financiallyIncludedStatuses: Set<ParticipantStatus> = [.registered, .attended, .noShow]

    static func makePreview(
        event: EventRecord,
        participants: [EventParticipant],
        people: [PersonRecord],
        transactions: [LedgerTransaction],
        financialEntries: [EventFinancialEntry]
    ) throws -> EventCloseoutPreview {
        guard !event.isReadOnly else { throw EventCloseoutError.readOnly }
        guard event.closedAt == nil && event.closeoutID == nil else { throw EventCloseoutError.alreadyClosed }
        let included = participants.filter { $0.eventID == event.id && financiallyIncludedStatuses.contains($0.status) }
        guard !included.isEmpty else { throw EventCloseoutError.noFinancialParticipants }
        let peopleByID = Dictionary(people.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let actualEntries = financialEntries.filter { $0.eventID == event.id && !$0.isProjected }
        let linked = transactions.filter { $0.eventID == event.id && !$0.isTransfer }
        let income: Int64
        let expense: Int64
        if actualEntries.isEmpty {
            income = linked.filter { $0.direction == .income }.reduce(Int64(0)) { $0 + $1.amountCents }
            expense = linked.filter { $0.direction == .expense }.reduce(Int64(0)) { $0 + $1.amountCents }
        } else {
            income = actualEntries.filter { $0.direction == .income }.reduce(Int64(0)) { $0 + $1.amountCents }
            expense = actualEntries.filter { $0.direction == .expense }.reduce(Int64(0)) { $0 + $1.amountCents }
        }
        let perPerson = expense == 0 ? 0 : (expense + Int64(included.count) - 1) / Int64(included.count)
        let rows: [EventCloseoutPreview.Participant] = included.map { participant -> EventCloseoutPreview.Participant in
            let guest = participant.guestName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = participant.personID.flatMap { peopleByID[$0] } ?? (guest.isEmpty ? "Unnamed guest" : guest)
            return EventCloseoutPreview.Participant(
                participantID: participant.id,
                personID: participant.personID,
                name: name,
                status: participant.status,
                feeScheduleName: participant.feeScheduleNameSnapshot,
                feeCents: participant.feeCents,
                paidCents: participant.paidCents,
                balanceCents: participant.feeCents - participant.paidCents,
                proposedAdjustmentCents: perPerson - participant.feeCents
            )
        }.sorted { (lhs: EventCloseoutPreview.Participant, rhs: EventCloseoutPreview.Participant) in
            // The preview order is persisted as the close-out allocation order; two guests with the same
            // name must not come out in a different order on each run.
            let byName = lhs.name.localizedStandardCompare(rhs.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.participantID.uuidString < rhs.participantID.uuidString
        }
        return EventCloseoutPreview(
            eventID: event.id,
            actualIncomeCents: income,
            actualExpenseCents: expense,
            actualParticipantCostCents: perPerson,
            finalVarianceCents: income - expense,
            unpaidCents: rows.reduce(Int64(0)) { $0 + max(0, $1.balanceCents) },
            refundDueCents: rows.reduce(Int64(0)) { $0 + min(0, $1.balanceCents) },
            participants: rows
        )
    }

    @MainActor
    static func post(
        preview: EventCloseoutPreview,
        event: EventRecord,
        closeDate: Date,
        notes: String,
        postMemberAdjustments: Bool,
        existingCloseouts: [EventCloseoutRecord],
        now: Date = Date(),
        calendar: Calendar = .current,
        in context: ModelContext
    ) throws -> EventCloseoutRecord {
        guard !event.isReadOnly else { throw EventCloseoutError.readOnly }
        guard preview.eventID == event.id else { throw EventCloseoutError.previewEventMismatch }
        let today = calendar.startOfDay(for: now)
        guard calendar.startOfDay(for: event.endDate) <= today else { throw EventCloseoutError.eventNotEnded }
        guard calendar.startOfDay(for: closeDate) <= today else { throw EventCloseoutError.closeDateInFuture }
        guard calendar.startOfDay(for: closeDate) >= calendar.startOfDay(for: event.endDate) else { throw EventCloseoutError.closeDateBeforeEventEnd }
        guard event.closedAt == nil, event.closeoutID == nil, !existingCloseouts.contains(where: { $0.eventID == event.id }) else {
            throw EventCloseoutError.alreadyClosed
        }
        let closeout = EventCloseoutRecord(eventID: event.id, closedAt: closeDate)
        closeout.rosterCount = preview.participants.count
        closeout.actualIncomeCents = preview.actualIncomeCents
        closeout.actualExpenseCents = preview.actualExpenseCents
        closeout.actualParticipantCostCents = preview.actualParticipantCostCents
        closeout.unpaidCents = preview.unpaidCents
        closeout.refundDueCents = preview.refundDueCents
        closeout.finalVarianceCents = preview.finalVarianceCents
        closeout.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        context.insert(closeout)

        var adjustmentCount = 0
        for row in preview.participants {
            let allocation = EventCloseoutAllocationRecord(closeoutID: closeout.id, eventID: event.id, participantID: row.participantID)
            allocation.personID = row.personID
            allocation.participantNameSnapshot = row.name
            allocation.statusSnapshot = row.status.rawValue
            allocation.feeScheduleNameSnapshot = row.feeScheduleName
            allocation.feeCents = row.feeCents
            allocation.paidCents = row.paidCents
            allocation.balanceCents = row.balanceCents
            allocation.proposedAdjustmentCents = row.proposedAdjustmentCents
            if postMemberAdjustments, let personID = row.personID, row.proposedAdjustmentCents != 0 {
                let amount = abs(row.proposedAdjustmentCents)
                let kind: MemberEntryKind = row.proposedAdjustmentCents > 0 ? .adjustmentIncrease : .adjustmentDecrease
                let entry = MemberLedgerEntry(personID: personID, date: closeDate, kind: kind, amountCents: amount, category: "Event Close-out")
                entry.eventID = event.id
                entry.notes = "Final cost adjustment for \(event.name); posted from close-out \(closeout.id.uuidString.lowercased())."
                context.insert(entry)
                allocation.memberEntryID = entry.id
                adjustmentCount += 1
            }
            context.insert(allocation)
        }
        closeout.postedAdjustmentCount = adjustmentCount
        event.closedAt = closeDate
        event.closeoutID = closeout.id
        event.status = .completed
        AuditLogger.record(
            .create,
            recordType: "Event Close-out",
            recordID: closeout.id,
            summary: "Closed event \(event.name)",
            details: AuditLogger.details([
                ("Roster", String(closeout.rosterCount)),
                ("Actual income", Money.currency(cents: closeout.actualIncomeCents)),
                ("Actual expenses", Money.currency(cents: closeout.actualExpenseCents)),
                ("Per-participant cost", Money.currency(cents: closeout.actualParticipantCostCents)),
                ("Posted member adjustments", String(adjustmentCount)),
            ]),
            in: context
        )
        try context.save()
        return closeout
    }
}
