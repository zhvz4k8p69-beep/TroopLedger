import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct FamilyStatementListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FamilyRecord.name) private var families: [FamilyRecord]
    @Query(sort: [SortDescriptor(\PersonRecord.lastName), SortDescriptor(\PersonRecord.firstName)]) private var people: [PersonRecord]
    @Query private var entries: [MemberLedgerEntry]
    @State private var showingNewFamily = false
    @State private var editingFamily: FamilyRecord?
    @State private var pendingDeletion: FamilyRecord?
    @State private var errorMessage: String?

    private var unassignedPeople: [PersonRecord] { people.filter { $0.familyID == nil } }

    var body: some View {
        List {
            if families.isEmpty {
                ContentUnavailableView {
                    Label("No families yet", systemImage: "house")
                } description: {
                    Text("Create a family and assign existing people to produce a combined statement without duplicating their ledger records.")
                } actions: {
                    Button("Create Family") { showingNewFamily = true }
                }
                .listRowBackground(Color.clear)
            } else {
                Section("Families") {
                    ForEach(families) { family in
                        NavigationLink {
                            FamilyStatementDetailView(family: family)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(family.name).font(.headline)
                                    Text(memberSummary(for: family))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                MoneyText(cents: balance(for: family), colorBySign: true)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Edit", systemImage: "pencil") { editingFamily = family }
                                .tint(.blue)
                        }
                    }
                    .onDelete(perform: deleteFamilies)
                }
            }

            Section("Assignment") {
                LabeledContent("People not assigned to a family", value: String(unassignedPeople.count))
                if !unassignedPeople.isEmpty {
                    Text(unassignedPeople.map(\.displayName).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("A person can belong to one family. Family statements read each person’s existing member ledger; they do not create or copy balances.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .pageToolbar(title: "Family Statements") {
            Button("Add Family", systemImage: "plus") { showingNewFamily = true }
        }
        .sheet(isPresented: $showingNewFamily) {
            FamilyEditorView(initialMemberIDs: [])
        }
        .sheet(item: $editingFamily) { family in
            FamilyEditorView(
                family: family,
                initialMemberIDs: Set(people.filter { $0.familyID == family.id }.map(\.id))
            )
        }
        .confirmationDialog(
            "Delete this family?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { family in
            Button("Delete \(family.name)", role: .destructive) { deleteFamily(family) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { family in
            Text("\(members(for: family).count) assigned people will be unassigned. Their ledger records are not affected.")
        }
        .alert("Families", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func members(for family: FamilyRecord) -> [PersonRecord] {
        people.filter { $0.familyID == family.id }
    }

    private func memberSummary(for family: FamilyRecord) -> String {
        let names = members(for: family).map(\.displayName)
        return names.isEmpty ? "No members assigned" : names.joined(separator: ", ")
    }

    private func balance(for family: FamilyRecord) -> Int64 {
        let ids = Set(members(for: family).map(\.id))
        return entries.filter { $0.personID.map(ids.contains) ?? false }.reduce(0) { $0 + $1.balanceEffectCents }
    }

    private func deleteFamilies(at offsets: IndexSet) {
        guard let index = offsets.first else { return }
        pendingDeletion = families[index]
    }

    private func deleteFamily(_ family: FamilyRecord) {
        let assigned = members(for: family)
        assigned.forEach { $0.familyID = nil }
        AuditLogger.record(
            .delete,
            recordType: "Family",
            recordID: family.id,
            summary: "Deleted family \(family.name)",
            details: AuditLogger.details([("Members unassigned", String(assigned.count))]),
            in: modelContext
        )
        modelContext.delete(family)
        pendingDeletion = nil
        do {
            try modelContext.save()
        } catch {
            errorMessage = "The family could not be deleted: \(error.localizedDescription)"
        }
    }
}

struct FamilyEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\PersonRecord.lastName), SortDescriptor(\PersonRecord.firstName)]) private var people: [PersonRecord]
    private let family: FamilyRecord?
    @State private var name: String
    @State private var notes: String
    @State private var selectedMemberIDs: Set<UUID>
    @State private var errorMessage: String?

    init(family: FamilyRecord? = nil, initialMemberIDs: Set<UUID>) {
        self.family = family
        _name = State(initialValue: family?.name ?? "")
        _notes = State(initialValue: family?.notes ?? "")
        _selectedMemberIDs = State(initialValue: initialMemberIDs)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Family") {
                    TextField("Family name", text: $name)
                    TextField("Private notes", text: $notes, axis: .vertical)
                }
                Section("Members") {
                    if people.isEmpty {
                        Text("Add people before assigning family members.").foregroundStyle(.secondary)
                    } else {
                        ForEach(people) { person in
                            Button {
                                toggle(person.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(person.displayName).foregroundStyle(.primary)
                                        Text(assignmentNote(for: person))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedMemberIDs.contains(person.id) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("Selecting someone already assigned elsewhere will move that person to this family when you save.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(family == nil ? "New Family" : "Edit Family")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 560)
        .alert("Family", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func toggle(_ id: UUID) {
        if selectedMemberIDs.contains(id) { selectedMemberIDs.remove(id) } else { selectedMemberIDs.insert(id) }
    }

    private func assignmentNote(for person: PersonRecord) -> String {
        guard let id = person.familyID else { return person.role.rawValue }
        if id == family?.id { return "\(person.role.rawValue) - in this family" }
        return "\(person.role.rawValue) - currently in another family"
    }

    private func save() {
        let record = family ?? FamilyRecord(name: name)
        let isNew = family == nil
        record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        record.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        record.modifiedAt = Date()
        if isNew { modelContext.insert(record) }

        let previousIDs = Set(people.filter { $0.familyID == record.id }.map(\.id))
        for person in people {
            if selectedMemberIDs.contains(person.id) {
                person.familyID = record.id
            } else if person.familyID == record.id {
                person.familyID = nil
            }
        }
        AuditLogger.record(
            isNew ? .create : .edit,
            recordType: "Family",
            recordID: record.id,
            summary: "\(isNew ? "Created" : "Edited") family \(record.name)",
            details: AuditLogger.details([
                ("Members", selectedMemberIDs.count.description),
                ("Added", selectedMemberIDs.subtracting(previousIDs).count.description),
                ("Removed", previousIDs.subtracting(selectedMemberIDs).count.description),
            ]),
            in: modelContext
        )
        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = "The family could not be saved: \(error.localizedDescription)"
        }
    }
}

struct FamilyStatementDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var people: [PersonRecord]
    @Query private var entries: [MemberLedgerEntry]
    @Query private var events: [EventRecord]
    @Query(sort: \TroopProfileRecord.modifiedAt, order: .reverse) private var troopProfiles: [TroopProfileRecord]
    let family: FamilyRecord
    @State private var periodStart = ReportingPeriod.containing(Date()).startDate
    @State private var asOfDate = Date()
    @State private var document: FamilyStatementPDFDocument?
    @State private var filename = "Family-Statement.pdf"
    @State private var showingExporter = false
    @State private var message: String?
    @State private var errorMessage: String?

    private var snapshot: FamilyStatementSnapshot? {
        try? FamilyStatementService.makeSnapshot(
            family: family,
            people: people,
            entries: entries,
            events: events,
            periodStart: periodStart,
            asOfDate: asOfDate,
            troopProfile: troopProfiles.first
        )
    }

    var body: some View {
        List {
            Section {
                TroopReportHeader(
                    profile: troopProfiles.first,
                    reportTitle: "Family Statement — \(family.name)",
                    subtitle: "Private family financial information"
                )
            }

            Section("Statement Dates") {
                DatePicker("Activity beginning", selection: $periodStart, displayedComponents: .date)
                DatePicker("Balance as of", selection: $asOfDate, in: ...Date(), displayedComponents: .date)
                if periodStart > asOfDate {
                    Label("The beginning date must be on or before the as-of date.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if let statement = snapshot {
                Section("Summary") {
                    statementRow("Beginning balance", statement.beginningBalanceCents)
                    statementRow("New charges", statement.newChargesCents)
                    statementRow("Payments and credits", -statement.paymentsAndCreditsCents)
                    statementRow("Balance adjustments", statement.balanceAdjustmentsCents)
                    Divider()
                    statementRow(statement.currentBalanceCents < 0 ? "Family credit" : "Current amount due", statement.currentBalanceCents, emphasized: true)
                }

                Section("Activity") {
                    if statement.activity.isEmpty {
                        Text("No activity in this period.").foregroundStyle(.secondary)
                    } else {
                        ForEach(statement.activity) { row in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.description.isEmpty ? row.kind.rawValue : row.description).font(.headline)
                                    Text("\(row.memberName) - \(row.kind.rawValue) - \(row.date.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    MoneyText(cents: row.balanceEffectCents, colorBySign: true)
                                    Text("Balance \(Money.currency(cents: row.runningBalanceCents))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Upcoming Due Items") {
                    if statement.upcoming.isEmpty {
                        Text("No future-dated charges are recorded.").foregroundStyle(.secondary)
                    } else {
                        ForEach(statement.upcoming) { row in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.description).font(.headline)
                                    Text("\(row.memberName) - due \(row.date.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                MoneyText(cents: row.amountCents)
                            }
                        }
                    }
                }

                Section {
                    Text("The PDF contains private family financial information. TroopLedger opens the system export sheet so you can choose an appropriate secure destination; it does not email statements automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("Statement unavailable", systemImage: "doc.badge.ellipsis", description: Text(statementUnavailableMessage))
                    .listRowBackground(Color.clear)
            }
        }
        .pageToolbar(title: family.name) {
            Button("Export PDF", systemImage: "square.and.arrow.up", action: prepareExport)
                .disabled(snapshot == nil)
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: document,
            contentType: .pdf,
            defaultFilename: filename
        ) { completeExport($0) }
        .alert("Family Statement", isPresented: Binding(
            get: { message != nil || errorMessage != nil },
            set: { if !$0 { message = nil; errorMessage = nil } }
        )) {
            Button("OK") { message = nil; errorMessage = nil }
        } message: {
            Text(errorMessage ?? message ?? "")
        }
    }

    private var statementUnavailableMessage: String {
        if periodStart > asOfDate { return FamilyStatementError.invalidPeriod.localizedDescription }
        if Calendar.current.startOfDay(for: asOfDate) > Calendar.current.startOfDay(for: Date()) {
            return FamilyStatementError.asOfDateInFuture.localizedDescription
        }
        return FamilyStatementError.noMembers.localizedDescription
    }

    private func statementRow(_ label: String, _ cents: Int64, emphasized: Bool = false) -> some View {
        HStack {
            Text(label).fontWeight(emphasized ? .semibold : .regular)
            Spacer()
            MoneyText(cents: cents, colorBySign: emphasized).fontWeight(emphasized ? .semibold : .regular)
        }
    }

    private func prepareExport() {
        do {
            let statement = try FamilyStatementService.makeSnapshot(
                family: family,
                people: people,
                entries: entries,
                events: events,
                periodStart: periodStart,
                asOfDate: asOfDate,
                troopProfile: troopProfiles.first
            )
            guard let data = FamilyStatementPDFRenderer.render(statement) else {
                throw CocoaError(.fileWriteUnknown)
            }
            document = FamilyStatementPDFDocument(data: data)
            filename = FamilyStatementService.defaultFilename(for: statement)
            showingExporter = true
        } catch {
            errorMessage = "The statement could not be prepared: \(error.localizedDescription)"
        }
    }

    private func completeExport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            AuditLogger.record(
                .export,
                recordType: "Family Statement",
                recordID: family.id,
                summary: "Exported family statement for \(family.name)",
                details: AuditLogger.details([
                    ("File", url.lastPathComponent),
                    ("Period beginning", periodStart.formatted(date: .numeric, time: .omitted)),
                    ("As of", asOfDate.formatted(date: .numeric, time: .omitted)),
                ]),
                in: modelContext
            )
            do {
                try modelContext.save()
                message = "Statement exported successfully."
            } catch {
                errorMessage = "The statement was exported, but its audit entry could not be saved: \(error.localizedDescription)"
            }
        case .failure(let error):
            let nsError = error as NSError
            guard !(error is CancellationError), nsError.code != NSUserCancelledError else { return }
            errorMessage = "The statement could not be exported: \(error.localizedDescription)"
        }
    }
}
