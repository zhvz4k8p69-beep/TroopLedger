import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ReimbursementApprovalIssueKind: String, CaseIterable, Identifiable, Hashable {
    case receipt = "Receipt"
    case approval = "Approval"
    case signer = "Signer Controls"
    case transaction = "Payment Link"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .receipt: "doc.text.magnifyingglass"
        case .approval: "checkmark.seal"
        case .signer: "person.2.badge.gearshape"
        case .transaction: "link.badge.plus"
        }
    }
}

struct ReimbursementApprovalIssue: Identifiable, Equatable {
    let kind: ReimbursementApprovalIssueKind
    let message: String
    var id: String { "\(kind.rawValue):\(message)" }
}

struct ReimbursementApprovalReportRow: Identifiable, Equatable {
    let requestID: UUID
    let requesterName: String
    let purpose: String
    let status: ReimbursementStatus
    let amountCents: Int64
    let submittedAt: Date
    let reviewedAt: Date?
    let reviewerName: String
    let approverName: String
    let signerOneName: String
    let signerTwoName: String
    let receiptCount: Int
    let linkedTransactionID: UUID?
    let auditEntryCount: Int
    let latestAuditAt: Date?
    let issues: [ReimbursementApprovalIssue]

    var id: UUID { requestID }
    var hasExceptions: Bool { !issues.isEmpty }
}

struct ReimbursementApprovalReport: Equatable {
    let generatedAt: Date
    let dualControlEnabled: Bool
    let rows: [ReimbursementApprovalReportRow]

    var exceptionRows: [ReimbursementApprovalReportRow] { rows.filter(\.hasExceptions) }

    func exceptionCount(for kind: ReimbursementApprovalIssueKind) -> Int {
        exceptionRows.filter { row in row.issues.contains { $0.kind == kind } }.count
    }
}

enum ReimbursementApprovalReportService {
    static func makeReport(
        requests: [ReimbursementRequest],
        attachments: [ReimbursementAttachment],
        transactions: [LedgerTransaction],
        people: [PersonRecord],
        auditEntries: [AuditLogEntry],
        policy: DisbursementControlPolicy,
        generatedAt: Date = Date()
    ) -> ReimbursementApprovalReport {
        let peopleByID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let transactionsByID = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let receiptCounts = Dictionary(grouping: attachments.compactMap { attachment in
            attachment.requestID.map { ($0, attachment) }
        }, by: \.0).mapValues(\.count)

        let rows = requests.sorted { $0.submittedAt > $1.submittedAt }.map { request in
            var issues: [ReimbursementApprovalIssue] = []
            let receiptCount = receiptCounts[request.id] ?? 0

            if request.status != .declined && receiptCount == 0 {
                issues.append(.init(kind: .receipt, message: "No receipt evidence is attached."))
            }

            switch request.status {
            case .submitted:
                issues.append(.init(kind: .approval, message: "Request is awaiting review or approval."))
            case .approved, .paid:
                if request.reviewerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || request.reviewedAt == nil {
                    issues.append(.init(kind: .approval, message: "Approval metadata is incomplete."))
                }
                if policy.isEnabled {
                    let controlAssessment = DisbursementControlEvaluator.assess(
                        approver: request.controlIdentity(for: .approver),
                        signerOne: request.controlIdentity(for: .signerOne),
                        signerTwo: request.controlIdentity(for: .signerTwo),
                        policy: policy,
                        requester: requesterIdentity(for: request, peopleByID: peopleByID)
                    )
                    for warning in controlAssessment.warnings {
                        let kind: ReimbursementApprovalIssueKind = warning.hasPrefix("No approver") || warning.hasPrefix("Approver") ? .approval : .signer
                        issues.append(.init(kind: kind, message: warning))
                    }
                }
            case .declined:
                if request.reviewerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || request.reviewedAt == nil {
                    issues.append(.init(kind: .approval, message: "Decline review metadata is incomplete."))
                }
            }

            if request.status == .approved && request.linkedTransactionID == nil {
                issues.append(.init(kind: .transaction, message: "Approved request has no linked payment transaction."))
            } else if request.status == .paid && request.linkedTransactionID == nil {
                issues.append(.init(kind: .transaction, message: "Paid request has no linked payment transaction."))
            } else if let transactionID = request.linkedTransactionID {
                guard let transaction = transactionsByID[transactionID] else {
                    issues.append(.init(kind: .transaction, message: "The linked payment transaction cannot be found."))
                    return makeRow(
                        request: request,
                        requesterName: requesterName(for: request, peopleByID: peopleByID),
                        receiptCount: receiptCount,
                        auditEntries: auditEntries,
                        issues: issues
                    )
                }
                if transaction.direction != .expense || transaction.amountCents != request.amountCents {
                    issues.append(.init(kind: .transaction, message: "The linked transaction is not an expense for the exact reimbursement amount."))
                }
                if request.status == .submitted || request.status == .declined {
                    issues.append(.init(kind: .transaction, message: "A non-payable request has a linked payment transaction."))
                }
                let calendar = Calendar.current
                if calendar.startOfDay(for: transaction.date) < calendar.startOfDay(for: request.purchaseDate) {
                    issues.append(.init(kind: .transaction, message: "The linked payment is dated before the purchase it reimburses."))
                }
            }

            return makeRow(
                request: request,
                requesterName: requesterName(for: request, peopleByID: peopleByID),
                receiptCount: receiptCount,
                auditEntries: auditEntries,
                issues: issues
            )
        }

        return ReimbursementApprovalReport(generatedAt: generatedAt, dualControlEnabled: policy.isEnabled, rows: rows)
    }

