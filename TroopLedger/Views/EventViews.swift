import SwiftUI
import SwiftData

struct EventListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \EventRecord.startDate, order: .reverse) private var events: [EventRecord]
    @Query private var transactions: [LedgerTransaction]
    @Query private var eventEntries: [EventFinancialEntry]
    @Query private var participants: [EventParticipant]
    @Query private var depositAllocations: [DepositAllocationRecord]
    @Query private var reimbursements: [ReimbursementRequest]
    @Query private var memberEntries: [MemberLedgerEntry]
    @Query private var feeSchedules: [EventFeeScheduleRecord]
    @Query private var closeouts: [EventCloseoutRecord]
    @Query private var closeoutAllocations: [EventCloseoutAllocationRecord]
    @State private var showingNewEvent = false
    @State private var presentation = EventPresentation.calendar
    @State private var deletionMessage: String?
    @State private var pendingDeletion: EventRecord?

    private var upcomingEvents: [EventRecord] {
        events
            .filter { $0.endDate >= Calendar.current.startOfDay(for: Date()) && $0.status != .cancelled }
            .sorted { $0.startDate < $1.startDate }
    }

    private var expectedIncome: Int64 { upcomingEvents.reduce(0) { $0 + $1.budgetIncomeCents } }
    private var expectedExpense: Int64 { upcomingEvents.reduce(0) { $0 + $1.budgetExpenseCents } }
    private var balancesDue: Int64 {
        let upcomingIDs = Set(upcomingEvents.map(\.id))
        return participants
            .filter { participant in participant.eventID.map(upcomingIDs.contains) ?? false }
            .filter { EventCloseoutService.financiallyIncludedStatuses.contains($0.status) }
            .reduce(0) { $0 + max(0, $1.feeCents - $1.paidCents) }
    }

    var body: some View {
        VStack(spacing: 0) {
            eventHero

            HStack {
                Picker("Event view", selection: $presentation) {
                    ForEach(EventPresentation.allCases) { option in
                        Label(option.title, systemImage: option.systemImage).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 250)

                Spacer()

                if !upcomingEvents.isEmpty {
                    Text("\(upcomingEvents.count) upcoming")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(.regularMaterial)

            Divider()

            if events.isEmpty {
                EmptyMessage(title: "No events", message: "Create a campout, fundraiser, training, or other event and track its full budget and attendance.", systemImage: "calendar")
            } else if presentation == .calendar {
                calendarWorkspace
            } else {
                eventList
            }
        }
        .background { FieldbookPageBackground() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .pageToolbar(title: "Events") {
            Button("Add Event", systemImage: "plus") { showingNewEvent = true }
                .buttonStyle(.fieldbookProminent)
        }
        .sheet(isPresented: $showingNewEvent) { EventFormView() }
        .confirmationDialog(
            "Delete this event?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { event in
            Button("Delete \(event.name)", role: .destructive) { deleteEvent(event) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { event in
            Text("\(event.name) has no roster, fee, or financial records and will be removed permanently.")
        }
        .alert("Events", isPresented: Binding(
            get: { deletionMessage != nil },
            set: { if !$0 { deletionMessage = nil } }
        )) {
            Button("OK") { deletionMessage = nil }
        } message: {
            Text(deletionMessage ?? "")
        }
    }

    private var eventHero: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 12) {
                FieldbookActivityEmblem(systemImage: "tent.2.fill", size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Date().formatted(.dateTime.month(.wide))) program & money")
                        .font(.title2.bold())
                    Text("Plan attendance, collect fees, track spending, and close every event from one trailhead.")
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(.white.opacity(0.80))
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 10)], spacing: 10) {
                eventMetric("Upcoming events", String(upcomingEvents.count))
                eventMetric("Expected income", Money.currency(cents: expectedIncome))
                eventMetric("Expected cost", Money.currency(cents: expectedExpense))
                eventMetric("Balances due", Money.currency(cents: balancesDue))
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.13, blue: 0.08), Color(red: 0.14, green: 0.24, blue: 0.17)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func eventMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.13)) }
    }

    @ViewBuilder
    private var calendarWorkspace: some View {
#if os(macOS)
        GeometryReader { proxy in
            HStack(spacing: 0) {
                EventCalendarView(events: events)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if proxy.size.width >= 850 {
                    Divider()
                    upcomingEventCards
                        .frame(width: 350)
                }
            }
        }
#else
        EventCalendarView(events: events)
#endif
    }

    private var upcomingEventCards: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Upcoming")
                        .font(.headline)
                    Spacer()
                    Text("Next \(min(upcomingEvents.count, 5))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 2)

                if upcomingEvents.isEmpty {
                    ContentUnavailableView("No Upcoming Events", systemImage: "calendar")
                } else {
                    ForEach(Array(upcomingEvents.prefix(5))) { event in
                        eventSummaryCard(event)
                    }
                }
            }
            .padding(14)
        }
        .background(Color.fieldbookRaisedSurface.opacity(0.62))
    }

    private func eventSummaryCard(_ event: EventRecord) -> some View {
        let eventParticipants = participants.filter { $0.eventID == event.id }
        let eventBalance = eventParticipants
            .filter { EventCloseoutService.financiallyIncludedStatuses.contains($0.status) }
            .reduce(0) { $0 + max(0, $1.feeCents - $1.paidCents) }
        return NavigationLink {
            EventDetailView(event: event)
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 10) {
                    FieldbookDateMarker(date: event.startDate)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Label(
                            eventLocation(event).isEmpty ? event.classification.rawValue : eventLocation(event),
                            systemImage: FieldbookActivityIcon.systemImage(
                                for: event.name,
                                classification: event.classification
                            )
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(event.status.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.fieldbookPositive)
                }

                Divider()

                HStack(spacing: 12) {
                    eventCardValue("Roster", eventParticipants.isEmpty ? "Not started" : "\(eventParticipants.count) people")
                    eventCardValue("Due", Money.currency(cents: eventBalance))
                    eventCardValue("Budget", Money.currency(cents: event.budgetExpenseCents))
                }
            }
            .padding(12)
            .background(Color.fieldbookSurface, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).stroke(Color.fieldbookBorder) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func eventCardValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var eventList: some View {
        List {
            ForEach(events) { event in
                NavigationLink {
                    EventDetailView(event: event)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.name).font(.headline)
                            Text("\(event.classification.rawValue) • \(event.startDate.formatted(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened)) • \(event.status.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            let location = eventLocation(event)
                            if !location.isEmpty {
                                Label(location, systemImage: "mappin.and.ellipse")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if event.isReadOnly {
                            Label("Scoutbook calendar", systemImage: "link")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(Color.fieldbookInfo)
                        }
                        if !event.isReadOnly {
                            MoneyText(cents: eventNet(event), colorBySign: true)
                        }
                    }
                }
            }
            .onDelete(perform: deleteEvents)
        }
    }

    private func eventNet(_ event: EventRecord) -> Int64 {
        let importedEntries = eventEntries.filter { $0.eventID == event.id && !$0.isProjected }
        if !importedEntries.isEmpty {
            return importedEntries.reduce(0) { partial, entry in
                partial + (entry.direction == .income ? entry.amountCents : -entry.amountCents)
            }
        }
        return transactions.filter { $0.eventID == event.id }.reduce(0) { $0 + $1.signedAmountCents }
    }

    private func eventLocation(_ event: EventRecord) -> String {
        [event.location, event.address]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }

    private func deleteEvents(at offsets: IndexSet) {
        guard let index = offsets.first else { return }
        let event = events[index]
        guard !event.isReadOnly,
              RecordDeletionPolicy.canDeleteEvent(
                event.id,
                transactions: transactions,
                depositAllocations: depositAllocations,
                reimbursements: reimbursements,
                memberEntries: memberEntries,
                feeSchedules: feeSchedules,
                participants: participants,
                closeouts: closeouts,
                closeoutAllocations: closeoutAllocations,
                financialEntries: eventEntries
              ) else {
            deletionMessage = "This event is synchronized or referenced by roster, fee, reimbursement, member-ledger, close-out, or financial records and cannot be deleted."
            return
        }
        pendingDeletion = event
    }

    private func deleteEvent(_ event: EventRecord) {
        do {
            AuditLogger.record(
                .delete,
                recordType: "Event",
                recordID: event.id,
                summary: "Deleted event \(event.name)",
                details: AuditLogger.details([
                    ("Start", event.startDate.formatted(date: .numeric, time: event.isAllDay ? .omitted : .shortened)),
                    ("Status", event.status.rawValue),
                ]),
                in: modelContext
            )
            modelContext.delete(event)
            pendingDeletion = nil
            try modelContext.save()
        } catch {
            deletionMessage = "The event could not be deleted: \(error.localizedDescription)"
        }
    }
}

