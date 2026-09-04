import SwiftData
import SwiftUI

struct RecurringChargeBatchListView: View {
    @Query(sort: \RecurringChargeBatchRecord.postedAt, order: .reverse) private var batches: [RecurringChargeBatchRecord]
    @State private var showingBuilder = false

    var body: some View {
        Group {
            if batches.isEmpty {
                EmptyMessage(
                    title: "No charge batches",
                    message: "Create a reviewed batch for recurring dues or registration assessments instead of entering the same charge one person at a time.",
                    systemImage: "person.2.badge.plus"
                )
            } else {
                List(batches) { batch in
                    NavigationLink {
                        RecurringChargeBatchDetailView(batch: batch)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: batch.kind == .registration ? "person.text.rectangle" : "calendar.badge.plus")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(batch.name).font(.headline)
                                // The batch stores its allocation count; scanning every allocation twice per row was wasted.
                                Text("\(batch.chargeDate.formatted(date: .abbreviated, time: .omitted)) - \(batch.allocationCount) charge\(batch.allocationCount == 1 ? "" : "s") - \(batch.category)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !batch.programYear.isEmpty {
                                    Text("Program year \(batch.programYear)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            MoneyText(cents: batch.totalCents)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .pageToolbar(title: "Charge Batches") {
            Button("New Charge Batch", systemImage: "plus") { showingBuilder = true }
        }
        .sheet(isPresented: $showingBuilder) { RecurringChargeBatchBuilderView() }
    }

}

private struct RecurringChargeBatchBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\PersonRecord.lastName), SortDescriptor(\PersonRecord.firstName)]) private var people: [PersonRecord]
    @Query private var registrations: [RegistrationRecord]
    @Query private var existingAllocations: [RecurringChargeAllocationRecord]
    @State private var name = "Monthly Dues"
    @State private var kind = RecurringChargeBatchKind.dues
    @State private var chargeDate = Date()
    @State private var category = "Dues"
    @State private var amount = "0.00"
    @State private var programYear = ""
    @State private var notes = ""
    @State private var selectedPersonIDs: Set<UUID> = []
    @State private var includeInactive = false
    @State private var proposal: RecurringChargeBatchProposal?
    @State private var errorMessage: String?

