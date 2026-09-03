import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
import VisionKit
#endif

struct ReimbursementListView: View {
    @Query(sort: \ReimbursementRequest.submittedAt, order: .reverse) private var requests: [ReimbursementRequest]
    @Query(sort: \PersonRecord.lastName) private var people: [PersonRecord]
    @State private var filter = ReimbursementFilter.open
    @State private var showingNewRequest = false

    private var filteredRequests: [ReimbursementRequest] {
        switch filter {
        case .open: requests.filter { $0.status == .submitted || $0.status == .approved }
        case .all: requests
        case .submitted: requests.filter { $0.status == .submitted }
        case .approved: requests.filter { $0.status == .approved }
        case .paid: requests.filter { $0.status == .paid }
        case .declined: requests.filter { $0.status == .declined }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Request filter", selection: $filter) {
                ForEach(ReimbursementFilter.allCases) { option in Text(option.rawValue).tag(option) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            if filteredRequests.isEmpty {
                EmptyMessage(
                    title: requests.isEmpty ? "No reimbursement requests" : "No matching requests",
                    message: requests.isEmpty
                        ? "Add a request to retain its purpose, receipt evidence, review, and final payment link."
                        : "Choose another status filter.",
                    systemImage: "doc.text.image"
                )
            } else {
                List(filteredRequests) { request in
                    NavigationLink {
                        ReimbursementDetailView(request: request)
                    } label: {
                        ReimbursementRow(request: request, requesterName: requesterName(for: request))
                    }
                }
                .listStyle(.inset)
            }
        }
        .pageHeader(title: "Reimbursements")
        .toolbar {
            Button("New Reimbursement", systemImage: "plus") { showingNewRequest = true }
        }
        .sheet(isPresented: $showingNewRequest) { ReimbursementEditorView() }
    }

    private func requesterName(for request: ReimbursementRequest) -> String {
        people.first { $0.id == request.requesterPersonID }?.displayName ?? "Unknown requester"
    }
}

private enum ReimbursementFilter: String, CaseIterable, Identifiable {
    case open = "Open"
    case submitted = "Review"
    case approved = "Approved"
    case paid = "Paid"
    case declined = "Declined"
    case all = "All"
    var id: String { rawValue }
}

private struct ReimbursementRow: View {
    let request: ReimbursementRequest
    let requesterName: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: request.status.systemImage)
                .foregroundStyle(statusColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(request.purpose).font(.headline)
                Text("\(requesterName) • \(request.purchaseDate.formatted(date: .abbreviated, time: .omitted)) • \(request.category)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(request.status.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            Spacer()
            MoneyText(cents: request.amountCents)
        }
        .padding(.vertical, 3)
    }

    private var statusColor: Color {
        switch request.status {
        case .submitted: .orange
        case .approved: .blue
        case .declined: .red
        case .paid: .green
        }
    }
}