private enum EventPresentation: String, CaseIterable, Identifiable {
    case calendar
    case list

    var id: String { rawValue }
    var title: String { self == .calendar ? "Calendar" : "List" }
    var systemImage: String { self == .calendar ? "calendar" : "list.bullet" }
}

private struct EventCalendarView: View {
    let events: [EventRecord]
    @State private var visibleMonth: Date
    @State private var selectedDate: Date
    private let calendar = Calendar.current

    init(events: [EventRecord]) {
        self.events = events
        // `events` arrives sorted by start date descending, so `first` would be the farthest-future event.
        // Fall back to the nearest event that has not ended yet, then to today.
        let today = Calendar.current.startOfDay(for: Date())
        let initialDate = events.first(where: { Calendar.current.isDate($0.startDate, equalTo: Date(), toGranularity: .month) })?.startDate
            ?? events.filter { $0.endDate >= today }.min(by: { $0.startDate < $1.startDate })?.startDate
            ?? Date()
        _visibleMonth = State(initialValue: Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: initialDate)) ?? initialDate)
        _selectedDate = State(initialValue: initialDate)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let offset = max(0, calendar.firstWeekday - 1)
        return Array(symbols[offset...] + symbols[..<offset])
    }

    private var days: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: visibleMonth),
              let dayRange = calendar.range(of: .day, in: .month, for: visibleMonth) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + dayRange.compactMap {
            calendar.date(byAdding: .day, value: $0 - 1, to: interval.start)
        }
    }

    private var selectedEvents: [EventRecord] {
        eventsForDay(selectedDate).sorted { $0.startDate < $1.startDate }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button("Previous month", systemImage: "chevron.left") { moveMonth(-1) }.labelStyle(.iconOnly)
                    Button("Next month", systemImage: "chevron.right") { moveMonth(1) }.labelStyle(.iconOnly)
                    Text(visibleMonth.formatted(.dateTime.month(.wide).year()))
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("Today") {
                        visibleMonth = startOfMonth(Date())
                        selectedDate = Date()
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                        if let date {
                            dayCell(date)
                        } else {
                            Color.clear.frame(minHeight: 64)
                        }
                    }
                }

                Divider()
                Text(selectedDate.formatted(date: .complete, time: .omitted))
                    .font(.headline)
                if selectedEvents.isEmpty {
                    Text("No events on this day.").foregroundStyle(.secondary)
                } else {
                    ForEach(selectedEvents) { event in
                        NavigationLink {
                            EventDetailView(event: event)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(event.name).font(.headline)
                                    Text("\(event.classification.rawValue) • \(event.status.rawValue)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if event.dateIsApproximate {
                                    Label("Approximate date", systemImage: "calendar.badge.exclamationmark")
                                        .labelStyle(.iconOnly)
                                        .foregroundStyle(Color.fieldbookWarning)
                                }
                                if event.isReadOnly {
                                    Label("Scoutbook calendar", systemImage: "link")
                                        .labelStyle(.iconOnly)
                                        .foregroundStyle(Color.fieldbookInfo)
                                }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding([.horizontal, .bottom])
        }
    }

    @ViewBuilder
    private func dayCell(_ date: Date) -> some View {
        let dayEvents = eventsForDay(date)
        let selected = calendar.isDate(date, inSameDayAs: selectedDate)
        Button {
            selectedDate = date
        } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.body.weight(calendar.isDateInToday(date) ? .bold : .regular))
                HStack(spacing: 3) {
                    ForEach(0..<min(dayEvents.count, 3), id: \.self) { _ in
                        Circle().frame(width: 5, height: 5)
                    }
                    if dayEvents.count > 3 { Text("+").font(.caption2) }
                }
                .foregroundStyle(dayEvents.contains(where: \.dateIsApproximate) ? Color.fieldbookWarning : Color.fieldbookAccent)
                .frame(height: 8)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(selected ? Color.fieldbookAccent.opacity(0.18) : Color.fieldbookRaisedSurface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if calendar.isDateInToday(date) {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.fieldbookAccent, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(date.formatted(date: .complete, time: .omitted)), \(dayEvents.count) events")
    }

    private func eventsForDay(_ date: Date) -> [EventRecord] {
        let day = calendar.startOfDay(for: date)
        return events.filter {
            day >= calendar.startOfDay(for: $0.startDate) && day <= calendar.startOfDay(for: $0.endDate)
        }
    }

    private func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private func moveMonth(_ amount: Int) {
        visibleMonth = calendar.date(byAdding: .month, value: amount, to: visibleMonth) ?? visibleMonth
        selectedDate = visibleMonth
    }
}

struct EventDetailView: View {
    let event: EventRecord
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LedgerTransaction.date, order: .reverse) private var allTransactions: [LedgerTransaction]
    @Query(sort: \EventFinancialEntry.date) private var allEventEntries: [EventFinancialEntry]
    @Query(sort: [SortDescriptor(\PersonRecord.lastName), SortDescriptor(\PersonRecord.firstName)]) private var people: [PersonRecord]
    @Query private var allParticipants: [EventParticipant]
    @State private var showingEdit = false
    @State private var showingParticipantPicker = false
    @State private var participantToEdit: EventParticipant?
    @State private var notesDraft = ""
    @State private var notesError: String?
    @FocusState private var notesFocused: Bool

    private var transactions: [LedgerTransaction] { allTransactions.filter { $0.eventID == event.id } }
    private var eventEntries: [EventFinancialEntry] { allEventEntries.filter { $0.eventID == event.id } }
    private var participants: [EventParticipant] { allParticipants.filter { $0.eventID == event.id } }
    private var actualIncome: Int64 {
        if !eventEntries.isEmpty { return eventEntries.filter { !$0.isProjected && $0.direction == .income }.reduce(0) { $0 + $1.amountCents } }
        return transactions.filter { $0.direction == .income }.reduce(0) { $0 + $1.amountCents }
    }
    private var actualExpense: Int64 {
        if !eventEntries.isEmpty { return eventEntries.filter { !$0.isProjected && $0.direction == .expense }.reduce(0) { $0 + $1.amountCents } }
        return transactions.filter { $0.direction == .expense }.reduce(0) { $0 + $1.amountCents }
    }

    var body: some View {
        List {
            Section("Event") {
                LabeledContent("Classification") {
                    Label(event.classification.rawValue, systemImage: event.classification.systemImage)
                }
                LabeledContent("Category", value: event.category)
                LabeledContent("Status", value: event.status.rawValue)
                if !event.coordinator.isEmpty { LabeledContent("Coordinator", value: event.coordinator) }
                if !event.registrationReference.isEmpty { LabeledContent("Registration reference", value: event.registrationReference) }
                if event.capacity > 0 { LabeledContent("Capacity", value: "\(event.capacity)") }
                if event.isReadOnly {
                    Label("Read-only Scoutbook calendar event", systemImage: "link")
                        .foregroundStyle(Color.fieldbookInfo)
                }
            }

            Section("Date and Time") {
                LabeledContent("Starts", value: formattedStart)
                LabeledContent("Ends", value: formattedEnd)
                LabeledContent("Duration", value: durationDescription)
                if event.isAllDay {
                    Label("All-day event", systemImage: "sun.max")
                        .foregroundStyle(.secondary)
                }
                if let deadline = event.registrationDeadline {
                    LabeledContent("Registration deadline", value: deadline.formatted(date: .long, time: .shortened))
                }
                if event.dateIsApproximate {
                    Label("Imported month only; confirm the exact dates", systemImage: "calendar.badge.exclamationmark")
                        .foregroundStyle(Color.fieldbookWarning)
                }
            }

            Section("Location") {
                if event.mapSearchQuery.isEmpty {
                    Text("No location has been entered.").foregroundStyle(.secondary)
                } else {
                    if !event.location.isEmpty { LabeledContent("Place", value: event.location) }
                    if !event.address.isEmpty {
                        LabeledContent("Address") {
                            Text(event.address).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }
                    }
                    if !event.locationDetails.isEmpty {
                        LabeledContent("Instructions") {
                            Text(event.locationDetails).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }
                    }
                    EventLocationMapView(query: event.mapSearchQuery, displayName: event.location)
                }
            }

            Section("Notes") {
                if !EventMutationPolicy.canEdit(event) {
                    // Synced and closed events are frozen; a live TextEditor binding would silently rewrite a
                    // closed event's record with no audit entry.
                    if event.notes.isEmpty {
                        Text(event.isReadOnly ? "No notes in the Scoutbook calendar feed." : "No notes were recorded before this event was closed.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(event.notes).textSelection(.enabled)
                    }
                } else {
                    ZStack(alignment: .topLeading) {
                        if notesDraft.isEmpty {
                            Text("Add planning notes, contacts, logistics, or follow-up details…")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                        }
                        // Edits accumulate in a draft and are committed (and audited) when the editor loses
                        // focus or the screen closes, instead of rewriting the record on every keystroke.
                        TextEditor(text: $notesDraft)
                            .focused($notesFocused)
                            .frame(minHeight: 130)
                            .scrollContentBackground(.hidden)
                    }
                    if let notesError {
                        Label(notesError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
            }

            Section("Budget and Actual") {
                LabeledContent("Budgeted income") { MoneyText(cents: event.budgetIncomeCents) }
                LabeledContent("Actual income") { MoneyText(cents: actualIncome) }
                LabeledContent("Budgeted expenses") { MoneyText(cents: event.budgetExpenseCents) }
                LabeledContent("Actual expenses") { MoneyText(cents: actualExpense) }
                LabeledContent("Actual net") { MoneyText(cents: actualIncome - actualExpense, colorBySign: true) }
                if event.feeCalculatorSuggestedFeeCents > 0 {
                    LabeledContent("Suggested participant fee") { MoneyText(cents: event.feeCalculatorSuggestedFeeCents) }
                }
            }

            Section("Financial Completion") {
                if event.isReadOnly {
                    Label("Detach this event from Scoutbook before changing its financial plan or roster.", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                } else {
                    NavigationLink { EventFeePlannerView(event: event) } label: {
                        Label("Fee Calculator & Schedules", systemImage: "function")
                    }
                    NavigationLink { EventCloseoutView(event: event) } label: {
                        Label(event.closedAt == nil ? "Close Out Event" : "View Posted Close-out", systemImage: event.closedAt == nil ? "checkmark.seal" : "lock.fill")
                    }
                }
                if let closedAt = event.closedAt {
                    Text("Roster and close-out totals frozen \(closedAt.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Participants (\(participants.count))") {
                if participants.isEmpty {
                    Text("No participants yet").foregroundStyle(.secondary)
                } else {
                    ForEach(participants) { participant in
                        Button { if EventMutationPolicy.canEdit(event) { participantToEdit = participant } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(participantName(participant)).font(.headline)
                                    Text(participant.status.rawValue).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                MoneyText(cents: participant.feeCents - participant.paidCents, colorBySign: true)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!EventMutationPolicy.canEdit(event))
                    }
                    .onDelete(perform: deleteParticipants)
                    .deleteDisabled(!EventMutationPolicy.canEdit(event))
                }
                if !event.isReadOnly && event.closedAt == nil {
                    Button("Add Participants", systemImage: "person.badge.plus") { showingParticipantPicker = true }
                }
            }

            Section("Linked Transactions") {
                if transactions.isEmpty {
                    Text("Link transactions to this event from the transaction form.").foregroundStyle(.secondary)
                } else {
                    ForEach(transactions) { transaction in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(transaction.payee.isEmpty ? transaction.category : transaction.payee)
                                Text(transaction.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            MoneyText(cents: transaction.signedAmountCents, colorBySign: true)
                        }
                    }
                }
            }

            if !eventEntries.isEmpty {
                Section("Imported Event Detail") {
                    Text("These rows preserve the event worksheet detail. They do not change the checking-account balance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(eventEntries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.entryDescription)
                                Text(entry.isProjected ? "Projected" : "Actual")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            MoneyText(cents: entry.direction == .income ? entry.amountCents : -entry.amountCents, colorBySign: true)
                        }
                    }
                }
            }
        }
        .pageToolbar(title: event.name) {
            NavigationLink {
                EventRosterView(event: event)
            } label: {
                Label("Event Roster", systemImage: "person.crop.rectangle.stack")
            }
            if event.isReadOnly {
                Label("Synced from Scoutbook", systemImage: "link")
            } else if event.closedAt == nil {
                Button("Edit Event", systemImage: "pencil") { showingEdit = true }
            }
        }
        .sheet(isPresented: $showingEdit) { EventFormView(event: event) }
        .sheet(isPresented: $showingParticipantPicker) { EventRosterBuilderView(event: event) }
        .sheet(item: $participantToEdit) { EventParticipantFormView(event: event, participant: $0) }
        .onAppear { notesDraft = event.notes }
        .onChange(of: event.notes) { _, newValue in if !notesFocused { notesDraft = newValue } }
        .onChange(of: notesFocused) { _, focused in if !focused { commitNotes() } }
        .onDisappear { commitNotes() }
    }

    private func commitNotes() {
        guard notesDraft != event.notes else { return }
        guard EventMutationPolicy.canEdit(event) else {
            notesDraft = event.notes
            return
        }
        let previous = event.notes
        event.notes = notesDraft
        AuditLogger.record(
            .edit,
            recordType: "Event",
            recordID: event.id,
            summary: "Edited notes for \(event.name)",
            details: AuditLogger.details([
                ("Previous notes", previous),
                ("New notes", event.notes),
            ]),
            in: modelContext
        )
        do {
            try modelContext.save()
            notesError = nil
        } catch {
            notesError = "Notes could not be saved: \(error.localizedDescription)"
        }
    }

    private var formattedStart: String {
        event.startDate.formatted(date: .complete, time: event.isAllDay ? .omitted : .shortened)
    }

    private var formattedEnd: String {
        event.endDate.formatted(date: .complete, time: event.isAllDay ? .omitted : .shortened)
    }

    private var durationDescription: String {
        if event.isAllDay {
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: event.startDate)
            let end = calendar.startOfDay(for: event.endDate)
            let days = max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
            return days == 1 ? "1 day" : "\(days) days"
        }
        let totalMinutes = max(0, Int(event.endDate.timeIntervalSince(event.startDate) / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        let components = [days > 0 ? "\(days)d" : nil, hours > 0 ? "\(hours)h" : nil, minutes > 0 ? "\(minutes)m" : nil]
            .compactMap { $0 }
            .joined(separator: " ")
        return components.isEmpty ? "0m" : components
    }

    private func participantName(_ participant: EventParticipant) -> String {
        let guestName = participant.guestName.trimmingCharacters(in: .whitespacesAndNewlines)
        return participant.personID.flatMap { id in people.first { $0.id == id }?.displayName }
            ?? (guestName.isEmpty ? nil : guestName)
            ?? "Unnamed guest"
    }

    private func deleteParticipants(at offsets: IndexSet) {
        guard EventMutationPolicy.canEdit(event) else { return }
        for index in offsets {
            let participant = participants[index]
            AuditLogger.record(
                .delete,
                recordType: "Event Participant",
                recordID: participant.id,
                summary: "Removed \(participantName(participant)) from \(event.name)",
                in: modelContext
            )
            modelContext.delete(participant)
        }
        do {
            try modelContext.save()
        } catch {
            notesError = "The roster change could not be saved: \(error.localizedDescription)"
        }
    }
}

struct EventFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    private let event: EventRecord?
    @State private var name: String
    @State private var category: String
    @State private var classification: EventClassification
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var isAllDay: Bool
    @State private var hasDeadline: Bool
    @State private var registrationDeadline: Date
    @State private var location: String
    @State private var address: String
    @State private var locationDetails: String
    @State private var coordinator: String
    @State private var registrationReference: String
    @State private var status: EventStatus
    @State private var capacity: Int
    @State private var budgetIncome: String
    @State private var budgetExpense: String
    @State private var notes: String
    @State private var dateIsApproximate: Bool
    @State private var errorMessage: String?

    init(event: EventRecord? = nil) {
        self.event = event
        let defaultStart = event?.startDate ?? Date()
        _name = State(initialValue: event?.name ?? "")
        _category = State(initialValue: event?.category ?? "Camping")
        _classification = State(initialValue: event?.classification ?? .troop)
        _startDate = State(initialValue: defaultStart)
        _endDate = State(initialValue: event?.endDate ?? Calendar.current.date(byAdding: .hour, value: 1, to: defaultStart) ?? defaultStart)
        _isAllDay = State(initialValue: event?.isAllDay ?? false)
        _hasDeadline = State(initialValue: event?.registrationDeadline != nil)
        _registrationDeadline = State(initialValue: event?.registrationDeadline ?? Date())
        _location = State(initialValue: event?.location ?? "")
        _address = State(initialValue: event?.address ?? "")
        _locationDetails = State(initialValue: event?.locationDetails ?? "")
        _coordinator = State(initialValue: event?.coordinator ?? "")
        _registrationReference = State(initialValue: event?.registrationReference ?? "")
        _status = State(initialValue: event?.status ?? .planning)
        _capacity = State(initialValue: event?.capacity ?? 0)
        _budgetIncome = State(initialValue: Money.editableString(cents: event?.budgetIncomeCents ?? 0))
        _budgetExpense = State(initialValue: Money.editableString(cents: event?.budgetExpenseCents ?? 0))
        _notes = State(initialValue: event?.notes ?? "")
        _dateIsApproximate = State(initialValue: event?.dateIsApproximate ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    TextField("Name", text: $name)
                    TextField("Category", text: $category)
                    Picker("Classification", selection: $classification) {
                        ForEach(EventClassification.allCases) { option in
                            Label(option.rawValue, systemImage: option.systemImage).tag(option)
                        }
                    }
                    Picker("Status", selection: $status) { ForEach(EventStatus.allCases) { Text($0.rawValue).tag($0) } }
                    TextField("Coordinator", text: $coordinator)
                    TextField("Council or venue confirmation number", text: $registrationReference)
                    Stepper("Capacity: \(capacity == 0 ? "Not set" : "\(capacity)")", value: $capacity, in: 0...500)
                }
                Section("Date and Time") {
                    Toggle("All-day event", isOn: $isAllDay)
                    DatePicker("Starts", selection: $startDate, displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                    DatePicker("Ends", selection: $endDate, in: startDate..., displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                    Toggle("Dates are approximate", isOn: $dateIsApproximate)
                    Toggle("Registration deadline", isOn: $hasDeadline)
                    if hasDeadline { DatePicker("Deadline", selection: $registrationDeadline) }
                }
                Section("Location") {
                    TextField("Place or venue", text: $location)
                    TextField("Street address", text: $address)
                    TextField("Site, parking, or meeting instructions", text: $locationDetails, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section("Budget") {
                    AmountField(title: "Budgeted income", text: $budgetIncome)
                    AmountField(title: "Budgeted expenses", text: $budgetExpense)
                }
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 140)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(event == nil ? "New Event" : "Edit Event")
            // The Ends picker only constrains its own display; moving Starts past Ends used to disable Save
            // with no explanation.
            .onChange(of: startDate) { _, newStart in
                if endDate < newStart { endDate = newStart }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
        }
        .frame(minWidth: 520, minHeight: 760)
        .alert("Event", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func snapshot(_ record: EventRecord) -> [(String, String)] {
        [
            ("Name", record.name),
            ("Category", record.category),
            ("Classification", record.classification.rawValue),
            ("Start", record.startDate.formatted(date: .numeric, time: record.isAllDay ? .omitted : .shortened)),
            ("End", record.endDate.formatted(date: .numeric, time: record.isAllDay ? .omitted : .shortened)),
            ("Registration deadline", record.registrationDeadline?.formatted(date: .numeric, time: .shortened) ?? ""),
            ("Location", record.mapSearchQuery),
            ("Coordinator", record.coordinator),
            ("Status", record.status.rawValue),
            ("Capacity", String(record.capacity)),
            ("Budgeted income", Money.currency(cents: record.budgetIncomeCents)),
            ("Budgeted expenses", Money.currency(cents: record.budgetExpenseCents)),
        ]
    }

    private var canSave: Bool {
        guard let income = Money.cents(from: budgetIncome), let expense = Money.cents(from: budgetExpense) else { return false }
        return (try? EventDraftPolicy.validate(
            event: event,
            name: name,
            startDate: startDate,
            endDate: endDate,
            registrationDeadline: hasDeadline ? registrationDeadline : nil,
            budgetIncomeCents: income,
            budgetExpenseCents: expense
        )) != nil
    }

    private func save() {
        do {
            guard let income = Money.cents(from: budgetIncome), let expense = Money.cents(from: budgetExpense) else {
                throw EventDraftValidationError.negativeBudget
            }
            let deadline = hasDeadline ? registrationDeadline : nil
            try EventDraftPolicy.validate(
                event: event,
                name: name,
                startDate: startDate,
                endDate: endDate,
                registrationDeadline: deadline,
                budgetIncomeCents: income,
                budgetExpenseCents: expense
            )
            let record = event ?? EventRecord(name: name, startDate: startDate, endDate: endDate)
            let before = event.map(snapshot)
            record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            record.category = category.trimmingCharacters(in: .whitespacesAndNewlines)
            record.classification = classification
            record.startDate = startDate
            record.endDate = endDate
            record.isAllDay = isAllDay
            record.registrationDeadline = deadline
            record.location = location.trimmingCharacters(in: .whitespacesAndNewlines)
            record.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
            record.locationDetails = locationDetails.trimmingCharacters(in: .whitespacesAndNewlines)
            record.coordinator = coordinator.trimmingCharacters(in: .whitespacesAndNewlines)
            record.registrationReference = registrationReference.trimmingCharacters(in: .whitespacesAndNewlines)
            record.status = status
            record.capacity = capacity
            record.budgetIncomeCents = income
            record.budgetExpenseCents = expense
            record.notes = notes
            record.dateIsApproximate = dateIsApproximate
            let isNew = event == nil
            if isNew { modelContext.insert(record) }
            AuditLogger.record(
                isNew ? .create : .edit,
                recordType: "Event",
                recordID: record.id,
                summary: "\(isNew ? "Created" : "Edited") event \(record.name)",
                details: AuditLogger.details([
                ("Start", record.startDate.formatted(date: .numeric, time: record.isAllDay ? .omitted : .shortened)),
                ("End", record.endDate.formatted(date: .numeric, time: record.isAllDay ? .omitted : .shortened)),
                ("Status", record.status.rawValue),
                ("Location", record.mapSearchQuery),
                ("Budgeted income", Money.currency(cents: record.budgetIncomeCents)),
                ("Budgeted expenses", Money.currency(cents: record.budgetExpenseCents)),
                ] + (before.map { AuditLogger.changes(from: $0, to: snapshot(record)) } ?? [])),
                in: modelContext
            )
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct EventParticipantFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let event: EventRecord
    let participant: EventParticipant
    @Query(sort: [SortDescriptor(\PersonRecord.lastName), SortDescriptor(\PersonRecord.firstName)]) private var people: [PersonRecord]
    @Query private var allFeeSchedules: [EventFeeScheduleRecord]
    @State private var guestName: String
    @State private var status: ParticipantStatus
    @State private var fee: String
    @State private var paid: String
    @State private var selectedFeeScheduleID: UUID?
    @State private var transportation: String
    @State private var notes: String
    @State private var errorMessage: String?

    init(event: EventRecord, participant: EventParticipant) {
        self.event = event
        self.participant = participant
        _guestName = State(initialValue: participant.guestName)
        _status = State(initialValue: participant.status)
        _fee = State(initialValue: Money.editableString(cents: participant.feeCents))
        _paid = State(initialValue: Money.editableString(cents: participant.paidCents))
        _selectedFeeScheduleID = State(initialValue: participant.feeScheduleID)
        _transportation = State(initialValue: participant.transportation)
        _notes = State(initialValue: participant.notes)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Participant") {
                    if let personID = participant.personID,
                       let person = people.first(where: { $0.id == personID }) {
                        LabeledContent("Person", value: person.displayName)
                    } else {
                        TextField("Guest name", text: $guestName)
                    }
                    Picker("Status", selection: $status) { ForEach(ParticipantStatus.allCases) { Text($0.rawValue).tag($0) } }
                    AmountField(title: "Fee", text: $fee)
                    if !feeSchedules.isEmpty {
                        Picker("Fee schedule", selection: $selectedFeeScheduleID) {
                            Text("Custom fee").tag(UUID?.none)
                            ForEach(feeSchedules) { schedule in Text("\(schedule.name) — \(Money.currency(cents: schedule.feeCents))").tag(Optional(schedule.id)) }
                        }
                        .onChange(of: selectedFeeScheduleID) { _, newValue in
                            if let schedule = feeSchedules.first(where: { $0.id == newValue }) { fee = Money.editableString(cents: schedule.feeCents) }
                        }
                    }
                    AmountField(title: "Paid", text: $paid)
                    TextField("Transportation", text: $transportation)
                }
                Section("Notes") { TextField("Optional notes", text: $notes, axis: .vertical) }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Participant")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
        }
        .frame(minWidth: 450, minHeight: 480)
        .alert("Participant", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var canSave: Bool {
        guard let feeCents = Money.cents(from: fee), let paidCents = Money.cents(from: paid) else { return false }
        return (try? EventParticipantPolicy.validate(
            event: event,
            participant: participant,
            guestName: guestName,
            feeCents: feeCents,
            paidCents: paidCents,
            feeScheduleID: selectedFeeScheduleID,
            schedules: allFeeSchedules
        )) != nil
    }

    private var feeSchedules: [EventFeeScheduleRecord] {
        allFeeSchedules.filter { $0.eventID == event.id }.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func save() {
        do {
            guard let feeCents = Money.cents(from: fee), let paidCents = Money.cents(from: paid) else {
                throw EventParticipantValidationError.negativeFee
            }
            try EventParticipantPolicy.validate(
                event: event,
                participant: participant,
                guestName: guestName,
                feeCents: feeCents,
                paidCents: paidCents,
                feeScheduleID: selectedFeeScheduleID,
                schedules: allFeeSchedules
            )
            participant.guestName = participant.personID == nil ? guestName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            participant.status = status
            participant.feeCents = feeCents
            participant.paidCents = paidCents
            participant.feeScheduleID = selectedFeeScheduleID
            participant.feeScheduleNameSnapshot = feeSchedules.first { $0.id == selectedFeeScheduleID }?.name ?? ""
            participant.transportation = transportation.trimmingCharacters(in: .whitespacesAndNewlines)
            participant.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let participantName = participant.personID.flatMap { id in people.first { $0.id == id }?.displayName }
                ?? participant.guestName
            AuditLogger.record(
                .edit,
                recordType: "Event Participant",
                recordID: participant.id,
                summary: "Edited \(participantName) on \(event.name) roster",
                details: AuditLogger.details([
                    ("Status", participant.status.rawValue),
                    ("Fee", Money.currency(cents: participant.feeCents)),
                    ("Paid", Money.currency(cents: participant.paidCents)),
                    ("Transportation", participant.transportation),
                ]),
                in: modelContext
            )
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
