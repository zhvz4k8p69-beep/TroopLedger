import SwiftData
import SwiftUI

struct EventFeePlannerView: View {
    let event: EventRecord
    @Environment(\.modelContext) private var modelContext
    @Query private var allSchedules: [EventFeeScheduleRecord]
    @Query private var allParticipants: [EventParticipant]
    @State private var lines: [EventCostEstimateLine]
    @State private var expectedParticipants: Int
    @State private var contingencyPercent: Double
    @State private var showingNewSchedule = false
    @State private var editingSchedule: EventFeeScheduleRecord?
    @State private var showingNewLine = false
    @State private var editingLine: EventCostEstimateLine?
    @State private var hasUnloggedAssumptionChanges = false
    @State private var message: String?

    init(event: EventRecord) {
        self.event = event
        _lines = State(initialValue: EventCostEstimates.lines(for: event))
        _expectedParticipants = State(initialValue: event.feeCalculatorExpectedParticipants)
        _contingencyPercent = State(initialValue: Double(event.feeCalculatorContingencyBasisPoints) / 100)
    }

    private var schedules: [EventFeeScheduleRecord] {
        allSchedules.filter { $0.eventID == event.id }.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
    private var contingencyBasisPoints: Int { Int((max(0, contingencyPercent) * 100).rounded()) }
    private var calculation: EventFeeCalculation {
        EventCostEstimates.calculate(lines: lines, expectedParticipants: expectedParticipants, contingencyBasisPoints: contingencyBasisPoints)
    }
    private var canEdit: Bool { EventMutationPolicy.canEdit(event) }

    var body: some View {
        List {
            Section("Cost Estimates") {
                if lines.isEmpty {
                    Text("No estimates yet. Add the campsite or cabin, food, and other expected expenses.")
                        .foregroundStyle(.secondary)
                }
                ForEach(lines) { line in
                    Button { editingLine = line } label: { lineRow(line) }
                        .buttonStyle(.plain)
                        .disabled(!canEdit)
                        .deleteDisabled(!canEdit)
                }
                .onDelete(perform: deleteLines)
                Button("Add Cost Estimate", systemImage: "plus") { showingNewLine = true }.disabled(!canEdit)
                if !lines.isEmpty {
                    Text("Event totals: \(Money.currency(cents: calculation.fixedCostsCents)) split among participants, plus \(Money.currency(cents: calculation.perPersonCostsCents)) per person.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Assumptions") {
                Stepper("Expected participants: \(expectedParticipants)", value: $expectedParticipants, in: 0...500)
                    .disabled(!canEdit)
                HStack {
                    Text("Contingency / margin")
                    Spacer()
                    TextField("Percent", value: $contingencyPercent, format: .number.precision(.fractionLength(0...2)))
                        .multilineTextAlignment(.trailing).frame(maxWidth: 100)
                        .disabled(!canEdit)
                    Text("%").foregroundStyle(.secondary)
                }
                Text("Contingency is an explicit planning assumption, not hidden markup. The suggested fee rounds the exact break-even fee up to the next whole dollar.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Per-Person Cost") {
                if expectedParticipants == 0 && lines.contains(where: { $0.basis == .total }) {
                    Text("Enter the expected number of participants to split the event totals.")
                        .foregroundStyle(.secondary)
                }
                ForEach(lines) { line in
                    if let share = line.perPersonShareCents(expectedParticipants: expectedParticipants) {
                        money(line.displayName, share)
                    }
                }
                if calculation.contingencyCents > 0 {
                    money("Contingency / margin", EventFeeCalculator.divideRoundingUp(calculation.contingencyCents, by: Int64(max(1, expectedParticipants))))
                }
                money("Exact break-even fee", calculation.exactBreakEvenFeeCents)
                money("Suggested fee", calculation.suggestedFeeCents, emphasized: true)
            }
            Section("Event Totals") {
                money("Base total cost", calculation.baseTotalCents)
                money("Contingency / margin", calculation.contingencyCents)
                money("Planned total cost", calculation.totalCostCents)
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
        .onChange(of: expectedParticipants) { _, _ in assumptionsChanged() }
        .onChange(of: contingencyPercent) { _, _ in assumptionsChanged() }
        .onDisappear(perform: logAssumptionChangesIfNeeded)
        .sheet(isPresented: $showingNewLine) {
            EventCostEstimateFormView(line: nil) { saveLine($0) }
        }
        .sheet(item: $editingLine) { line in
            EventCostEstimateFormView(line: line) { saveLine($0) }
        }
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

    private func lineRow(_ line: EventCostEstimateLine) -> some View {
        HStack(spacing: 10) {
            Image(systemName: line.category.systemImage)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(line.displayName).fontWeight(.medium)
                Text(line.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? line.basis.rawValue : "\(line.category.rawValue) • \(line.basis.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                MoneyText(cents: line.amountCents)
                if line.basis == .perPerson {
                    Text("per person").font(.caption2).foregroundStyle(.secondary)
                } else if let share = line.perPersonShareCents(expectedParticipants: expectedParticipants) {
                    Text("\(Money.currency(cents: share)) each").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Persistence

    /// Every change writes through immediately: the plan is a scratchpad, and a treasurer who taps back out
    /// after adding the cabin rental should not lose it. The derived lump sums stay in step so the event
    /// summary and backups keep showing the same numbers as this screen.
    private func persist() {
        guard canEdit else { return }
        let calculation = calculation
        event.feeCalculatorEstimateLinesJSON = EventCostEstimates.encode(lines)
        event.feeCalculatorFixedCostsCents = calculation.fixedCostsCents
        event.feeCalculatorPerPersonCostsCents = calculation.perPersonCostsCents
        event.feeCalculatorExpectedParticipants = calculation.expectedParticipants
        event.feeCalculatorContingencyBasisPoints = calculation.contingencyBasisPoints
        event.feeCalculatorSuggestedFeeCents = calculation.suggestedFeeCents
        do {
            try modelContext.save()
        } catch {
            message = "The fee plan could not be saved: \(error.localizedDescription)"
        }
    }

    private func planDetails() -> String {
        AuditLogger.details([
            ("Expected participants", String(calculation.expectedParticipants)),
            ("Planned cost", Money.currency(cents: calculation.totalCostCents)),
            ("Suggested fee", Money.currency(cents: calculation.suggestedFeeCents)),
        ])
    }

    private func saveLine(_ line: EventCostEstimateLine) {
        guard canEdit else { return }
        let isNew: Bool
        if let index = lines.firstIndex(where: { $0.id == line.id }) {
            lines[index] = line
            isNew = false
        } else {
            lines.append(line)
            isNew = true
        }
        persist()
        AuditLogger.record(isNew ? .create : .edit, recordType: "Event Fee Plan", recordID: event.id,
                           summary: "\(isNew ? "Added" : "Edited") \(line.displayName) estimate for \(event.name)",
                           details: AuditLogger.details([("Amount", "\(Money.currency(cents: line.amountCents)) (\(line.basis.rawValue.lowercased()))")]) + "\n" + planDetails(),
                           in: modelContext)
        try? modelContext.save()
    }

    private func deleteLines(at offsets: IndexSet) {
        guard canEdit else { return }
        let removed = offsets.map { lines[$0] }
        lines.remove(atOffsets: offsets)
        persist()
        for line in removed {
            AuditLogger.record(.delete, recordType: "Event Fee Plan", recordID: event.id,
                               summary: "Removed \(line.displayName) estimate from \(event.name)",
                               details: planDetails(), in: modelContext)
        }
        try? modelContext.save()
    }

    /// The stepper fires once per tap, so assumption changes are saved as they happen but logged once, when
    /// the treasurer leaves the screen.
    private func assumptionsChanged() {
        guard canEdit else { return }
        hasUnloggedAssumptionChanges = true
        persist()
    }

    private func logAssumptionChangesIfNeeded() {
        guard hasUnloggedAssumptionChanges, canEdit else { return }
        hasUnloggedAssumptionChanges = false
        AuditLogger.record(.edit, recordType: "Event Fee Plan", recordID: event.id, summary: "Updated fee plan for \(event.name)", details: planDetails(), in: modelContext)
        try? modelContext.save()
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

private struct EventCostEstimateFormView: View {
    let line: EventCostEstimateLine?
    let onSave: (EventCostEstimateLine) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var category: EventCostCategory
    @State private var label: String
    @State private var amount: String
    @State private var basis: EventCostBasis

    init(line: EventCostEstimateLine?, onSave: @escaping (EventCostEstimateLine) -> Void) {
        self.line = line
        self.onSave = onSave
        _category = State(initialValue: line?.category ?? .lodging)
        _label = State(initialValue: line?.label ?? "")
        _amount = State(initialValue: line.map { Money.editableString(cents: $0.amountCents) } ?? "")
        _basis = State(initialValue: line?.basis ?? .total)
    }

    private var cents: Int64? {
        guard let value = Money.cents(from: amount), value >= 0, value <= Money.maximumCents else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Category", selection: $category) {
                    ForEach(EventCostCategory.allCases) { Label($0.rawValue, systemImage: $0.systemImage).tag($0) }
                }
                .onChange(of: category) { _, newValue in
                    // Food is almost always priced per head and lodging by the site; start from the likely basis
                    // until the treasurer picks one deliberately.
                    if line == nil { basis = newValue == .food ? .perPerson : .total }
                }
                TextField("Description (optional)", text: $label, prompt: Text(category == .lodging ? "e.g. Camp Squanto cabin" : category == .food ? "e.g. 5 meals" : "e.g. \(category.rawValue)"))
                AmountField(title: "Estimated amount", text: $amount)
                Picker("Amount is", selection: $basis) {
                    ForEach(EventCostBasis.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(basis == .total
                     ? "One amount for the whole event, divided evenly among the expected participants."
                     : "An amount for each participant; multiplied by the expected participants.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle(line == nil ? "New Cost Estimate" : "Edit Cost Estimate")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let cents else { return }
                        var saved = line ?? EventCostEstimateLine()
                        saved.category = category
                        saved.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved.amountCents = cents
                        saved.basis = basis
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(cents == nil)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 360)
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

    private func scheduleSnapshot(_ record: EventFeeScheduleRecord) -> [(String, String)] {
        [("Name", record.name), ("Fee", Money.currency(cents: record.feeCents)), ("Eligibility", record.eligibilityNotes), ("Default", String(record.isDefault))]
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
            let before = schedule.map(scheduleSnapshot)
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
            AuditLogger.record(isNew ? .create : .edit, recordType: "Event Fee Schedule", recordID: record.id, summary: "\(isNew ? "Created" : "Edited") \(record.name) fee schedule for \(event.name)", details: AuditLogger.details([("Fee", Money.currency(cents: record.feeCents)), ("Default", String(record.isDefault))] + (before.map { AuditLogger.changes(from: $0, to: scheduleSnapshot(record)) } ?? [])), in: modelContext)
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

    private var eventHasEnded: Bool {
        Calendar.current.startOfDay(for: event.endDate) <= Calendar.current.startOfDay(for: Date())
    }

    /// The service refuses a close date before the event ended or after today; the picker used to offer any
    /// past date, so a treasurer could pick one, confirm the close-out, and only then be told it was invalid.
    static func closeDateRange(eventEnd: Date, now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: now)
        let earliest = min(calendar.startOfDay(for: eventEnd), today)
        return earliest...max(now, earliest)
    }

    var body: some View {
        let preview = self.preview
        return List {
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
                if preview.participants.reduce(Int64(0), { $0 + $1.paidCents }) > preview.actualIncomeCents {
                    Section {
                        Label("The roster records \(Money.currency(cents: preview.participants.reduce(Int64(0), { $0 + $1.paidCents }))) paid, but only \(Money.currency(cents: preview.actualIncomeCents)) of income is linked to this event. Link the deposits before closing so collected cash is traceable.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
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
                    DatePicker("Close date", selection: $closeDate, in: Self.closeDateRange(eventEnd: event.endDate), displayedComponents: [.date])
                    Toggle("Post final-cost member adjustments", isOn: $postAdjustments)
                    Text("When enabled, each rostered member receives one balance increase or decrease for the difference between their recorded fee and actual per-participant cost. Guests remain in the close-out without a member-ledger entry.")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField("Close-out notes", text: $notes, axis: .vertical)
                    // The service rejects an event that has not ended; do not walk the user through the
                    // confirmation first.
                    Button("Review & Close Event", systemImage: "lock.fill") { confirming = true }
                        .disabled(!eventHasEnded)
                }
            } else {
                Section { Text("Add a registered, attended, or no-show participant before closing this event.").foregroundStyle(.secondary) }
            }
            if existing == nil, preview != nil, !eventHasEnded {
                Section {
                    Label("This event ends \(event.endDate.formatted(date: .abbreviated, time: .omitted)). It can be closed out once it has ended.", systemImage: "clock")
                        .foregroundStyle(.orange)
                }
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