struct ReimbursementEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PersonRecord.lastName) private var people: [PersonRecord]
    @Query(sort: \EventRecord.startDate, order: .reverse) private var events: [EventRecord]
    @Query(sort: \LedgerCategoryRecord.sortOrder) private var categories: [LedgerCategoryRecord]
    let request: ReimbursementRequest?
    @State private var requesterPersonID: UUID?
    @State private var purchaseDate: Date
    @State private var purpose: String
    @State private var category: String
    @State private var amount: String
    @State private var eventID: UUID?
    @State private var notes: String
    @State private var errorMessage: String?

    init(request: ReimbursementRequest? = nil) {
        self.request = request
        _requesterPersonID = State(initialValue: request?.requesterPersonID)
        _purchaseDate = State(initialValue: request?.purchaseDate ?? Date())
        _purpose = State(initialValue: request?.purpose ?? "")
        _category = State(initialValue: request?.category ?? "")
        _amount = State(initialValue: request.map { Money.editableString(cents: $0.amountCents) } ?? "")
        _eventID = State(initialValue: request?.eventID)
        _notes = State(initialValue: request?.notes ?? "")
    }

    private var expenseCategories: [LedgerCategoryRecord] {
        categories.filter { $0.isActive && $0.direction == .expense }
    }

    private var categorySelection: Binding<UUID?> {
        Binding(
            get: { expenseCategories.first { $0.name.caseInsensitiveCompare(category) == .orderedSame }?.id },
            set: { id in
                if let id, let selected = expenseCategories.first(where: { $0.id == id }) { category = selected.name }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Request") {
                    Picker("Requester", selection: $requesterPersonID) {
                        Text("Choose a person").tag(nil as UUID?)
                        ForEach(people.filter { $0.isActive || $0.id == request?.requesterPersonID }) { Text($0.displayName).tag($0.id as UUID?) }
                    }
                    DatePicker("Purchase date", selection: $purchaseDate, displayedComponents: .date)
                    TextField("Business purpose", text: $purpose, axis: .vertical)
                    AmountField(title: "Amount", text: $amount)
                    Picker("Saved category", selection: categorySelection) {
                        Text("Custom category").tag(nil as UUID?)
                        ForEach(expenseCategories) { Text($0.name).tag($0.id as UUID?) }
                    }
                    TextField("Expense category", text: $category)
                    Picker("Event", selection: $eventID) {
                        Text("None").tag(nil as UUID?)
                        ForEach(events) { Text($0.name).tag($0.id as UUID?) }
                    }
                }
                Section("Notes") { TextField("Additional context", text: $notes, axis: .vertical) }
                Section {
                    Text("Save the request before attaching receipt photos, scans, or PDFs. Submitted details and receipts remain editable until the request is approved or declined.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(request == nil ? "New Reimbursement" : "Edit Reimbursement")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear {
                _ = try? CategoryCatalog.seedMissingDefinitions(in: modelContext)
            }
        }
        .frame(minWidth: 470, minHeight: 560)
        .alert("Reimbursement", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func snapshot(_ record: ReimbursementRequest) -> [(String, String)] {
        [
            ("Requester", people.first { $0.id == record.requesterPersonID }?.displayName ?? ""),
            ("Purchase date", record.purchaseDate.formatted(date: .numeric, time: .omitted)),
            ("Purpose", record.purpose),
            ("Category", record.category),
            ("Amount", Money.currency(cents: record.amountCents)),
            ("Event", events.first { $0.id == record.eventID }?.name ?? ""),
            ("Notes", record.notes),
        ]
    }

    private func save() {
        do {
            let cents = Money.cents(from: amount)
            try ReimbursementService.validate(
                requesterPersonID: requesterPersonID,
                purpose: purpose,
                category: category,
                amountCents: cents
            )
            guard let cents else { throw ReimbursementError.invalidAmount }
            let isNew = request == nil
            let record = request ?? ReimbursementRequest(
                requesterPersonID: requesterPersonID,
                purchaseDate: purchaseDate,
                purpose: purpose,
                category: category,
                amountCents: cents,
                eventID: eventID
            )
            guard record.status == .submitted else { throw ReimbursementError.requestNotSubmitted }
            let before = request.map(snapshot)
            record.requesterPersonID = requesterPersonID
            record.purchaseDate = purchaseDate
            record.purpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
            record.category = category.trimmingCharacters(in: .whitespacesAndNewlines)
            record.amountCents = cents
            record.eventID = eventID
            record.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            record.modifiedAt = Date()
            if isNew { modelContext.insert(record) }
            AuditLogger.record(
                isNew ? .create : .edit,
                recordType: "Reimbursement Request",
                recordID: record.id,
                summary: isNew ? "Submitted reimbursement request" : "Edited reimbursement request",
                details: AuditLogger.details([
                    ("Purpose", record.purpose),
                    ("Amount", Money.currency(cents: record.amountCents)),
                    ("Category", record.category),
                    ("Requester ID", record.requesterPersonID?.uuidString),
                    ("Event ID", record.eventID?.uuidString),
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

struct ReimbursementDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PersonRecord.lastName) private var people: [PersonRecord]
    @Query(sort: \EventRecord.startDate, order: .reverse) private var events: [EventRecord]
    @Query(sort: \LedgerTransaction.date, order: .reverse) private var transactions: [LedgerTransaction]
    @Query(sort: \ReimbursementAttachment.createdAt) private var allAttachments: [ReimbursementAttachment]
    @Query(sort: \DisbursementControlSettings.modifiedAt, order: .reverse) private var controlSettings: [DisbursementControlSettings]
    let request: ReimbursementRequest
    @State private var showingEdit = false
    @State private var showingReview = false
    @State private var showingPayment = false
    @State private var showingControls = false
    @State private var showingFileImporter = false
    @State private var selectedAttachment: ReimbursementAttachment?
    @State private var errorMessage: String?
    @State private var showingReopen = false
    @State private var reopenReason = ""
#if os(iOS)
    @State private var showingScanner = false
#endif

    private var canReopen: Bool {
        request.status == .declined || (request.status == .approved && request.linkedTransactionID == nil)
    }

    private var attachments: [ReimbursementAttachment] {
        allAttachments.filter { $0.requestID == request.id }
    }

    private var requesterName: String {
        people.first { $0.id == request.requesterPersonID }?.displayName ?? "Unknown requester"
    }

    private var eventName: String? {
        request.eventID.flatMap { id in events.first { $0.id == id }?.name }
    }

    private var linkedTransaction: LedgerTransaction? {
        request.linkedTransactionID.flatMap { id in transactions.first { $0.id == id } }
    }

    private var controlPolicy: DisbursementControlPolicy {
        DisbursementControlPolicy(settings: controlSettings.first)
    }

    var body: some View {
        List {
            Section("Request") {
                LabeledContent("Status") { Label(request.status.rawValue, systemImage: request.status.systemImage) }
                LabeledContent("Requester", value: requesterName)
                LabeledContent("Purchase date", value: request.purchaseDate.formatted(date: .long, time: .omitted))
                LabeledContent("Amount", value: Money.currency(cents: request.amountCents))
                LabeledContent("Category", value: request.category)
                if let eventName { LabeledContent("Event", value: eventName) }
                LabeledContent("Purpose", value: request.purpose)
                if !request.notes.isEmpty { LabeledContent("Notes", value: request.notes) }
                LabeledContent("Submitted", value: request.submittedAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section("Receipt Evidence") {
                if attachments.isEmpty {
                    Text("No receipt is attached.").foregroundStyle(.secondary)
                } else {
                    ForEach(attachments) { attachment in
                        Button { selectedAttachment = attachment } label: {
                            HStack {
                                Image(systemName: attachment.mediaType == "application/pdf" ? "doc.richtext" : "photo")
                                VStack(alignment: .leading) {
                                    Text(attachment.filename)
                                    Text(ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            if request.status == .submitted {
                                Button("Remove", role: .destructive) { remove(attachment) }
                            }
                        }
                    }
                }
                if request.status == .submitted {
                    Button("Attach Photo or PDF", systemImage: "paperclip") { showingFileImporter = true }
#if os(iOS)
                    if VNDocumentCameraViewController.isSupported {
                        Button("Scan Receipt", systemImage: "doc.viewfinder") { showingScanner = true }
                    }
#endif
                } else {
                    Text("Receipt evidence is retained unchanged after review.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let reviewedAt = request.reviewedAt {
                Section("Review") {
                    LabeledContent("Reviewed by", value: request.reviewerName)
                    LabeledContent("Reviewed", value: reviewedAt.formatted(date: .abbreviated, time: .shortened))
                    if !request.reviewNotes.isEmpty { LabeledContent("Notes", value: request.reviewNotes) }
                }
            }

            if controlPolicy.isEnabled && (request.status == .approved || request.status == .paid) {
                Section("Disbursement Controls") {
                    DisbursementControlSummaryView(request: request, policy: controlPolicy)
                    Button(
                        request.disbursementControlRecordedAt == nil ? "Record Control Evidence" : "Edit Control Evidence",
                        systemImage: "person.2.badge.gearshape"
                    ) { showingControls = true }
                }
            }

            if request.status == .submitted {
                Section("Next Step") {
                    Button("Review Request", systemImage: "checkmark.seal") { showingReview = true }
                    if attachments.isEmpty {
                        Label("No receipt is attached. Confirm the evidence requirement before approval.", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            } else if request.status == .approved {
                Section("Next Step") {
                    Button("Record Payment", systemImage: "checkmark.circle") { showingPayment = true }
                    Text("Link an existing matching expense, or create one through the locked-period ledger validator.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if canReopen {
                Section("Correction") {
                    Button("Reopen for Review", systemImage: "arrow.uturn.backward.circle") { showingReopen = true }
                    Text("Returns the request to the review queue when a decision was made by mistake. The original decision stays in the audit log.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if request.status == .paid, let transaction = linkedTransaction {
                Section("Payment") {
                    LabeledContent("Date", value: (request.paymentDate ?? transaction.date).formatted(date: .long, time: .omitted))
                    LabeledContent("Reference", value: request.paymentReference.isEmpty ? "Not recorded" : request.paymentReference)
                    LabeledContent("Ledger transaction", value: transaction.id.uuidString.lowercased())
                    LabeledContent("Account entry", value: "\(transaction.payee) • \(Money.currency(cents: transaction.amountCents))")
                }
            }
        }
        .navigationTitle("Reimbursement")
        .toolbar {
            if request.status == .submitted {
                Button("Edit", systemImage: "pencil") { showingEdit = true }
            }
        }
        .sheet(isPresented: $showingEdit) { ReimbursementEditorView(request: request) }
        .sheet(isPresented: $showingReview) { ReimbursementReviewView(request: request) }
        .sheet(isPresented: $showingPayment) { ReimbursementPaymentView(request: request, requesterName: requesterName) }
        .sheet(isPresented: $showingControls) { DisbursementControlEditorView(request: request) }
        .sheet(item: $selectedAttachment) { attachment in ReceiptPreviewView(attachment: attachment) }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.image, .pdf]) { result in
            importReceipt(result)
        }
#if os(iOS)
        .sheet(isPresented: $showingScanner) {
            ReceiptScannerView { pages in
                showingScanner = false
                addScannedPages(pages)
            } onCancel: {
                showingScanner = false
            }
        }
#endif
        .alert("Reimbursement", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        .alert("Reopen this request for review?", isPresented: $showingReopen) {
            TextField("Reason for reopening", text: $reopenReason)
            Button("Reopen", role: .destructive) { reopen() }
            Button("Cancel", role: .cancel) { reopenReason = "" }
        } message: {
            Text("The \(request.status.rawValue.lowercased()) decision will be cleared and the request returned to Submitted.")
        }
    }

    private func reopen() {
        do {
            try ReimbursementService.reopen(request, reason: reopenReason, in: modelContext)
            reopenReason = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importReceipt(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
            let data = try ImportedFileReader.read(url, maximumBytes: ReimbursementService.maximumAttachmentBytes, tooLargeError: ReimbursementError.receiptTooLarge)
            _ = try ReimbursementService.addAttachment(
                to: request,
                data: data,
                filename: url.lastPathComponent,
                mediaType: type?.preferredMIMEType,
                in: modelContext
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ attachment: ReimbursementAttachment) {
        do { try ReimbursementService.removeAttachment(attachment, from: request, in: modelContext) }
        catch { errorMessage = error.localizedDescription }
    }

#if os(iOS)
    private func addScannedPages(_ pages: [ScannedReceiptPage]) {
        do {
            for page in pages {
                _ = try ReimbursementService.addAttachment(
                    to: request,
                    data: page.data,
                    filename: page.filename,
                    mediaType: "image/jpeg",
                    in: modelContext
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
#endif
}

private struct ReimbursementReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PersonRecord.lastName) private var people: [PersonRecord]
    @Query(sort: \DisbursementControlSettings.modifiedAt, order: .reverse) private var controlSettings: [DisbursementControlSettings]
    @Query private var allAttachments: [ReimbursementAttachment]
    let request: ReimbursementRequest
    @State private var reviewerName = AuditIdentity.current.userIdentity
    @State private var approverPersonID: UUID?
    @State private var approverHousehold = ""
    @State private var notes = ""
    @State private var errorMessage: String?

    /// Active adults other than the requester; approving one's own request is refused by the service as well.
    private var adults: [PersonRecord] { people.filter { $0.role != .scout && $0.isActive && $0.id != request.requesterPersonID } }
    private var controlPolicy: DisbursementControlPolicy { DisbursementControlPolicy(settings: controlSettings.first) }
    private var hasReceipt: Bool { allAttachments.contains { $0.requestID == request.id } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Review") {
                    LabeledContent("Purpose", value: request.purpose)
                    LabeledContent("Amount", value: Money.currency(cents: request.amountCents))
                    if controlPolicy.isEnabled {
                        Picker("Approver roster record", selection: $approverPersonID) {
                            Text("No linked record").tag(nil as UUID?)
                            ForEach(adults) { Text($0.displayName).tag($0.id as UUID?) }
                        }
                        TextField("Approver / reviewer name", text: $reviewerName)
                        TextField("Household label (optional)", text: $approverHousehold)
                    } else {
                        TextField("Reviewer name", text: $reviewerName)
                    }
                    TextField(hasReceipt ? "Review notes" : "Review notes (required to approve without a receipt)", text: $notes, axis: .vertical)
                    if !hasReceipt {
                        Label("No receipt is attached. To approve anyway, record why the request is acceptable without one.", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Text(controlPolicy.isEnabled
                        ? "Approval records the approver as a historical snapshot and freezes the request details and receipts. Only adult roster records are offered. Declining requires an explanation."
                        : "Approval records the reviewer and freezes the request details and receipts. Declining requires an explanation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Review Reimbursement")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Menu("Decide") {
                        Button("Approve", systemImage: "checkmark.seal") { review(approve: true) }
                        Button("Decline", systemImage: "xmark.seal", role: .destructive) { review(approve: false) }
                    }
                }
            }
            .onChange(of: approverPersonID) { _, newID in
                if let person = adults.first(where: { $0.id == newID }) {
                    reviewerName = person.displayName
                }
            }
        }
        .frame(minWidth: 440, minHeight: 340)
        .alert("Review", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func review(approve: Bool) {
        do {
            try ReimbursementService.review(
                request,
                approve: approve,
                reviewerName: reviewerName,
                notes: notes,
                approver: controlPolicy.isEnabled
                    ? DisbursementControlIdentity(
                        personID: approverPersonID,
                        name: reviewerName,
                        household: approverHousehold
                    )
                    : nil,
                in: modelContext
            )
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct ReimbursementPaymentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query(sort: \LedgerTransaction.date, order: .reverse) private var transactions: [LedgerTransaction]
    @Query(sort: \ReimbursementRequest.submittedAt, order: .reverse) private var requests: [ReimbursementRequest]
    @Query(sort: \ReconciliationRecord.statementDate, order: .reverse) private var reconciliations: [ReconciliationRecord]
    @Query(sort: \DisbursementControlSettings.modifiedAt, order: .reverse) private var controlSettings: [DisbursementControlSettings]
    let request: ReimbursementRequest
    let requesterName: String
    @State private var mode = PaymentLinkMode.create
    @State private var accountID: UUID?
    @State private var paymentDate = Date()
    @State private var reference = ""
    @State private var transactionID: UUID?
    @State private var errorMessage: String?

    private var matchingTransactions: [LedgerTransaction] {
        let linked = Set(requests.compactMap(\.linkedTransactionID))
        return transactions.filter {
            $0.direction == .expense
                && !$0.isTransfer
                && $0.amountCents == request.amountCents
                && ($0.personID == nil || $0.personID == request.requesterPersonID)
                && (!linked.contains($0.id) || $0.id == request.linkedTransactionID)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Payment method", selection: $mode) {
                        ForEach(PaymentLinkMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if mode == .create {
                    Section("New Ledger Expense") {
                        Picker("Account", selection: $accountID) {
                            Text("Choose an account").tag(nil as UUID?)
                            ForEach(accounts.filter(\.isActive)) { Text($0.name).tag($0.id as UUID?) }
                        }
                        DatePicker("Payment date", selection: $paymentDate, in: ...Date(), displayedComponents: .date)
                        TextField("Check / payment reference", text: $reference)
                        LabeledContent("Payee", value: requesterName)
                        LabeledContent("Amount", value: Money.currency(cents: request.amountCents))
                        LabeledContent("Category", value: request.category)
                    }
                } else {
                    Section("Existing Ledger Expense") {
                        Picker("Transaction", selection: $transactionID) {
                            Text("Choose a matching expense").tag(nil as UUID?)
                            ForEach(matchingTransactions) { transaction in
                                Text("\(transaction.date.formatted(date: .abbreviated, time: .omitted)) • \(transaction.payee) • \(Money.currency(cents: transaction.amountCents))")
                                    .tag(transaction.id as UUID?)
                            }
                        }
                        if matchingTransactions.isEmpty {
                            Text("No unlinked expense has the exact reimbursement amount.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                let controlPolicy = DisbursementControlPolicy(settings: controlSettings.first)
                if controlPolicy.isEnabled {
                    Section("Disbursement Control Warnings") {
                        DisbursementControlSummaryView(
                            request: request,
                            policy: controlPolicy,
                            showEvidence: false
                        )
                    }
                }
                Section {
                    Text("A reimbursement can link to only one expense, and an expense can pay only one reimbursement. Creating a new expense is blocked in reconciled periods.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Record Payment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Record Paid", action: recordPayment) }
            }
            .onAppear { accountID = accountID ?? accounts.first(where: \.isActive)?.id }
        }
        .frame(minWidth: 480, minHeight: 440)
        .alert("Payment", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func recordPayment() {
        do {
            if mode == .create {
                _ = try ReimbursementService.createAndLinkPayment(
                    for: request,
                    accountID: accountID,
                    paymentDate: paymentDate,
                    reference: reference,
                    payee: requesterName,
                    reconciliations: reconciliations,
                    in: modelContext
                )
            } else {
                try ReimbursementService.linkExistingPayment(for: request, transactionID: transactionID, in: modelContext)
            }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private enum PaymentLinkMode: String, CaseIterable, Identifiable {
    case create = "Create Expense"
    case existing = "Link Existing"
    var id: String { rawValue }
}

private struct ReceiptPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: ReimbursementAttachment

    var body: some View {
        NavigationStack {
            Group {
                if attachment.mediaType == "application/pdf" {
                    ReceiptPDFView(data: attachment.data)
                } else {
#if os(macOS)
                    if let image = NSImage(data: attachment.data) {
                        ScrollView([.horizontal, .vertical]) { Image(nsImage: image).resizable().scaledToFit().padding() }
                    } else { ContentUnavailableView("Unreadable Image", systemImage: "photo.badge.exclamationmark") }
#else
                    if let image = UIImage(data: attachment.data) {
                        ScrollView([.horizontal, .vertical]) { Image(uiImage: image).resizable().scaledToFit().padding() }
                    } else { ContentUnavailableView("Unreadable Image", systemImage: "photo.badge.exclamationmark") }
#endif
                }
            }
            .navigationTitle(attachment.filename)
            .toolbar { Button("Done") { dismiss() } }
        }
        .frame(minWidth: 500, minHeight: 600)
    }
}

/// Receipts are documents supplied by third parties. PDFKit opens link annotations in the browser by default,
/// so a crafted receipt could send the treasurer to an arbitrary site with one click; taking over link handling
/// and doing nothing keeps the preview strictly read-only.
private final class ReceiptPDFLinkBlocker: NSObject, PDFViewDelegate {
    nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}
}

#if os(macOS)
private struct ReceiptPDFView: NSViewRepresentable {
    let data: Data
    func makeCoordinator() -> ReceiptPDFLinkBlocker { ReceiptPDFLinkBlocker() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.delegate = context.coordinator
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        view.document = PDFDocument(data: data)
        view.autoScales = true
    }
}
#else
private struct ReceiptPDFView: UIViewRepresentable {
    let data: Data
    func makeCoordinator() -> ReceiptPDFLinkBlocker { ReceiptPDFLinkBlocker() }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        view.document = PDFDocument(data: data)
        view.autoScales = true
    }
}

struct ScannedReceiptPage: Identifiable {
    let id = UUID()
    let filename: String
    let data: Data
}

private struct ReceiptScannerView: UIViewControllerRepresentable {
    let onComplete: ([ScannedReceiptPage]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete, onCancel: onCancel) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @MainActor VNDocumentCameraViewControllerDelegate {
        let onComplete: ([ScannedReceiptPage]) -> Void
        let onCancel: () -> Void
        init(onComplete: @escaping ([ScannedReceiptPage]) -> Void, onCancel: @escaping () -> Void) {
            self.onComplete = onComplete
            self.onCancel = onCancel
        }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let pages = (0..<scan.pageCount).compactMap { index -> ScannedReceiptPage? in
                guard let data = scan.imageOfPage(at: index).jpegData(compressionQuality: 0.9) else { return nil }
                return ScannedReceiptPage(filename: "Scanned Receipt \(stamp) Page \(index + 1).jpg", data: data)
            }
            controller.dismiss(animated: true) { self.onComplete(pages) }
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true) { self.onCancel() }
        }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            controller.dismiss(animated: true) { self.onCancel() }
        }
    }
}
#endif
