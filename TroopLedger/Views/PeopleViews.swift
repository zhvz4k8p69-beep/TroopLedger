import SwiftUI
import SwiftData

enum PersonActivityFilter: String, CaseIterable, Identifiable {
    case active = "Active"
    case inactive = "Inactive"
    case all = "All"

    var id: String { rawValue }

    func includes(_ person: PersonRecord) -> Bool {
        switch self {
        case .active: person.isActive
        case .inactive: !person.isActive
        case .all: true
        }
    }
}

enum PersonRoleFilter: String, CaseIterable, Identifiable {
    case all = "All Roles"
    case scouts = "Scouts"
    case leaders = "Leaders"
    case parents = "Parents/Guardians"
    case other = "Other"

    var id: String { rawValue }

    var pluralDescription: String {
        switch self {
        case .all: "people"
        case .scouts: "Scouts"
        case .leaders: "leaders"
        case .parents: "parents/guardians"
        case .other: "other people"
        }
    }

    func includes(_ person: PersonRecord) -> Bool {
        switch self {
        case .all: true
        case .scouts: person.role == .scout
        case .leaders: person.role == .leader
        case .parents: person.role == .parent
        case .other: person.role == .other
        }
    }
}

struct PeopleListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\PersonRecord.lastName), SortDescriptor(\PersonRecord.firstName)]) private var people: [PersonRecord]
    @Query private var entries: [MemberLedgerEntry]
    @Query private var transactions: [LedgerTransaction]
    @Query private var depositAllocations: [DepositAllocationRecord]
    @Query private var reimbursements: [ReimbursementRequest]
    @Query private var recurringAllocations: [RecurringChargeAllocationRecord]
    @Query private var registrations: [RegistrationRecord]
    @Query private var participants: [EventParticipant]
    @Query private var closeoutAllocations: [EventCloseoutAllocationRecord]
    @State private var searchText = ""
    @State private var activityFilter: PersonActivityFilter = .active
    @State private var roleFilter: PersonRoleFilter = .all
    @State private var showingNewPerson = false
    @State private var deletionMessage: String?

    private var filtered: [PersonRecord] {
        people.filter { person in
            guard activityFilter.includes(person) else { return false }
            guard roleFilter.includes(person) else { return false }
            guard !searchText.isEmpty else { return true }
            return person.displayName.localizedCaseInsensitiveContains(searchText)
                || person.patrol.localizedCaseInsensitiveContains(searchText)
                || person.currentRank.displayName.localizedCaseInsensitiveContains(searchText)
                || person.positionSummary.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
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

            if filtered.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: searchText.isEmpty ? "person.slash" : "magnifyingglass")
                } description: {
                    Text(emptyMessage)
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(filtered) { person in
                    NavigationLink(value: person) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(person.displayName).font(.headline)
                                Text([
                                    person.role.rawValue,
                                    person.role == .scout && person.currentRank != .none ? person.currentRank.displayName : nil,
                                    person.patrol.isEmpty ? nil : person.patrol,
                                    person.isActive ? nil : "Inactive"
                                ].compactMap { $0 }.joined(separator: " • "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !person.positionSummary.isEmpty {
                                    Text(person.positionSummary)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            MoneyText(cents: FinanceEngine.memberBalance(personID: person.id, entries: entries), colorBySign: true)
                        }
                    }
                }
                .onDelete(perform: deletePeople)
            }
        }
        .searchable(text: $searchText, prompt: "Name, patrol, rank, or position")
        .navigationDestination(for: PersonRecord.self) { PersonDetailView(person: $0) }
        .pageToolbar(title: "People") {
            Button("Add Person", systemImage: "plus") { showingNewPerson = true }
        }
        .sheet(isPresented: $showingNewPerson) { PersonFormView() }
        .alert("People", isPresented: Binding(
            get: { deletionMessage != nil },
            set: { if !$0 { deletionMessage = nil } }
        )) {
            Button("OK") { deletionMessage = nil }
        } message: {
            Text(deletionMessage ?? "")
        }
    }

    private var emptyTitle: String {
        if !searchText.isEmpty { return "No matches" }
        return switch activityFilter {
        case .active: "No active \(roleFilter.pluralDescription)"
        case .inactive: "No inactive \(roleFilter.pluralDescription)"
        case .all: "No \(roleFilter.pluralDescription)"
        }
    }

    private var emptyMessage: String {
        if !searchText.isEmpty { return "Try a different name, patrol, rank, or position." }
        if people.isEmpty { return "Add Scouts, leaders, and guardians. Registration history and member balances stay with each person." }
        return "Change the status or role filter to see other people."
    }

    private func deletePeople(at offsets: IndexSet) {
        for index in offsets {
            let person = filtered[index]
            guard RecordDeletionPolicy.canDeletePerson(
                person.id,
                transactions: transactions,
                depositAllocations: depositAllocations,
                reimbursements: reimbursements,
                recurringAllocations: recurringAllocations,
                memberEntries: entries,
                registrations: registrations,
                participants: participants,
                closeoutAllocations: closeoutAllocations
            ) else {
                deletionMessage = "This person is referenced by financial, registration, reimbursement, or event records and cannot be deleted. Mark the person inactive instead."
                continue
            }
            AuditLogger.record(
                .delete,
                recordType: "Person",
                recordID: person.id,
                summary: "Deleted person \(person.displayName)",
                details: AuditLogger.details([
                    ("Role", person.role.rawValue),
                    ("Scouting Member ID", person.scoutingMemberID),
                ]),
                in: modelContext
            )
            modelContext.delete(person)
        }
    }
}

