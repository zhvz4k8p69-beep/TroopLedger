import SwiftUI
import SwiftData

struct BudgetView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LedgerCategoryRecord.sortOrder) private var categories: [LedgerCategoryRecord]
    @Query(sort: \OperatingBudgetRecord.modifiedAt, order: .reverse) private var budgets: [OperatingBudgetRecord]
    @Query private var budgetLines: [BudgetLineRecord]
    @Query private var transactions: [LedgerTransaction]
    @State private var selectedYear = ReportingYearBasis.schoolYear.startingYear(containing: Date())
    @State private var displayedStatus: BudgetStatus = .working
    @State private var budgetToEdit: OperatingBudgetRecord?
    @State private var showingCategories = false
    @State private var showingApprovalConfirmation = false
    @State private var message: String?

    private var years: [Int] {
        let current = ReportingYearBasis.schoolYear.startingYear(containing: Date())
        let transactionYears = transactions.map { ReportingYearBasis.schoolYear.startingYear(containing: $0.date) }
        return Set(budgets.map(\.reportingYearStart) + transactionYears + [current, selectedYear]).sorted(by: >)
    }

    private var selectedBudget: OperatingBudgetRecord? {
        budgets
            .filter { $0.reportingYearStart == selectedYear && $0.status == displayedStatus }
            .max { lhs, rhs in
                let left = lhs.approvedAt ?? lhs.modifiedAt
                let right = rhs.approvedAt ?? rhs.modifiedAt
                return left < right
            }
    }

    private var selectedLines: [BudgetLineRecord] {
        guard let selectedBudget else { return [] }
        return budgetLines
            .filter { $0.budgetID == selectedBudget.id }
            .sorted { $0.categoryName.localizedStandardCompare($1.categoryName) == .orderedAscending }
    }

    private var budgetIncomeCents: Int64 {
        selectedLines.filter { $0.direction == .income }.reduce(0) { $0 + $1.amountCents }
    }

    private var budgetExpenseCents: Int64 {
        selectedLines.filter { $0.direction == .expense }.reduce(0) { $0 + $1.amountCents }
    }

    var body: some View {
        List {
            Section("School Year") {
                Picker("School year beginning", selection: $selectedYear) {
                    ForEach(years, id: \.self) { year in
                        Text(ReportingPeriod(basis: .schoolYear, startingYear: year).pickerLabel).tag(year)
                    }
                }
                LabeledContent("Dates", value: ReportingPeriod(basis: .schoolYear, startingYear: selectedYear).dateRangeLabel())
                Picker("Budget version", selection: $displayedStatus) {
                    ForEach(BudgetStatus.allCases) { status in Text(status.rawValue).tag(status) }
                }
                .pickerStyle(.segmented)
            }

            if let selectedBudget {
                Section(displayedStatus == .approved ? "Approved Budget — Revision \(selectedBudget.revision)" : "Working Budget") {
                    budgetLinesSection(for: .income)
                    budgetLinesSection(for: .expense)
                    Divider()
                    budgetRow("Budgeted income", budgetIncomeCents, emphasized: true)
                    budgetRow("Budgeted expenses", budgetExpenseCents, emphasized: true)
                    budgetRow("Planned surplus / (deficit)", budgetIncomeCents - budgetExpenseCents, emphasized: true, colorBySign: true)
                    if !selectedBudget.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        LabeledContent("Notes", value: selectedBudget.notes)
                    }
                    if let approvedAt = selectedBudget.approvedAt {
                        LabeledContent("Approved", value: approvedAt.formatted(date: .long, time: .shortened))
                    }
                }

                if displayedStatus == .working {
                    Section("Actions") {
                        Button("Edit Working Budget", systemImage: "pencil") { budgetToEdit = selectedBudget }
                        Button("Approve as New Revision", systemImage: "checkmark.seal") {
                            showingApprovalConfirmation = true
                        }
                        .disabled(selectedLines.isEmpty)
                        Text("Approval creates a dated, read-only snapshot. The working budget remains available for the next revision.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    ContentUnavailableView(
                        displayedStatus == .working ? "No Working Budget" : "No Approved Budget",
                        systemImage: displayedStatus == .working ? "pencil.and.list.clipboard" : "checkmark.seal",
                        description: Text(displayedStatus == .working
                            ? "Create a working budget from the active category catalog."
                            : "Approve a working budget to create the first read-only revision.")
                    )
                    if displayedStatus == .working {
                        Button("Create Working Budget", systemImage: "plus", action: createWorkingBudget)
                    }
                }
            }

            Section("Category Catalog") {
                LabeledContent("Active income categories", value: String(categories.filter { $0.isActive && $0.direction == .income }.count))
                LabeledContent("Active expense categories", value: String(categories.filter { $0.isActive && $0.direction == .expense }.count))
                Button("Manage Categories", systemImage: "tag") { showingCategories = true }
                Text("Standard troop categories are supplemented by categories already used in the register. Archived categories remain on historical transactions and approved budgets.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .pageToolbar(title: "Budget") {
            Button("Categories", systemImage: "tag") { showingCategories = true }
        }
        .task { seedCategories() }
        .sheet(item: $budgetToEdit) { BudgetEditorView(budget: $0) }
        .sheet(isPresented: $showingCategories) { CategoryManagementView() }
        .confirmationDialog(
            "Approve this working budget?",
            isPresented: $showingApprovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Approve New Revision") { approveWorkingBudget() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A dated approved snapshot will be created. It cannot be edited from the app.")
        }
        .alert("Budget", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    @ViewBuilder
    private func budgetLinesSection(for direction: TransactionDirection) -> some View {
        let lines = selectedLines.filter { $0.direction == direction }
        if !lines.isEmpty {
            Text(direction.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(lines) { line in budgetRow(line.categoryName, line.amountCents) }
        }
    }

    private func budgetRow(_ label: String, _ cents: Int64, emphasized: Bool = false, colorBySign: Bool = false) -> some View {
        HStack {
            Text(label).fontWeight(emphasized ? .semibold : .regular)
            Spacer()
            MoneyText(cents: cents, colorBySign: colorBySign).fontWeight(emphasized ? .semibold : .regular)
        }
    }

    private func seedCategories() {
        do {
            _ = try CategoryCatalog.seedMissingDefinitions(in: modelContext)
        } catch {
            message = "The category catalog could not be prepared: \(error.localizedDescription)"
        }
    }

    private func createWorkingBudget() {
        let budget = OperatingBudgetRecord(reportingYearStart: selectedYear)
        modelContext.insert(budget)
        AuditLogger.record(
            .create,
            recordType: "Operating Budget",
            recordID: budget.id,
            summary: "Created working budget for \(budget.reportingPeriod.label)",
            in: modelContext
        )
        do {
            try modelContext.save()
            budgetToEdit = budget
        } catch {
            message = "The working budget could not be created: \(error.localizedDescription)"
        }
    }

    private func approveWorkingBudget() {
        guard let working = selectedBudget, working.status == .working else { return }
        let revisions = budgets.filter { $0.reportingYearStart == selectedYear && $0.status == .approved }
        let approvedAt = Date()
        let approved = OperatingBudgetRecord(
            reportingYearStart: selectedYear,
            status: .approved,
            revision: (revisions.map(\.revision).max() ?? 0) + 1
        )
        approved.notes = working.notes
        approved.createdAt = approvedAt
        approved.modifiedAt = approvedAt
        approved.approvedAt = approvedAt
        modelContext.insert(approved)
        for line in selectedLines {
            let approvedLine = BudgetLineRecord(
                budgetID: approved.id,
                categoryID: line.categoryID,
                categoryName: line.categoryName,
                direction: line.direction,
                amountCents: line.amountCents
            )
            approvedLine.createdAt = approvedAt
            approvedLine.modifiedAt = approvedAt
            modelContext.insert(approvedLine)
        }
        AuditLogger.record(
            .create,
            recordType: "Operating Budget",
            recordID: approved.id,
            summary: "Approved revision \(approved.revision) for \(approved.reportingPeriod.label)",
            details: AuditLogger.details([
                ("Working budget ID", working.id.uuidString),
                ("Income", Money.currency(cents: budgetIncomeCents)),
                ("Expenses", Money.currency(cents: budgetExpenseCents)),
            ]),
            in: modelContext
        )
        do {
            try modelContext.save()
            displayedStatus = .approved
        } catch {
            message = "The approved revision could not be saved: \(error.localizedDescription)"
        }
    }
}

private struct BudgetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LedgerCategoryRecord.sortOrder) private var categories: [LedgerCategoryRecord]
    @Query private var allLines: [BudgetLineRecord]
    let budget: OperatingBudgetRecord
    @State private var amounts: [UUID: String] = [:]
    @State private var notes: String
    @State private var didLoad = false
    @State private var errorMessage: String?

    init(budget: OperatingBudgetRecord) {
        self.budget = budget
        _notes = State(initialValue: budget.notes)
    }

    private var existingLines: [BudgetLineRecord] { allLines.filter { $0.budgetID == budget.id } }
    private var editableCategories: [LedgerCategoryRecord] {
        categories.filter { category in
            category.isActive || existingLines.contains { $0.categoryID == category.id && $0.amountCents != 0 }
        }
    }
    private var canSave: Bool {
        amounts.values.allSatisfy { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Money.cents(from: value).map { $0 >= 0 } == true
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("School Year") {
                    LabeledContent("Budget", value: budget.reportingPeriod.label)
                    LabeledContent("Dates", value: budget.reportingPeriod.dateRangeLabel())
                }
                categorySection(.income)
                categorySection(.expense)
                Section("Notes") {
                    TextField("Assumptions, approval context, or working notes", text: $notes, axis: .vertical)
                }
                if !canSave {
                    Section {
                        Label("Every amount must be blank, zero, or a positive dollar amount.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Working Budget")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .onAppear(perform: loadAmounts)
            .alert("Working Budget", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .frame(minWidth: 500, minHeight: 650)
    }

    @ViewBuilder
    private func categorySection(_ direction: TransactionDirection) -> some View {
        let matching = editableCategories.filter { $0.direction == direction }
        Section(direction.rawValue) {
            if matching.isEmpty {
                Text("No active \(direction.rawValue.lowercased()) categories.").foregroundStyle(.secondary)
            } else {
                ForEach(matching) { category in
                    AmountField(title: category.name, text: amountBinding(for: category.id))
                }
            }
        }
    }

    private func amountBinding(for categoryID: UUID) -> Binding<String> {
        Binding(
            get: { amounts[categoryID] ?? "" },
            set: { amounts[categoryID] = $0 }
        )
    }

    private func loadAmounts() {
        guard !didLoad else { return }
        for category in editableCategories {
            if let line = existingLines.first(where: { $0.categoryID == category.id }) {
                amounts[category.id] = line.amountCents == 0 ? "" : Money.editableString(cents: line.amountCents)
            }
        }
        didLoad = true
    }

    private func save() {
        guard canSave else { return }
        // Approved revisions are dated, read-only snapshots; nothing that reaches this editor may rewrite one.
        guard budget.status == .working else {
            errorMessage = "Approved budget revisions cannot be edited. Change the working budget and approve a new revision."
            return
        }
        let modifiedAt = Date()
        for category in editableCategories {
            let cents = Money.cents(from: amounts[category.id] ?? "") ?? 0
            let existing = existingLines.first { $0.categoryID == category.id }
            if cents == 0 {
                if let existing { modelContext.delete(existing) }
                continue
            }
            let line = existing ?? BudgetLineRecord(
                budgetID: budget.id,
                categoryID: category.id,
                categoryName: category.name,
                direction: category.direction,
                amountCents: cents
            )
            line.categoryName = category.name
            line.direction = category.direction
            line.amountCents = cents
            line.modifiedAt = modifiedAt
            if existing == nil { modelContext.insert(line) }
        }
        budget.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        budget.modifiedAt = modifiedAt
        AuditLogger.record(
            .edit,
            recordType: "Operating Budget",
            recordID: budget.id,
            summary: "Updated working budget for \(budget.reportingPeriod.label)",
            in: modelContext
        )
        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = "The working budget could not be saved: \(error.localizedDescription)"
        }
    }
}

private struct CategoryManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LedgerCategoryRecord.name) private var categories: [LedgerCategoryRecord]
    @State private var categoryToEdit: LedgerCategoryRecord?
    @State private var showingNewCategory = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                categorySection("Income", categories.filter { $0.isActive && $0.direction == .income })
                categorySection("Expenses", categories.filter { $0.isActive && $0.direction == .expense })
                categorySection("Archived", categories.filter { !$0.isActive })
            }
            .navigationTitle("Categories")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Add", systemImage: "plus") { showingNewCategory = true } }
            }
            .task { seedCategories() }
            .sheet(isPresented: $showingNewCategory) { CategoryFormView() }
            .sheet(item: $categoryToEdit) { CategoryFormView(category: $0) }
            .alert("Categories", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .frame(minWidth: 480, minHeight: 600)
    }

    @ViewBuilder
    private func categorySection(_ title: String, _ records: [LedgerCategoryRecord]) -> some View {
        if !records.isEmpty {
            Section(title) {
                ForEach(records) { category in
                    Button { categoryToEdit = category } label: {
                        HStack {
                            Text(category.name)
                            Spacer()
                            if category.isStandard {
                                Text("Standard").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func seedCategories() {
        do {
            _ = try CategoryCatalog.seedMissingDefinitions(in: modelContext)
        } catch {
            errorMessage = "The category catalog could not be prepared: \(error.localizedDescription)"
        }
    }
}

private struct CategoryFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var categories: [LedgerCategoryRecord]
    private let category: LedgerCategoryRecord?
    @State private var name: String
    @State private var direction: TransactionDirection
    @State private var isActive: Bool
    @State private var notes: String
    @State private var errorMessage: String?

    init(category: LedgerCategoryRecord? = nil) {
        self.category = category
        _name = State(initialValue: category?.name ?? "")
        _direction = State(initialValue: category?.direction ?? .expense)
        _isActive = State(initialValue: category?.isActive ?? true)
        _notes = State(initialValue: category?.notes ?? "")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDuplicate: Bool {
        categories.contains {
            $0.id != category?.id && CategoryCatalog.key(name: $0.name, direction: $0.direction) == CategoryCatalog.key(name: trimmedName, direction: direction)
        }
    }
    private var canSave: Bool { !trimmedName.isEmpty && !isDuplicate }

    var body: some View {
        NavigationStack {
            Form {
                Section("Definition") {
                    TextField("Category name", text: $name)
                    Picker("Type", selection: $direction) {
                        ForEach(TransactionDirection.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .disabled(category != nil)
                    Toggle("Active", isOn: $isActive)
                }
                Section("Notes") { TextField("Optional guidance", text: $notes, axis: .vertical) }
                if isDuplicate {
                    Section {
                        Label("That category already exists for this transaction type.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Text("Archiving removes a category from new transaction and budget choices without changing historical records. Renaming a definition does not rewrite old transactions or approved budgets.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(category == nil ? "New Category" : "Edit Category")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .alert("Category", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .frame(minWidth: 440, minHeight: 450)
    }

    private func save() {
        guard canSave else { return }
        let record = category ?? LedgerCategoryRecord(name: trimmedName, direction: direction)
        let isNew = category == nil
        record.name = trimmedName
        record.direction = direction
        record.isActive = isActive
        record.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        record.modifiedAt = Date()
        if isNew { modelContext.insert(record) }
        AuditLogger.record(
            isNew ? .create : .edit,
            recordType: "Ledger Category",
            recordID: record.id,
            summary: "\(isNew ? "Created" : "Edited") \(record.direction.rawValue.lowercased()) category \(record.name)",
            details: AuditLogger.details([("Active", record.isActive ? "Yes" : "No")]),
            in: modelContext
        )
        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = "The category could not be saved: \(error.localizedDescription)"
        }
    }
}
