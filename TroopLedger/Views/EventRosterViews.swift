import SwiftData
import SwiftUI

struct EventRosterView: View {
    let event: EventRecord
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\PersonRecord.lastName), SortDescriptor(\PersonRecord.firstName)]) private var people: [PersonRecord]
    @Query private var allParticipants: [EventParticipant]
    @Query(sort: \TroopProfileRecord.modifiedAt, order: .reverse) private var troopProfiles: [TroopProfileRecord]
    @State private var showingBuilder = false
    @State private var participantToEdit: EventParticipant?
    @State private var errorMessage: String?

    private var participants: [EventParticipant] {
        let roster = EventRosterSnapshot(event: event, participants: allParticipants.filter { $0.eventID == event.id }, people: people, troopProfile: troopProfiles.first)
        let participantByID = Dictionary(allParticipants.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return roster.rows.compactMap { participantByID[$0.id] }
    }

    private var peopleByID: [UUID: PersonRecord] {
        Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        // The roster snapshot and the role groupings were rebuilt for every header count and section.
        let participants = self.participants
        let scouts = participants.filter { person(for: $0)?.role == .scout }
        let adults = participants.filter { [.leader, .parent].contains(person(for: $0)?.role) }
        let others = participants.filter {
            guard let role = person(for: $0)?.role else { return true }
            return ![.scout, .leader, .parent].contains(role)
        }
        return List {
            Section {
                TroopReportHeader(
                    profile: troopProfiles.first,
                    reportTitle: "Event Roster — \(event.name)",
                    subtitle: eventDateRange
                )
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(eventDateRange).font(.headline)
                    Label(event.classification.rawValue, systemImage: event.classification.systemImage)
                        .font(.subheadline)
                    if !event.mapSearchQuery.isEmpty {
                        Label(event.mapSearchQuery, systemImage: "mappin.and.ellipse")
                    }
                    HStack(spacing: 14) {
                        Label("\(participants.filter { $0.status != .cancelled }.count) attending", systemImage: "person.2")
                        Text("\(scouts.filter { $0.status != .cancelled }.count) Scouts")
                        Text("\(adults.filter { $0.status != .cancelled }.count) adults")
                        if participants.contains(where: { $0.status == .cancelled }) {
                            Text("\(participants.filter { $0.status == .cancelled }.count) cancelled")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if participants.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No one on this roster",
                        systemImage: "person.crop.rectangle.stack",
                        description: Text("Add active troop members, then update their registration or attendance status as plans change.")
                    )
                    if EventMutationPolicy.canEdit(event) {
                        Button("Add People", systemImage: "person.badge.plus") { showingBuilder = true }
                    }
                }
            } else {
                participantSection("Scouts", participants: scouts)
                participantSection("Adults", participants: adults)
                participantSection("Guests and Other", participants: others)
            }
        }
        .pageToolbar(title: "Event Roster") {
            Button("Print Roster", systemImage: "printer") { printRoster() }
                .disabled(participants.isEmpty)
            if EventMutationPolicy.canEdit(event) {
                Button("Add People", systemImage: "person.badge.plus") { showingBuilder = true }
            }
        }
        .sheet(isPresented: $showingBuilder) { EventRosterBuilderView(event: event) }
        .sheet(item: $participantToEdit) { EventParticipantFormView(event: event, participant: $0) }
        .alert("Event Roster", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func participantSection(_ title: String, participants: [EventParticipant]) -> some View {
        if !participants.isEmpty {
            Section("\(title) (\(participants.count))") {
                ForEach(participants) { participant in
                    Button { if EventMutationPolicy.canEdit(event) { participantToEdit = participant } } label: {
                        rosterRow(participant)
                    }
                    .buttonStyle(.plain)
                    .disabled(!EventMutationPolicy.canEdit(event))
                    .deleteDisabled(!EventMutationPolicy.canEdit(event))
                }
                .onDelete { offsets in
                    guard EventMutationPolicy.canEdit(event) else { return }
                    for index in offsets {
                        let participant = participants[index]
                        do {
                            try EventParticipantPolicy.validateDeletion(participant)
                        } catch {
                            errorMessage = error.localizedDescription
                            continue
                        }
                        AuditLogger.record(
                            .delete,
                            recordType: "Event Participant",
                            recordID: participant.id,
                            summary: "Removed \(participantDisplayName(participant)) from \(event.name)",
                            details: AuditLogger.details([
                                ("Status", participant.status.rawValue),
                                ("Fee", Money.currency(cents: participant.feeCents)),
                                ("Paid", Money.currency(cents: participant.paidCents)),
                                ("Notes", participant.notes),
                            ]),
                            in: modelContext
                        )
                        modelContext.delete(participant)
                    }
                    do {
                        try modelContext.save()
                    } catch {
                        errorMessage = "The roster change could not be saved: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func rosterRow(_ participant: EventParticipant) -> some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol(participant.status))
                .foregroundStyle(statusColor(participant.status))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(participantDisplayName(participant))
                    .font(.headline)
                let details = participantDetails(participant)
                if !details.isEmpty {
                    Text(details).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(participant.status.rawValue).font(.subheadline)
                if !participant.transportation.isEmpty {
                    Text(participant.transportation).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }

    private func person(for participant: EventParticipant) -> PersonRecord? {
        participant.personID.flatMap { peopleByID[$0] }
    }

    private func participantDetails(_ participant: EventParticipant) -> String {
        guard let person = person(for: participant) else {
            return ["Guest" as String?, participant.notes.nonempty].compactMap { $0 }.joined(separator: " • ")
        }
        let identity: String
        switch person.role {
        case .scout:
            identity = [person.patrol.nonempty, person.currentRank == .none ? nil : person.currentRank.displayName]
                .compactMap { $0 }.joined(separator: " • ")
        case .leader, .parent, .other:
            identity = person.positionSummary.nonempty ?? person.role.rawValue
        }
        return [identity.nonempty, participant.notes.nonempty].compactMap { $0 }.joined(separator: " • ")
    }

    private func participantDisplayName(_ participant: EventParticipant) -> String {
        person(for: participant)?.displayName
            ?? participant.guestName.nonempty
            ?? "Unnamed guest"
    }

    private func statusSymbol(_ status: ParticipantStatus) -> String {
        switch status {
        case .invited: "envelope"
        case .registered: "checkmark.circle"
        case .waitlisted: "clock"
        case .attended: "checkmark.seal.fill"
        case .cancelled: "xmark.circle"
        case .noShow: "person.crop.circle.badge.xmark"
        }
    }

    private func statusColor(_ status: ParticipantStatus) -> Color {
        switch status {
        case .registered, .attended: .green
        case .waitlisted, .invited: .orange
        case .cancelled, .noShow: .secondary
        }
    }

    private var eventDateRange: String {
        EventRosterSnapshot(event: event, participants: [], people: []).dateRange
    }

    private func printRoster() {
        // A check-in sheet should not list people who cancelled.
        let roster = EventRosterSnapshot(event: event, participants: participants.filter { $0.status != .cancelled }, people: people, troopProfile: troopProfiles.first)
        EventRosterPrinter.printRoster(roster)
    }
}

struct EventRosterBuilderView: View {
    let event: EventRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\PersonRecord.lastName), SortDescriptor(\PersonRecord.firstName)]) private var people: [PersonRecord]
    @Query private var allParticipants: [EventParticipant]
    @State private var selection: Set<UUID> = []
    @State private var searchText = ""
    @State private var activityFilter: PersonActivityFilter = .active
    @State private var roleFilter: PersonRoleFilter = .all
    @State private var guestNames = ""
    @State private var errorMessage: String?

    private var existingPersonIDs: Set<UUID> {
        Set(allParticipants.filter { $0.eventID == event.id }.compactMap(\.personID))
    }

    /// The raw selection can hold people who were added from another device or deleted while this sheet was
    /// open; only people who still exist and are not already on the roster are counted or added.
    private var effectiveSelection: Set<UUID> {
        selection.intersection(Set(people.map(\.id))).subtracting(existingPersonIDs)
    }

    private var availablePeople: [PersonRecord] {
        let existing = existingPersonIDs
        return people.filter { person in
            !existing.contains(person.id)
                && activityFilter.includes(person)
                && roleFilter.includes(person)
                && (searchText.isEmpty
                    || person.displayName.localizedCaseInsensitiveContains(searchText)
                    || person.patrol.localizedCaseInsensitiveContains(searchText)
                    || (person.currentRank != .none && person.currentRank.displayName.localizedCaseInsensitiveContains(searchText))
                    || person.positionSummary.localizedCaseInsensitiveContains(searchText))
        }
    }

    private var visibleIDs: Set<UUID> { Set(availablePeople.map(\.id)) }

    /// Distinct new guest names: the same name typed twice, or a guest already on the roster, is added once.
    private var guestNamesToAdd: [String] {
        let existing = Set(allParticipants.filter { $0.eventID == event.id && $0.personID == nil }.map { $0.guestName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        var seen = existing
        return guestNames
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { name in
                guard !name.isEmpty, !seen.contains(name.lowercased()) else { return false }
                seen.insert(name.lowercased())
                return true
            }
    }

    private var additionCount: Int { effectiveSelection.count + guestNamesToAdd.count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("People status", selection: $activityFilter) {
                        ForEach(PersonActivityFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("People status")

                    HStack {
                        Label("Role", systemImage: "person.2")
                        Spacer()
                        Picker("Role", selection: $roleFilter) {
                            ForEach(PersonRoleFilter.allCases) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .accessibilityLabel("Person role")
                    }
                }

                Section("Non-members") {
                    TextField("Names, one per line", text: $guestNames, axis: .vertical)
                        .lineLimit(3...8)
                    Text("Add guests, visiting Scouts, drivers, or other attendees who are not in the People list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("People") {
                    if availablePeople.isEmpty {
                        Text("No matching people are available to add. Try another status or role filter.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(availablePeople) { person in
                            Button { toggle(person.id) } label: {
                                HStack {
                                    Image(systemName: selection.contains(person.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selection.contains(person.id) ? Color.accentColor : Color.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(person.displayName)
                                        Text(personSummary(person)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

            }
            .searchable(text: $searchText, prompt: "Name, patrol, rank, or position")
            .navigationTitle("Add to Roster")
#if os(iOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Select Shown") {
                        selection.formUnion(visibleIDs)
                    }
                    .disabled(availablePeople.isEmpty)
                    Button("Deselect All") {
                        selection.removeAll()
                    }
                    .disabled(selection.isEmpty)
                    Button("Add \(additionCount)", action: addSelected).disabled(additionCount == 0)
                }
            }
#endif
        }
#if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Deselect All") { selection.removeAll() }
                    .disabled(selection.isEmpty)
                Button("Select Shown") { selection.formUnion(visibleIDs) }
                    .disabled(availablePeople.isEmpty)
                Button("Add \(additionCount)", action: addSelected)
                    .buttonStyle(.fieldbookProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(additionCount == 0)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
        }
#endif
        .frame(minWidth: 480, minHeight: 560)
        .alert("Add to Roster", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func personSummary(_ person: PersonRecord) -> String {
        switch person.role {
        case .scout:
            [person.role.rawValue, person.patrol.nonempty, person.isActive ? nil : "Inactive"]
                .compactMap { $0 }.joined(separator: " • ")
        case .leader, .parent, .other:
            [person.role.rawValue, person.positionSummary.nonempty, person.isActive ? nil : "Inactive"]
                .compactMap { $0 }.joined(separator: " • ")
        }
    }

    private func addSelected() {
        guard EventMutationPolicy.canEdit(event) else { return }
        for id in effectiveSelection {
            let participant = EventParticipant(eventID: event.id, personID: id, status: .registered)
            modelContext.insert(participant)
            let name = people.first { $0.id == id }?.displayName ?? "Unknown person"
            AuditLogger.record(
                .create,
                recordType: "Event Participant",
                recordID: participant.id,
                summary: "Added \(name) to \(event.name)",
                in: modelContext
            )
        }
        for name in guestNamesToAdd {
            let participant = EventParticipant(eventID: event.id, personID: nil, status: .registered)
            participant.guestName = name
            modelContext.insert(participant)
            AuditLogger.record(
                .create,
                recordType: "Event Participant",
                recordID: participant.id,
                summary: "Added guest \(name) to \(event.name)",
                in: modelContext
            )
        }
        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = "The roster could not be saved: \(error.localizedDescription)"
        }
    }
}

private extension String {
    var nonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
