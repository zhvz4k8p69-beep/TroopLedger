import SwiftData
import SwiftUI

struct EventFeePlannerView: View {
    let event: EventRecord
    @Environment(\.modelContext) private var modelContext
    @Query private var allSchedules: [EventFeeScheduleRecord]
    @Query private var allParticipants: [EventParticipant]
    @State private var fixedCosts: String
    @State private var perPersonCosts: String
    @State private var expectedParticipants: Int
    @State private var contingencyPercent: Double
    @State private var showingNewSchedule = false
    @State private var editingSchedule: EventFeeScheduleRecord?
    @State private var message: String?

    init(event: EventRecord) {
        self.event = event
        _fixedCosts = State(initialValue: Money.editableString(cents: event.feeCalculatorFixedCostsCents))
        _perPersonCosts = State(initialValue: Money.editableString(cents: event.feeCalculatorPerPersonCostsCents))
        _expectedParticipants = State(initialValue: event.feeCalculatorExpectedParticipants)
        _contingencyPercent = State(initialValue: Double(event.feeCalculatorContingencyBasisPoints) / 100)
    }

    private var schedules: [EventFeeScheduleRecord] {
        allSchedules.filter { $0.eventID == event.id }.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
    private var calculation: EventFeeCalculation? {
        guard let fixed = Money.cents(from: fixedCosts), let per = Money.cents(from: perPersonCosts) else { return nil }
        return EventFeeCalculator.calculate(fixedCostsCents: fixed, perPersonCostsCents: per, expectedParticipants: expectedParticipants, contingencyBasisPoints: Int((contingencyPercent * 100).rounded()))
    }
    private var canEdit: Bool { EventMutationPolicy.canEdit(event) }

    var body: some View {
        List {
            Section("Break-even Assumptions") {
                AmountField(title: "Fixed costs", text: $fixedCosts)
                AmountField(title: "Per-person costs", text: $perPersonCosts)
                Stepper("Expected participants: \(expectedParticipants)", value: $expectedParticipants, in: 0...500)
                HStack {
                    Text("Contingency / margin")
                    Spacer()
                    TextField("Percent", value: $contingencyPercent, format: .number.precision(.fractionLength(0...2)))
                        .multilineTextAlignment(.trailing).frame(maxWidth: 100)
                    Text("%").foregroundStyle(.secondary)
                }
                Text("Contingency is an explicit planning assumption, not hidden markup. The suggested fee rounds the exact break-even fee up to the next whole dollar.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let calculation {
                Section("Calculation") {
                    money("Base total cost", calculation.baseTotalCents)
                    money("Contingency / margin", calculation.contingencyCents)
                    money("Planned total cost", calculation.totalCostCents)
                    money("Exact break-even fee", calculation.exactBreakEvenFeeCents)
                    money("Suggested fee", calculation.suggestedFeeCents, emphasized: true)
                    Button("Save Calculator Assumptions", systemImage: "checkmark.circle", action: saveCalculation)
                        .disabled(!canEdit)
                }
            }
            Section("Participant Fee Schedules") {
                if schedules.isEmpty { Text("No fee schedules. Add a standard, youth, adult, subsidized, or other event-specific fee.").foregroundStyle(.secondary) }
                ForEach(schedules) { schedule in
                    Button { editingSchedule = schedule } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Text(schedule.name).fontWeight(.medium); if schedule.isDefault { Text("DEFAULT").font(.caption2.weight(.bold)).foregroundStyle(.blue) } }
                                if !schedule.eligibilityNotes.isEmpty { Text(schedule.eligibilityNotes).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            MoneyText(cents: schedule.feeCents)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }.buttonStyle(.plain)
                        .disabled(!canEdit)
                        .deleteDisabled(!canEdit)
                }
                .onDelete(perform: deleteSchedules)
                Button("Add Fee Schedule", systemImage: "plus") { showingNewSchedule = true }.disabled(!canEdit)
            }
        }
        .pageHeader(title: "Fee Planner")
        .sheet(isPresented: $showingNewSchedule) { EventFeeScheduleFormView(event: event, schedule: nil) }
        .sheet(item: $editingSchedule) { EventFeeScheduleFormView(event: event, schedule: $0) }
        .alert("Fee Planner", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func saveCalculation() {
        guard canEdit, let calculation else { return }
        event.feeCalculatorFixedCostsCents = calculation.fixedCostsCents
        event.feeCalculatorPerPersonCostsCents = calculation.perPersonCostsCents
        event.feeCalculatorExpectedParticipants = calculation.expectedParticipants
        event.feeCalculatorContingencyBasisPoints = calculation.contingencyBasisPoints
        event.feeCalculatorSuggestedFeeCents = calculation.suggestedFeeCents
        AuditLogger.record(.edit, recordType: "Event Fee Plan", recordID: event.id, summary: "Updated fee plan for \(event.name)", details: AuditLogger.details([("Expected participants", String(calculation.expectedParticipants)), ("Planned cost", Money.currency(cents: calculation.totalCostCents)), ("Suggested fee", Money.currency(cents: calculation.suggestedFeeCents))]), in: modelContext)
        do {
            try modelContext.save()
        } catch {
            message = "The fee plan could not be saved: \(error.localizedDescription)"
        }
    }

    private func deleteSchedules(at offsets: IndexSet) {
        guard canEdit else { return }
        for index in offsets {
            let schedule = schedules[index]
            do {
                try EventFeeSchedulePolicy.validateDeletion(schedule, participants: allParticipants)
                AuditLogger.record(.delete, recordType: "Event Fee Schedule", recordID: schedule.id, summary: "Deleted \(schedule.name) fee schedule from \(event.name)", in: modelContext)
                modelContext.delete(schedule)
                try modelContext.save()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func money(_ label: String, _ cents: Int64, emphasized: Bool = false) -> some View {
        HStack { Text(label).fontWeight(emphasized ? .semibold : .regular); Spacer(); MoneyText(cents: cents).fontWeight(emphasized ? .semibold : .regular) }
    }
}

private struct EventFeeScheduleFormView: View {
    let event: EventRecord
    let schedule: EventFeeScheduleRecord?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allSchedules: [EventFeeScheduleRecord]
    @State private var name: String
    @State private var eligibility: String
    @State private var amount: String
    @State private var isDefault: Bool
    @State private var errorMessage: String?

    init(event: EventRecord, schedule: EventFeeScheduleRecord?) {
        self.event = event
        self.schedule = schedule
        _name = State(initialValue: schedule?.name ?? "")
        _eligibility = State(initialValue: schedule?.eligibilityNotes ?? "")
        _amount = State(initialValue: Money.editableString(cents: schedule?.feeCents ?? event.feeCalculatorSuggestedFeeCents))
        _isDefault = State(initialValue: schedule?.isDefault ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Schedule name", text: $name)
                AmountField(title: "Participant fee", text: $amount)
                TextField("Eligibility or purpose", text: $eligibility, axis: .vertical)
                Toggle("Default for this event", isOn: $isDefault)
            }
            .formStyle(.grouped)
            .navigationTitle(schedule == nil ? "New Fee Schedule" : "Edit Fee Schedule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 350)
        .alert("Fee Schedule", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var canSave: Bool {
        guard let cents = Money.cents(from: amount) else { return false }
        return (try? EventFeeSchedulePolicy.validate(
            event: event,
            schedule: schedule,
            name: name,
            feeCents: cents,
            schedules: allSchedules
        )) != nil
    }

    private func save() {
        do {
            guard let cents = Money.cents(from: amount) else { throw EventFeeScheduleValidationError.negativeFee }
            try EventFeeSchedulePolicy.validate(event: event, schedule: schedule, name: name, feeCents: cents, schedules: allSchedules)
            let record = schedule ?? EventFeeScheduleRecord(eventID: event.id, name: name, feeCents: cents)
            record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            record.eligibilityNotes = eligibility.trimmingCharacters(in: .whitespacesAndNewlines)
            record.feeCents = cents
            record.isDefault = isDefault
            record.modifiedAt = Date()
            if isDefault {
                for other in allSchedules where other.eventID == event.id && other.id != record.id { other.isDefault = false }
            }
            let isNew = schedule == nil
            if isNew { modelContext.insert(record) }
            AuditLogger.record(isNew ? .create : .edit, recordType: "Event Fee Schedule", recordID: record.id, summary: "\(isNew ? "Created" : "Edited") \(record.name) fee schedule for \(event.name)", details: AuditLogger.details([("Fee", Money.currency(cents: record.feeCents)), ("Default", String(record.isDefault))]), in: modelContext)
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct EventCloseoutView: View {
    let event: EventRecord
    @Environment(\.modelContext) private var modelContext
    @Query private var allParticipants: [EventParticipant]
    @Query private var people: [PersonRecord]
    @Query private var transactions: [LedgerTransaction]
    @Query private var financialEntries: [EventFinancialEntry]
    @Query private var closeouts: [EventCloseoutRecord]
    @State private var closeDate = Date()
    @State private var notes = ""
    @State private var postAdjustments = false
    @State private var confirming = false
    @State private var message: String?
    @State private var showingCloseoutMilestone = false

    private var existing: EventCloseoutRecord? { closeouts.first { $0.eventID == event.id } }
    private var preview: EventCloseoutPreview? {
        try? EventCloseoutService.makePreview(event: event, participants: allParticipants, people: people, transactions: transactions, financialEntries: financialEntries)
    }

    var body: some View {
        List {
            if let existing {
                Section("Posted Close-out") {
                    LabeledContent("Closed", value: existing.closedAt.formatted(date: .long, time: .shortened))
                    LabeledContent("Frozen roster", value: "\(existing.rosterCount) participants")
                    money("Actual income", existing.actualIncomeCents)
                    money("Actual expenses", existing.actualExpenseCents)
                    money("Actual cost per participant", existing.actualParticipantCostCents)
                    money("Unpaid", existing.unpaidCents)
                    money("Refund due", existing.refundDueCents)
                    money("Final variance", existing.finalVarianceCents)
                    LabeledContent("Member adjustments", value: "\(existing.postedAdjustmentCount)")
                    if !existing.notes.isEmpty { Text(existing.notes) }
                    Label("The close-out and roster snapshots are read-only.", systemImage: "lock.fill").foregroundStyle(.secondary)
                }
            } else if let preview {
                Section("Actual Results") {
                    money("Actual income", preview.actualIncomeCents)
                    money("Actual expenses", preview.actualExpenseCents)
                    money("Actual cost per participant", preview.actualParticipantCostCents, emphasized: true)
                    money("Final event variance", preview.finalVarianceCents)
                    money("Currently unpaid", preview.unpaidCents)
                    money("Currently refund due", preview.refundDueCents)
                }
                Section("Frozen Roster Preview") {
                    ForEach(preview.participants) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(row.name).fontWeight(.medium); Spacer(); MoneyText(cents: row.balanceCents, colorBySign: true) }
                            Text("\(row.status.rawValue) • fee \(Money.currency(cents: row.feeCents)) • paid \(Money.currency(cents: row.paidCents))")
                                .font(.caption).foregroundStyle(.secondary)
                            if row.proposedAdjustmentCents != 0 {
                                Text("Final-cost adjustment: \(Money.currency(cents: row.proposedAdjustmentCents))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Post Close-out") {
                    DatePicker("Close date", selection: $closeDate, displayedComponents: [.date])
                    Toggle("Post final-cost member adjustments", isOn: $postAdjustments)
                    Text("When enabled, each rostered member receives one balance increase or decrease for the difference between their recorded fee and actual per-participant cost. Guests remain in the close-out without a member-ledger entry.")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField("Close-out notes", text: $notes, axis: .vertical)
                    Button("Review & Close Event", systemImage: "lock.fill") { confirming = true }
                }
            } else {
                Section { Text("Add a registered, attended, or no-show participant before closing this event.").foregroundStyle(.secondary) }
            }
        }
        .pageHeader(title: "Event Close-out")
        .confirmationDialog("Close \(event.name)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Post Close-out", role: .destructive) { post() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This freezes the roster snapshot and actual event totals. The close-out cannot be edited or posted twice.")
        }
        .alert("Event Close-out", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .scoutMilestoneOverlay(
            isPresented: $showingCloseoutMilestone,
            title: "Camp Closed Out",
            subtitle: "The roster and event totals are safely locked.",
            systemImage: "tent.2.fill",
            badgeSystemImage: "lock.fill"
        )
    }

    private func post() {
        guard let preview else { return }
        do {
            _ = try EventCloseoutService.post(preview: preview, event: event, closeDate: closeDate, notes: notes, postMemberAdjustments: postAdjustments, existingCloseouts: closeouts, in: modelContext)
            showingCloseoutMilestone = true
        } catch { message = error.localizedDescription }
    }

    private func money(_ label: String, _ cents: Int64, emphasized: Bool = false) -> some View {
        HStack { Text(label).fontWeight(emphasized ? .semibold : .regular); Spacer(); MoneyText(cents: cents, colorBySign: true).fontWeight(emphasized ? .semibold : .regular) }
    }
}