struct PersonDetailView: View {
    let person: PersonRecord
    @Query(sort: \MemberLedgerEntry.date, order: .reverse) private var allEntries: [MemberLedgerEntry]
    @Query(sort: \RegistrationRecord.registeredOn, order: .reverse) private var allRegistrations: [RegistrationRecord]
    @Query private var events: [EventRecord]
    @State private var showingEdit = false
    @State private var showingEntry = false
    @State private var showingRegistration = false

    private var entries: [MemberLedgerEntry] { allEntries.filter { $0.personID == person.id } }
    private var registrations: [RegistrationRecord] { allRegistrations.filter { $0.personID == person.id } }

    var body: some View {
        List {
            Section {
                LabeledContent("Role", value: person.role.rawValue)
                if person.role == .scout {
                    LabeledContent("Current rank", value: person.currentRank.displayName)
                }
                if !person.positionSummary.isEmpty {
                    LabeledContent("Current positions") {
                        Text(person.positionSummary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if !person.patrol.isEmpty { LabeledContent("Patrol", value: person.patrol) }
                if !person.scoutingMemberID.isEmpty { LabeledContent("Scouting Member ID", value: person.scoutingMemberID) }
                LabeledContent("Member balance") { MoneyText(cents: FinanceEngine.memberBalance(personID: person.id, entries: entries), colorBySign: true) }
            }

            Section("Registration") {
                if registrations.isEmpty {
                    Text("No registration records").foregroundStyle(.secondary)
                } else {
                    ForEach(registrations) { registration in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(registration.programYear).font(.headline); Spacer(); Text(registration.status.rawValue).foregroundStyle(.secondary) }
                            Text([registration.unitRole, Money.currency(cents: registration.duesAssessedCents)].filter { !$0.isEmpty }.joined(separator: " • "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Add Registration", systemImage: "person.badge.plus") { showingRegistration = true }
            }

            Section("Member Ledger") {
                if entries.isEmpty {
                    Text("No charges or payments").foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.category).font(.headline)
                                Text("\(entry.kind.rawValue) • \(entry.date.formatted(date: .abbreviated, time: .omitted))\(eventName(entry.eventID).map { " • \($0)" } ?? "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            MoneyText(cents: entry.balanceEffectCents, colorBySign: true)
                        }
                    }
                }
                Button("Add Charge or Payment", systemImage: "plus.circle") { showingEntry = true }
            }
        }
        .pageToolbar(title: person.displayName) {
            Button("Edit Person", systemImage: "pencil") { showingEdit = true }
        }
        .sheet(isPresented: $showingEdit) { PersonFormView(person: person) }
        .sheet(isPresented: $showingEntry) { MemberEntryFormView(person: person) }
        .sheet(isPresented: $showingRegistration) { RegistrationFormView(person: person) }
    }

    private func eventName(_ id: UUID?) -> String? { events.first(where: { $0.id == id })?.name }
}

struct PersonFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    private let person: PersonRecord?
    @State private var firstName: String
    @State private var lastName: String
    @State private var role: PersonRole
    @State private var currentRank: ScoutsBSARank
    @State private var selectedPositions: Set<TroopPosition>
    @State private var customPosition: String
    @State private var patrol: String
    @State private var memberID: String
    @State private var email: String
    @State private var phone: String
    @State private var isActive: Bool
    @State private var notes: String
    @State private var showingPositions = false

    init(person: PersonRecord? = nil) {
        self.person = person
        _firstName = State(initialValue: person?.firstName ?? "")
        _lastName = State(initialValue: person?.lastName ?? "")
        _role = State(initialValue: person?.role ?? .scout)
        _currentRank = State(initialValue: person?.currentRank ?? .none)
        _selectedPositions = State(initialValue: Set(person?.troopPositions ?? []))
        _customPosition = State(initialValue: person?.customPosition ?? "")
        _patrol = State(initialValue: person?.patrol ?? "")
        _memberID = State(initialValue: person?.scoutingMemberID ?? "")
        _email = State(initialValue: person?.email ?? "")
        _phone = State(initialValue: person?.phone ?? "")
        _isActive = State(initialValue: person?.isActive ?? true)
        _notes = State(initialValue: person?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Person") {
                    TextField("First name", text: $firstName)
                    TextField("Last name", text: $lastName)
                    Picker("Person type", selection: $role) { ForEach(PersonRole.allCases) { Text($0.rawValue).tag($0) } }
                    TextField("Patrol", text: $patrol)
                    Toggle("Active", isOn: $isActive)
                }
                Section("Rank and troop positions") {
                    if role == .scout {
                        Picker("Current rank", selection: $currentRank) {
                            ForEach(ScoutsBSARank.allCases) { rank in
                                Text(rank.displayName).tag(rank)
                            }
                        }
                    }

                    Button {
                        showingPositions = true
                    } label: {
                        HStack {
                            Text("Current positions")
                            Spacer()
                            Text(selectedPositions.isEmpty ? "None" : "\(selectedPositions.count) selected")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    if !selectedPositionSummary.isEmpty {
                        Text(selectedPositionSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextField("Other or troop-specific position", text: $customPosition, axis: .vertical)
                }
                Section("Registration identity") { TextField("Scouting Member ID", text: $memberID) }
                Section("Contact") {
                    TextField("Email", text: $email)
                    TextField("Phone", text: $phone)
                }
                Section("Notes") { TextField("Optional notes", text: $notes, axis: .vertical) }
            }
            .formStyle(.grouped)
            .navigationTitle(person == nil ? "New Person" : "Edit Person")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(firstName.trimmingCharacters(in: .whitespaces).isEmpty && lastName.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
        }
        .frame(minWidth: 450, minHeight: 560)
        .sheet(isPresented: $showingPositions) {
            TroopPositionSelectionView(
                selectedPositions: $selectedPositions,
                preferredCategory: role == .scout ? .youth : .adult
            )
        }
    }

    private var selectedPositionSummary: String {
        selectedPositions
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map(\.displayName)
            .joined(separator: ", ")
    }

    private func save() {
        let record = person ?? PersonRecord(firstName: firstName, lastName: lastName, role: role)
        record.firstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        record.lastName = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        record.role = role
        record.currentRank = currentRank
        record.troopPositions = Array(selectedPositions)
        record.customPosition = customPosition.trimmingCharacters(in: .whitespacesAndNewlines)
        record.patrol = patrol
        record.scoutingMemberID = memberID
        record.email = email
        record.phone = phone
        record.isActive = isActive
        record.notes = notes
        let isNew = person == nil
        if isNew { modelContext.insert(record) }
        AuditLogger.record(
            isNew ? .create : .edit,
            recordType: "Person",
            recordID: record.id,
            summary: "\(isNew ? "Created" : "Edited") person \(record.displayName)",
            details: AuditLogger.details([
                ("Role", record.role.rawValue),
                ("Rank", record.role == .scout ? record.currentRank.displayName : nil),
                ("Positions", record.positionSummary),
                ("Patrol", record.patrol),
                ("Active", record.isActive ? "Yes" : "No"),
            ]),
            in: modelContext
        )
        dismiss()
    }
}

struct TroopPositionSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedPositions: Set<TroopPosition>
    let preferredCategory: TroopPositionCategory

    private var orderedCategories: [TroopPositionCategory] {
        preferredCategory == .youth ? [.youth, .adult] : [.adult, .youth]
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(orderedCategories) { category in
                    Section(category.rawValue) {
                        ForEach(TroopPosition.allCases.filter { $0.category == category }) { position in
                            Button {
                                toggle(position)
                            } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(position.displayName)
                                            .foregroundStyle(.primary)
                                        if position.category == .youth && !position.fulfillsYouthPositionOfResponsibility {
                                            Text("Does not fulfill the Star, Life, or Eagle position-of-responsibility requirement")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if selectedPositions.contains(position) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(position.displayName)
                            .accessibilityValue(selectedPositions.contains(position) ? "Selected" : "Not selected")
                        }
                    }
                }
            }
            .navigationTitle("Current Positions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { selectedPositions.removeAll() }
                        .disabled(selectedPositions.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 600)
    }

    private func toggle(_ position: TroopPosition) {
        if selectedPositions.contains(position) {
            selectedPositions.remove(position)
        } else {
            selectedPositions.insert(position)
        }
    }
}

struct MemberEntryFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let person: PersonRecord
    @Query(sort: \EventRecord.startDate, order: .reverse) private var events: [EventRecord]
    @State private var date = Date()
    @State private var kind = MemberEntryKind.charge
    @State private var amount = "0.00"
    @State private var category = "Dues"
    @State private var eventID: UUID?
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Entry") {
                    LabeledContent("Person", value: person.displayName)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Type", selection: $kind) { ForEach(MemberEntryKind.allCases) { Text($0.rawValue).tag($0) } }
                    AmountField(title: "Amount", text: $amount)
                    TextField("Category", text: $category)
                    Picker("Event", selection: $eventID) {
                        Text("None").tag(nil as UUID?)
                        ForEach(events) { Text($0.name).tag($0.id as UUID?) }
                    }
                }
                Section("Notes") { TextField("Optional notes", text: $notes, axis: .vertical) }
            }
            .formStyle(.grouped)
            .navigationTitle("Member Ledger Entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
        }
        .frame(minWidth: 450, minHeight: 480)
    }

    private var canSave: Bool { Money.cents(from: amount).map { $0 > 0 } == true && !category.trimmingCharacters(in: .whitespaces).isEmpty }

    private func save() {
        guard let cents = Money.cents(from: amount), cents > 0 else { return }
        let record = MemberLedgerEntry(personID: person.id, date: date, kind: kind, amountCents: cents, category: category.trimmingCharacters(in: .whitespacesAndNewlines))
        record.eventID = eventID
        record.notes = notes
        modelContext.insert(record)
        AuditLogger.record(
            .create,
            recordType: "Member Ledger Entry",
            recordID: record.id,
            summary: "Added \(record.kind.rawValue.lowercased()) for \(person.displayName)",
            details: AuditLogger.details([
                ("Date", record.date.formatted(date: .numeric, time: .omitted)),
                ("Amount", Money.currency(cents: record.amountCents)),
                ("Category", record.category),
                ("Event ID", record.eventID?.uuidString),
            ]),
            in: modelContext
        )
        dismiss()
    }
}

struct RegistrationFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let person: PersonRecord
    @Query private var registrations: [RegistrationRecord]
    @State private var programYear = String(Calendar.current.component(.year, from: Date()))
    @State private var unitRole = ""
    @State private var status = RegistrationStatus.current
    @State private var registeredOn = Date()
    @State private var hasExpiration = false
    @State private var expiresOn = Date()
    @State private var dues = "0.00"
    @State private var notes = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Registration") {
                    LabeledContent("Person", value: person.displayName)
                    TextField("Program year", text: $programYear)
                    TextField("Unit role", text: $unitRole)
                    Picker("Status", selection: $status) { ForEach(RegistrationStatus.allCases) { Text($0.rawValue).tag($0) } }
                    DatePicker("Registered", selection: $registeredOn, displayedComponents: .date)
                    Toggle("Has expiration date", isOn: $hasExpiration)
                    if hasExpiration { DatePicker("Expires", selection: $expiresOn, displayedComponents: .date) }
                    AmountField(title: "Dues assessed", text: $dues)
                }
                Section("Notes") { TextField("Optional notes", text: $notes, axis: .vertical) }
            }
            .formStyle(.grouped)
            .navigationTitle("New Registration")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
        }
        .frame(minWidth: 450, minHeight: 520)
        .alert("Registration", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var canSave: Bool {
        guard let cents = Money.cents(from: dues) else { return false }
        return (try? RegistrationPolicy.validate(
            personID: person.id,
            programYear: programYear,
            registeredOn: registeredOn,
            expiresOn: hasExpiration ? expiresOn : nil,
            duesAssessedCents: cents,
            registrations: registrations
        )) != nil
    }

    private func save() {
        do {
            guard let cents = Money.cents(from: dues) else { throw RegistrationValidationError.negativeDues }
            let expiration = hasExpiration ? expiresOn : nil
            try RegistrationPolicy.validate(
                personID: person.id,
                programYear: programYear,
                registeredOn: registeredOn,
                expiresOn: expiration,
                duesAssessedCents: cents,
                registrations: registrations
            )
            let record = RegistrationRecord(
                personID: person.id,
                programYear: programYear.trimmingCharacters(in: .whitespacesAndNewlines),
                unitRole: unitRole.trimmingCharacters(in: .whitespacesAndNewlines),
                status: status
            )
            record.registeredOn = registeredOn
            record.expiresOn = expiration
            record.duesAssessedCents = cents
            record.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            modelContext.insert(record)
            AuditLogger.record(
                .create,
                recordType: "Registration",
                recordID: record.id,
                summary: "Added \(record.programYear) registration for \(person.displayName)",
                details: AuditLogger.details([
                    ("Unit role", record.unitRole),
                    ("Status", record.status.rawValue),
                    ("Registered", record.registeredOn.formatted(date: .numeric, time: .omitted)),
                    ("Dues assessed", Money.currency(cents: record.duesAssessedCents)),
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
