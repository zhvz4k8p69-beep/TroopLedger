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
    @State private var pendingDeletion: PersonRecord?

    private var filtered: [PersonRecord] {
        people.filter { person in
            guard activityFilter.includes(person) else { return false }
            guard roleFilter.includes(person) else { return false }
            guard !searchText.isEmpty else { return true }
            return person.displayName.localizedCaseInsensitiveContains(searchText)
                || person.patrol.localizedCaseInsensitiveContains(searchText)
                || (person.currentRank != .none && person.currentRank.displayName.localizedCaseInsensitiveContains(searchText))
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

            if activityFilter == .active, inactiveBalances.count > 0 {
                Section {
                    Button {
                        activityFilter = .inactive
                    } label: {
                        Label(
                            "\(inactiveBalances.count) inactive \(inactiveBalances.count == 1 ? "person" : "people") still carry balances totaling \(Money.currency(cents: inactiveBalances.total))",
                            systemImage: "exclamationmark.circle"
                        )
                        .foregroundStyle(.orange)
                    }
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
        .confirmationDialog(
            "Delete this person?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { person in
            Button("Delete \(person.displayName)", role: .destructive) { deletePerson(person) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { person in
            Text("\(person.displayName) has no financial, registration, or event records and will be removed permanently. Mark people inactive instead when their history should be kept.")
        }
        .alert("People", isPresented: Binding(
            get: { deletionMessage != nil },
            set: { if !$0 { deletionMessage = nil } }
        )) {
            Button("OK") { deletionMessage = nil }
        } message: {
            Text(deletionMessage ?? "")
        }
    }

    /// The default Active filter hid money still owed by or to families who left.
    private var inactiveBalances: (count: Int, total: Int64) {
        let balances = people.filter { !$0.isActive }
            .map { FinanceEngine.memberBalance(personID: $0.id, entries: entries) }
            .filter { $0 != 0 }
        return (balances.count, balances.reduce(0, +))
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
        guard let index = offsets.first else { return }
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
            return
        }
        pendingDeletion = person
    }

    private func deletePerson(_ person: PersonRecord) {
        do {
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
            pendingDeletion = nil
            try modelContext.save()
        } catch {
            deletionMessage = "The person could not be deleted: \(error.localizedDescription)"
        }
    }
}

struct PersonDetailView: View {
    let person: PersonRecord
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MemberLedgerEntry.date, order: .reverse) private var allEntries: [MemberLedgerEntry]
    @Query(sort: \RegistrationRecord.registeredOn, order: .reverse) private var allRegistrations: [RegistrationRecord]
    @Query private var events: [EventRecord]
    @Query private var chargeAllocations: [RecurringChargeAllocationRecord]
    @State private var showingEdit = false
    @State private var showingEntry = false
    @State private var showingRegistration = false
    @State private var editingRegistration: RegistrationRecord?
    @State private var pendingRegistrationDeletion: RegistrationRecord?
    @State private var errorMessage: String?

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
                        Button { editingRegistration = registration } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(registration.programYear).font(.headline); Spacer(); Text(registration.status.rawValue).foregroundStyle(.secondary) }
                                Text([registration.unitRole, Money.currency(cents: registration.duesAssessedCents)].filter { !$0.isEmpty }.joined(separator: " • "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: requestRegistrationDeletion)
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
                                if entry.kind == .payment {
                                    Label(
                                        entry.accountTransactionID == nil ? "No bank receipt linked" : "Bank receipt linked",
                                        systemImage: entry.accountTransactionID == nil ? "exclamationmark.circle" : "link"
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(entry.accountTransactionID == nil ? Color.orange : Color.secondary)
                                }
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
        .sheet(item: $editingRegistration) { RegistrationFormView(person: person, registration: $0) }
        .confirmationDialog(
            "Delete this registration?",
            isPresented: Binding(get: { pendingRegistrationDeletion != nil }, set: { if !$0 { pendingRegistrationDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingRegistrationDeletion
        ) { registration in
            Button("Delete \(registration.programYear) registration", role: .destructive) { deleteRegistration(registration) }
            Button("Cancel", role: .cancel) { pendingRegistrationDeletion = nil }
        } message: { registration in
            Text("The \(registration.programYear) registration for \(person.displayName) will be removed permanently.")
        }
        .alert("Registration", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func eventName(_ id: UUID?) -> String? { events.first(where: { $0.id == id })?.name }

    private func requestRegistrationDeletion(at offsets: IndexSet) {
        guard let index = offsets.first else { return }
        let registration = registrations[index]
        guard RegistrationPolicy.canDelete(registration, allocations: chargeAllocations) else {
            errorMessage = "A posted charge batch used this registration's assessed dues. It is part of that batch's history and cannot be deleted."
            return
        }
        pendingRegistrationDeletion = registration
    }

    private func deleteRegistration(_ registration: RegistrationRecord) {
        AuditLogger.record(
            .delete,
            recordType: "Registration",
            recordID: registration.id,
            summary: "Deleted \(registration.programYear) registration for \(person.displayName)",
            details: AuditLogger.details([
                ("Unit role", registration.unitRole),
                ("Status", registration.status.rawValue),
                ("Dues assessed", Money.currency(cents: registration.duesAssessedCents)),
            ]),
            in: modelContext
        )
        modelContext.delete(registration)
        pendingRegistrationDeletion = nil
        do {
            try modelContext.save()
        } catch {
            errorMessage = "The registration could not be deleted: \(error.localizedDescription)"
        }
    }
}

struct PersonFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var people: [PersonRecord]
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
    @State private var errorMessage: String?

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
        .alert("Person", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func snapshot(_ record: PersonRecord) -> [(String, String)] {
        [
            ("Name", record.displayName),
            ("Role", record.role.rawValue),
            ("Rank", record.currentRank.displayName),
            ("Positions", record.positionSummary),
            ("Patrol", record.patrol),
            ("Scouting Member ID", record.scoutingMemberID),
            ("Email", record.email),
            ("Phone", record.phone),
            ("Active", record.isActive ? "Yes" : "No"),
            ("Notes", record.notes),
        ]
    }

    private var selectedPositionSummary: String {
        selectedPositions
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map(\.displayName)
            .joined(separator: ", ")
    }

    private func save() {
        do {
            try PersonPolicy.validate(firstName: firstName, lastName: lastName, memberID: memberID, editingPersonID: person?.id, people: people)
            let record = person ?? PersonRecord(firstName: firstName, lastName: lastName, role: role)
            let before = person.map(snapshot)
            // Identity and contact fields are matched exactly by the Scoutbook importer, so stray whitespace
            // here would create duplicate people on the next import.
            record.firstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
            record.lastName = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
            record.role = role
            record.currentRank = currentRank
            record.troopPositions = Array(selectedPositions)
            record.customPosition = customPosition.trimmingCharacters(in: .whitespacesAndNewlines)
            record.patrol = patrol.trimmingCharacters(in: .whitespacesAndNewlines)
            record.scoutingMemberID = memberID.trimmingCharacters(in: .whitespacesAndNewlines)
            record.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
            record.phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
            record.isActive = isActive
            record.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
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
    @Query(sort: \LedgerTransaction.date, order: .reverse) private var transactions: [LedgerTransaction]
    @Query private var allEntries: [MemberLedgerEntry]
    @State private var linkedTransactionID: UUID?
    @State private var date = Date()
    @State private var kind = MemberEntryKind.charge
    @State private var amount = "0.00"
    @State private var category = "Dues"
    @State private var eventID: UUID?
    @State private var notes = ""
    @State private var errorMessage: String?

    private var isAdjustment: Bool { kind == .adjustmentIncrease || kind == .adjustmentDecrease }

    /// Income received from this person in the bank ledger that no other member-ledger payment claims yet.
    private var receiptCandidates: [LedgerTransaction] {
        let claimed = Set(allEntries.compactMap(\.accountTransactionID))
        return transactions.filter {
            $0.direction == .income && !$0.isTransfer && $0.personID == person.id && !claimed.contains($0.id)
        }
    }

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
                if kind == .payment {
                    Section("Bank Receipt") {
                        Picker("Received in", selection: $linkedTransactionID) {
                            Text("Not linked").tag(nil as UUID?)
                            ForEach(receiptCandidates) { transaction in
                                Text("\(transaction.date.formatted(date: .abbreviated, time: .omitted)) • \(transaction.category) • \(Money.currency(cents: transaction.amountCents))")
                                    .tag(transaction.id as UUID?)
                            }
                        }
                        Text(receiptCandidates.isEmpty
                            ? "No unlinked income from \(person.displayName) is recorded in the register yet. Record the deposit or Undeposited Funds receipt with this person linked, then attach it here so every payment traces to cash that actually arrived."
                            : "Linking the register entry shows that the money behind this payment reached the troop's accounts.")
                            .font(.footnote)
                            .foregroundStyle(linkedTransactionID == nil ? .orange : .secondary)
                    }
                }
                Section(isAdjustment ? "Reason for Adjustment" : "Notes") {
                    TextField(isAdjustment ? "Required explanation" : "Optional notes", text: $notes, axis: .vertical)
                    if isAdjustment {
                        Text("Balance adjustments change what a family owes without a charge or payment behind them, so the reason is recorded with the entry.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Member Ledger Entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
        }
        .frame(minWidth: 450, minHeight: 480)
        .alert("Member Ledger Entry", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private var canSave: Bool {
        (try? MemberEntryPolicy.validate(kind: kind, amountCents: Money.cents(from: amount), category: category, notes: notes)) != nil
    }

    private func save() {
        do {
            let cents = Money.cents(from: amount)
            try MemberEntryPolicy.validate(kind: kind, amountCents: cents, category: category, notes: notes)
            guard let cents else { throw MemberEntryValidationError.invalidAmount }
            let record = MemberLedgerEntry(personID: person.id, date: date, kind: kind, amountCents: cents, category: category.trimmingCharacters(in: .whitespacesAndNewlines))
            record.eventID = eventID
            record.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            record.accountTransactionID = kind == .payment ? linkedTransactionID : nil
            modelContext.insert(record)
            AuditLogger.record(
                .create,
                recordType: "Member Ledger Entry",
                recordID: record.id,
                summary: "Added \(record.kind.rawValue.lowercased()) for \(person.displayName)",
                details: AuditLogger.details([
                    ("Person ID", person.id.uuidString),
                    ("Date", record.date.formatted(date: .numeric, time: .omitted)),
                    ("Amount", Money.currency(cents: record.amountCents)),
                    ("Category", record.category),
                    ("Event ID", record.eventID?.uuidString),
                    ("Linked bank transaction ID", record.accountTransactionID?.uuidString),
                    (isAdjustment ? "Adjustment reason" : "Notes", record.notes),
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

struct RegistrationFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let person: PersonRecord
    private let registration: RegistrationRecord?
    @Query private var registrations: [RegistrationRecord]
    @State private var programYear: String
    @State private var unitRole: String
    @State private var status: RegistrationStatus
    @State private var registeredOn: Date
    @State private var hasExpiration: Bool
    @State private var expiresOn: Date
    @State private var dues: String
    @State private var notes: String
    @State private var errorMessage: String?

    init(person: PersonRecord, registration: RegistrationRecord? = nil) {
        self.person = person
        self.registration = registration
        _programYear = State(initialValue: registration?.programYear ?? String(Calendar.current.component(.year, from: Date())))
        _unitRole = State(initialValue: registration?.unitRole ?? "")
        _status = State(initialValue: registration?.status ?? .current)
        _registeredOn = State(initialValue: registration?.registeredOn ?? Date())
        _hasExpiration = State(initialValue: registration?.expiresOn != nil)
        _expiresOn = State(initialValue: registration?.expiresOn ?? Date())
        _dues = State(initialValue: Money.editableString(cents: registration?.duesAssessedCents ?? 0))
        _notes = State(initialValue: registration?.notes ?? "")
    }

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
            .navigationTitle(registration == nil ? "New Registration" : "Edit Registration")
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
            registrations: registrations,
            excluding: registration?.id
        )) != nil
    }

    private func snapshot(_ record: RegistrationRecord) -> [(String, String)] {
        [
            ("Program year", record.programYear),
            ("Unit role", record.unitRole),
            ("Status", record.status.rawValue),
            ("Registered", record.registeredOn.formatted(date: .numeric, time: .omitted)),
            ("Expires", record.expiresOn?.formatted(date: .numeric, time: .omitted) ?? ""),
            ("Dues assessed", Money.currency(cents: record.duesAssessedCents)),
            ("Notes", record.notes),
        ]
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
                registrations: registrations,
                excluding: registration?.id
            )
            let isNew = registration == nil
            let before = registration.map(snapshot)
            let record = registration ?? RegistrationRecord(
                personID: person.id,
                programYear: programYear.trimmingCharacters(in: .whitespacesAndNewlines),
                unitRole: unitRole.trimmingCharacters(in: .whitespacesAndNewlines),
                status: status
            )
            record.programYear = programYear.trimmingCharacters(in: .whitespacesAndNewlines)
            record.unitRole = unitRole.trimmingCharacters(in: .whitespacesAndNewlines)
            record.status = status
            record.registeredOn = registeredOn
            record.expiresOn = expiration
            record.duesAssessedCents = cents
            record.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if isNew { modelContext.insert(record) }
            AuditLogger.record(
                isNew ? .create : .edit,
                recordType: "Registration",
                recordID: record.id,
                summary: "\(isNew ? "Added" : "Edited") \(record.programYear) registration for \(person.displayName)",
                details: AuditLogger.details([
                    ("Unit role", record.unitRole),
                    ("Status", record.status.rawValue),
                    ("Registered", record.registeredOn.formatted(date: .numeric, time: .omitted)),
                    ("Dues assessed", Money.currency(cents: record.duesAssessedCents)),
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
