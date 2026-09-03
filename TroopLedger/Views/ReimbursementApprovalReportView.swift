import SwiftData
import SwiftUI

struct ReimbursementApprovalReportView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ReimbursementRequest.submittedAt, order: .reverse) private var requests: [ReimbursementRequest]
    @Query private var attachments: [ReimbursementAttachment]
    @Query private var transactions: [LedgerTransaction]
    @Query private var people: [PersonRecord]
    @Query private var auditEntries: [AuditLogEntry]
    @Query private var controlSettings: [DisbursementControlSettings]
    @Query(sort: \TroopProfileRecord.modifiedAt, order: .reverse) private var troopProfiles: [TroopProfileRecord]
    @State private var issueFilter: ReimbursementApprovalIssueKind?
    @State private var exportDocument: ReimbursementApprovalCSVDocument?
    @State private var exportFilename = ReimbursementApprovalReportService.defaultFilename()
    @State private var showingExporter = false
    @State private var exportMessage: String?

    private var report: ReimbursementApprovalReport {
        ReimbursementApprovalReportService.makeReport(
            requests: requests,
            attachments: attachments,
            transactions: transactions,
            people: people,
            auditEntries: auditEntries,
            policy: DisbursementControlPolicy(settings: controlSettings.first)
        )
    }

    private var filteredRows: [ReimbursementApprovalReportRow] {
        guard let issueFilter else { return report.exceptionRows }
        return report.exceptionRows.filter { row in row.issues.contains { $0.kind == issueFilter } }
    }

    var body: some View {
        List {
            Section {
                TroopReportHeader(
                    profile: troopProfiles.first,
                    reportTitle: "Reimbursement Approval & Audit Report",
                    subtitle: "Generated \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))"
                )
            }

            Section("Summary") {
                LabeledContent("Reimbursement requests", value: String(report.rows.count))
                LabeledContent("Requests with exceptions", value: String(report.exceptionRows.count))
                ForEach(ReimbursementApprovalIssueKind.allCases) { kind in
                    LabeledContent(kind.rawValue, value: String(report.exceptionCount(for: kind)))
                }
                LabeledContent("Dual-control checks", value: report.dualControlEnabled ? "Enabled" : "Disabled")
            }

            Section("Exception Filter") {
                Picker("Show", selection: $issueFilter) {
                    Text("All exceptions").tag(nil as ReimbursementApprovalIssueKind?)
                    ForEach(ReimbursementApprovalIssueKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind as ReimbursementApprovalIssueKind?)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Exceptions") {
                if filteredRows.isEmpty {
                    ContentUnavailableView(
                        "No Matching Exceptions",
                        systemImage: "checkmark.seal",
                        description: Text("No reimbursement requests match the selected exception category.")
                    )
                } else {
                    ForEach(filteredRows) { row in
                        if let request = requests.first(where: { $0.id == row.requestID }) {
                            NavigationLink {
                                ReimbursementDetailView(request: request)
                            } label: {
                                ReimbursementApprovalExceptionRow(row: row)
                            }
                        }
                    }
                }
            }

            Section("Approval and Audit Export") {
                Button("Export Approval & Audit CSV", systemImage: "square.and.arrow.up") {
                    prepareExport()
                }
                Text("The CSV includes every reimbursement request, its receipt and approval evidence, signer snapshots when enabled, linked-transaction information, exception details, and related audit-entry counts and dates.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Declined requests do not require receipts, signers, or payment links, but must retain decline review metadata. Submitted requests remain listed as awaiting approval. Approved requests remain listed until a matching payment transaction is linked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Approval Exceptions")
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: exportFilename
        ) { result in
            completeExport(result)
        }
        .alert("Approval Report", isPresented: Binding(
            get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } }
        )) { Button("OK") { exportMessage = nil } } message: { Text(exportMessage ?? "") }
    }

    private func prepareExport() {
        let generatedAt = Date()
        let exportReport = ReimbursementApprovalReportService.makeReport(
            requests: requests,
            attachments: attachments,
            transactions: transactions,
            people: people,
            auditEntries: auditEntries,
            policy: DisbursementControlPolicy(settings: controlSettings.first),
            generatedAt: generatedAt
        )
        exportDocument = ReimbursementApprovalCSVDocument(csv: ReimbursementApprovalReportService.csv(
            for: exportReport,
            troop: TroopReportIdentity(profile: troopProfiles.first)
        ))
        exportFilename = ReimbursementApprovalReportService.defaultFilename(at: generatedAt)
        showingExporter = true
    }

    private func completeExport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let exportedReport = report
            AuditLogger.record(
                .export,
                recordType: "Reimbursement Approval Report",
                recordID: nil,
                summary: "Exported reimbursement approval and audit report",
                details: AuditLogger.details([
                    ("File", url.lastPathComponent),
                    ("Requests", String(exportedReport.rows.count)),
                    ("Exceptions", String(exportedReport.exceptionRows.count)),
                    ("Dual-control checks", exportedReport.dualControlEnabled ? "Enabled" : "Disabled"),
                ]),
                in: modelContext
            )
            do {
                try modelContext.save()
                exportMessage = "Approval and audit report exported successfully."
            } catch {
                exportMessage = "The report was exported, but its audit entry could not be saved: \(error.localizedDescription)"
            }
        case .failure(let error):
            let nsError = error as NSError
            guard !(error is CancellationError), nsError.code != NSUserCancelledError else { return }
            exportMessage = "The report could not be exported: \(error.localizedDescription)"
        }
    }
}

private struct ReimbursementApprovalExceptionRow: View {
    let row: ReimbursementApprovalReportRow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(row.purpose).font(.headline)
                Spacer()
                MoneyText(cents: row.amountCents)
            }
            Text("\(row.requesterName) • \(row.status.rawValue) • \(row.submittedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(row.issues) { issue in
                Label(issue.message, systemImage: issue.kind.systemImage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("\(row.auditEntryCount) related audit entr\(row.auditEntryCount == 1 ? "y" : "ies")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}