    static func csv(for report: ReimbursementApprovalReport, troop: TroopReportIdentity? = nil) -> String {
        let includesTroopIdentity = troop?.hasProfile == true
        let troopColumns = ["troop_name", "troop_number", "council", "district", "treasurer"]
        let reportColumns = [
            "request_id", "requester", "purpose", "status", "amount_cents", "submitted_at", "reviewed_at",
            "reviewer", "approver_snapshot", "signer_one_snapshot", "signer_two_snapshot", "receipt_count",
            "linked_transaction_id", "exception_kinds", "exception_details", "audit_entry_count", "latest_audit_at",
            "dual_control_enabled",
        ]
        let columns = includesTroopIdentity ? troopColumns + reportColumns : reportColumns
        let rows: [[String]] = report.rows.map { row -> [String] in
            let reportValues: [String] = [
                row.requestID.uuidString.lowercased(), row.requesterName, row.purpose, row.status.rawValue,
                String(row.amountCents), dateString(row.submittedAt), row.reviewedAt.map(dateString) ?? "",
                row.reviewerName, row.approverName, row.signerOneName, row.signerTwoName, String(row.receiptCount),
                row.linkedTransactionID?.uuidString.lowercased() ?? "",
                row.issues.map(\.kind.rawValue).joined(separator: " | "),
                row.issues.map(\.message).joined(separator: " | "),
                String(row.auditEntryCount), row.latestAuditAt.map(dateString) ?? "", String(report.dualControlEnabled),
            ]
            guard includesTroopIdentity, let troop else { return reportValues }
            let troopValues: [String] = [
                troop.formalName,
                troop.troopNumber,
                troop.council,
                troop.district,
                troop.treasurerName,
            ]
            return troopValues + reportValues
        }
        return ([columns] + rows).map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func defaultFilename(at date: Date = Date(), calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "TroopLedger Approval Audit %04d-%02d-%02d.csv", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func makeRow(
        request: ReimbursementRequest,
        requesterName: String,
        receiptCount: Int,
        auditEntries: [AuditLogEntry],
        issues: [ReimbursementApprovalIssue]
    ) -> ReimbursementApprovalReportRow {
        let requestID = request.id.uuidString
        let relatedAudit = auditEntries.filter { entry in
            entry.recordID == request.id || entry.details.localizedCaseInsensitiveContains(requestID)
        }
        return ReimbursementApprovalReportRow(
            requestID: request.id,
            requesterName: requesterName,
            purpose: request.purpose,
            status: request.status,
            amountCents: request.amountCents,
            submittedAt: request.submittedAt,
            reviewedAt: request.reviewedAt,
            reviewerName: request.reviewerName,
            approverName: request.approverNameSnapshot,
            signerOneName: request.signerOneNameSnapshot,
            signerTwoName: request.signerTwoNameSnapshot,
            receiptCount: receiptCount,
            linkedTransactionID: request.linkedTransactionID,
            auditEntryCount: relatedAudit.count,
            latestAuditAt: relatedAudit.map(\.timestamp).max(),
            issues: issues
        )
    }

    private static func requesterName(for request: ReimbursementRequest, peopleByID: [UUID: PersonRecord]) -> String {
        request.requesterPersonID.flatMap { peopleByID[$0]?.displayName } ?? "Unknown requester"
    }

    private static func requesterIdentity(for request: ReimbursementRequest, peopleByID: [UUID: PersonRecord]) -> DisbursementControlIdentity? {
        guard let requesterID = request.requesterPersonID else { return nil }
        return DisbursementControlIdentity(personID: requesterID, name: peopleByID[requesterID]?.displayName ?? "", household: "")
    }

    private static func dateString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func csvField(_ value: String) -> String {
        CSVFormatting.field(value)
    }
}

struct ReimbursementApprovalCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let data: Data

    init(csv: String) {
        data = Data(csv.utf8)
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