    private var programYears: [String] {
        Array(Set(registrations.map { $0.programYear.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
            .sorted(by: >)
    }

    private var visiblePeople: [PersonRecord] {
        people.filter { includeInactive || $0.isActive }
    }

    /// "Select Eligible" for dues picks Scouts; parents and other contacts are not charged troop dues and
    /// were being swept into batches by the bulk button. Anyone can still be selected individually.
    private var selectablePeople: [PersonRecord] {
        guard kind == .registration else { return visiblePeople.filter { $0.role == .scout } }
        return visiblePeople.filter {
            (RecurringChargeBatchService.assessedDues(for: $0.id, programYear: programYear, registrations: registrations) ?? 0) > 0
        }
    }

    var body: some View {
        NavigationStack {
            if let proposal {
                review(proposal)
            } else {
                builder
            }
        }
        .frame(minWidth: 560, minHeight: 700)
        .alert("Charge Batch", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private var builder: some View {
        Form {
            Section("Batch") {
                Picker("Charge type", selection: $kind) {
                    ForEach(RecurringChargeBatchKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Batch name", text: $name)
                DatePicker("Charge date", selection: $chargeDate, displayedComponents: .date)
                TextField("Member-ledger category", text: $category)
                if kind == .dues {
                    AmountField(title: "Amount per person", text: $amount)
                } else if programYears.isEmpty {
                    Label("No registration records with program years are available.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Picker("Program year", selection: $programYear) {
                        ForEach(programYears, id: \.self) { Text($0).tag($0) }
                    }
                    Text("Each selected person receives the positive dues amount already assessed on the preferred registration record for this program year.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                TextField("Batch notes", text: $notes, axis: .vertical)
            }

            Section {
                Toggle("Include inactive people", isOn: $includeInactive)
                HStack {
                    Button("Select Eligible") {
                        selectedPersonIDs.formUnion(selectablePeople.map(\.id))
                    }
                    Spacer()
                    Button("Clear") { selectedPersonIDs.removeAll() }
                        .disabled(selectedPersonIDs.isEmpty)
                }
            } header: {
                Text("People")
            } footer: {
                Text(kind == .dues
                    ? "\(selectedPersonIDs.count) selected. Select Eligible chooses active Scouts; tap individual leaders or others to add them."
                    : "\(selectedPersonIDs.count) selected. Registration rows without positive assessed dues for the chosen year cannot be selected.")
            }

            Section("Proposed Charges") {
                if visiblePeople.isEmpty {
                    Text("No people are available.").foregroundStyle(.secondary)
                } else {
                    ForEach(visiblePeople) { person in
                        personButton(person)
                    }
                }
            }

            Section {
                Text("Nothing is written while selecting people. Review shows every person and amount before posting. Posting creates one immutable batch allocation and one ordinary member-ledger charge per person; it does not create bank-account income.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("New Charge Batch")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Review Charges", action: prepareReview)
                    .disabled(selectedPersonIDs.isEmpty)
            }
        }
        .onAppear {
            if programYear.isEmpty { programYear = programYears.first ?? "" }
        }
        .onChange(of: kind) { oldValue, newValue in
            selectedPersonIDs.removeAll()
            // Only replace the name and category when they still hold the previous kind's defaults, so a
            // batch name the treasurer typed is not thrown away by toggling the type.
            let previous = Self.defaults(for: oldValue)
            let next = Self.defaults(for: newValue)
            if name == previous.name { name = next.name }
            if category == previous.category { category = next.category }
            if newValue == .registration {
                programYear = programYear.isEmpty ? (programYears.first ?? "") : programYear
            }
        }
        .onChange(of: programYear) { _, _ in
            if kind == .registration { selectedPersonIDs.removeAll() }
        }
    }

    private static func defaults(for kind: RecurringChargeBatchKind) -> (name: String, category: String) {
        kind == .registration ? ("Registration Charges", "Registration") : ("Monthly Dues", "Dues")
    }

    private func personButton(_ person: PersonRecord) -> some View {
        let assessed = RecurringChargeBatchService.assessedDues(
            for: person.id,
            programYear: programYear,
            registrations: registrations
        )
        let eligible = kind == .dues || (assessed ?? 0) > 0
        return Button {
            if selectedPersonIDs.contains(person.id) { selectedPersonIDs.remove(person.id) }
            else { selectedPersonIDs.insert(person.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedPersonIDs.contains(person.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedPersonIDs.contains(person.id) ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.displayName).foregroundStyle(eligible ? .primary : .secondary)
                    Text([person.role.rawValue, person.isActive ? nil : "Inactive"].compactMap { $0 }.joined(separator: " - "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if kind == .dues {
                    Text(Money.cents(from: amount).map { Money.currency(cents: $0) } ?? "Invalid amount")
                        .foregroundStyle(.secondary)
                } else if let assessed, assessed > 0 {
                    MoneyText(cents: assessed)
                } else {
                    Text("No assessed dues").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!eligible)
    }

    private func review(_ proposal: RecurringChargeBatchProposal) -> some View {
        List {
            Section("Batch Summary") {
                LabeledContent("Name", value: proposal.name)
                LabeledContent("Type", value: proposal.kind.rawValue)
                LabeledContent("Charge date", value: proposal.chargeDate.formatted(date: .long, time: .omitted))
                LabeledContent("Category", value: proposal.category)
                if !proposal.programYear.isEmpty { LabeledContent("Program year", value: proposal.programYear) }
                LabeledContent("People", value: String(proposal.rows.count))
                LabeledContent("Total charges", value: Money.currency(cents: proposal.totalCents))
            }

            Section("Charges to Post") {
                ForEach(proposal.rows) { row in
                    HStack {
                        Text(row.personName)
                        Spacer()
                        MoneyText(cents: row.amountCents)
                    }
                }
            }

            if !proposal.notes.isEmpty {
                Section("Notes") { Text(proposal.notes) }
            }

            Section {
                Text("Review the complete list before posting. Posted batches and allocations are read-only. A second batch with the same person, date, category, and amount is rejected as a likely duplicate.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Review Charge Batch")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Back") { self.proposal = nil } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Post \(proposal.rows.count) Charges", action: post)
            }
        }
    }

    private func draft() -> RecurringChargeBatchDraft {
        RecurringChargeBatchDraft(
            name: name,
            kind: kind,
            chargeDate: chargeDate,
            category: category,
            fixedAmountCents: Money.cents(from: amount),
            programYear: programYear,
            notes: notes,
            selectedPersonIDs: selectedPersonIDs
        )
    }

    private func prepareReview() {
        do {
            proposal = try RecurringChargeBatchService.preview(
                draft: draft(),
                people: people,
                registrations: registrations,
                existingAllocations: existingAllocations
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func post() {
        do {
            _ = try RecurringChargeBatchService.post(draft: draft(), in: modelContext)
            dismiss()
        } catch {
            proposal = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct RecurringChargeBatchDetailView: View {
    @Query private var allAllocations: [RecurringChargeAllocationRecord]
    @Query private var memberEntries: [MemberLedgerEntry]
    let batch: RecurringChargeBatchRecord

    private var allocations: [RecurringChargeAllocationRecord] {
        allAllocations
            .filter { $0.batchID == batch.id }
            .sorted { $0.personNameSnapshot.localizedStandardCompare($1.personNameSnapshot) == .orderedAscending }
    }

    var body: some View {
        List {
            Section("Posted Batch") {
                LabeledContent("Name", value: batch.name)
                LabeledContent("Type", value: batch.kind.rawValue)
                LabeledContent("Charge date", value: batch.chargeDate.formatted(date: .long, time: .omitted))
                LabeledContent("Category", value: batch.category)
                if !batch.programYear.isEmpty { LabeledContent("Program year", value: batch.programYear) }
                if batch.fixedAmountCents > 0 { LabeledContent("Amount per person", value: Money.currency(cents: batch.fixedAmountCents)) }
                LabeledContent("People charged", value: String(batch.allocationCount))
                LabeledContent("Total", value: Money.currency(cents: batch.totalCents))
                LabeledContent("Posted", value: batch.postedAt.formatted(date: .abbreviated, time: .shortened))
                if !batch.notes.isEmpty { LabeledContent("Notes", value: batch.notes) }
            }

            Section("Read-only Allocations") {
                let memberEntryIDs = Set(memberEntries.map(\.id))
                ForEach(allocations) { allocation in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(allocation.personNameSnapshot).font(.headline)
                            Text(allocation.categorySnapshot).font(.caption).foregroundStyle(.secondary)
                            if allocation.registrationID != nil {
                                Text("Linked to assessed registration dues").font(.caption2).foregroundStyle(.secondary)
                            }
                            if allocation.memberEntryID.map({ memberEntryIDs.contains($0) }) != true {
                                Label("Generated member-ledger charge is missing", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        MoneyText(cents: allocation.amountCents)
                    }
                    .padding(.vertical, 3)
                }
            }

            Section {
                Text("This batch is historical evidence of the reviewed posting. Its allocations preserve the charged names and amounts even if person or registration records later change.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Charge Batch")
    }
}
