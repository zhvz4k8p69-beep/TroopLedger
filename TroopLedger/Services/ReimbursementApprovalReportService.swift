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
        families: [FamilyRecord] = [],
        auditEntries: [AuditLogEntry],
        policy: DisbursementControlPolicy,
        generatedAt: Date = Date()
    ) -> ReimbursementApprovalReport {
        let peopleByID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let familyNamesByID = Dictionary(families.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        // Indexed once: the per-request audit scan used to walk the whole log with a locale-aware substring
        // search for every request, and the view evaluates this report several times per render.
        let auditByRecordID = Dictionary(grouping: auditEntries.filter { $0.recordID != nil }, by: { $0.recordID! })
        let auditMentions = auditEntries.map { (entry: $0, details: $0.details.lowercased()) }
        let transactionsByID = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let receiptCounts = Dictionary(grouping: attachments.compactMap { attachment in
            attachment.requestID.map { ($0, attachment) }
        }, by: \.0).mapValues(\.count)

        // Tiebreak on id so two requests entered in the same second export in a stable order; otherwise two
        // runs over the same data produce different CSV bytes and different package manifest hashes.
        let sortedRequests = requests.sorted { left, right in
            if left.submittedAt != right.submittedAt { return left.submittedAt > right.submittedAt }
            return left.id.uuidString < right.id.uuidString
        }
        let rows = sortedRequests.map { request -> ReimbursementApprovalReportRow in
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
                        requester: requesterIdentity(for: request, peopleByID: peopleByID, familyNamesByID: familyNamesByID)
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
                if let reviewedAt = request.reviewedAt, let days = Calendar.current.dateComponents([.day], from: reviewedAt, to: generatedAt).day, days > 30 {
                    issues.append(.init(kind: .transaction, message: "Approved \(days) days ago and still unpaid."))
                }
            } else if request.status == .paid && request.linkedTransactionID == nil {
                issues.append(.init(kind: .transaction, message: "Paid request has no linked payment transaction."))
            } else if let transactionID = request.linkedTransactionID {
                guard let transaction = transactionsByID[transactionID] else {
                    issues.append(.init(kind: .transaction, message: "The linked payment transaction cannot be found."))
                    return makeRow(
                        request: request,
                        requesterName: requesterName(for: request, peopleByID: peopleByID),
                        receiptCount: receiptCount,
                        auditByRecordID: auditByRecordID,
                        auditMentions: auditMentions,
                        issues: issues
                    )
                }
                if transaction.direction != .expense || transaction.amountCents != request.amountCents {
                    issues.append(.init(kind: .transaction, message: "The linked transaction is not an expense for the exact reimbursement amount."))
                }
                if request.status == .submitted || request.status == .declined {
                    issues.append(.init(kind: .transaction, message: "A non-payable request has a linked payment transaction."))
                }
                if let personID = transaction.personID, personID != request.requesterPersonID {
                    issues.append(.init(kind: .transaction, message: "The linked payment is attributed to a different person than the requester."))
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
                auditByRecordID: auditByRecordID,
                auditMentions: auditMentions,
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
        auditByRecordID: [UUID: [AuditLogEntry]],
        auditMentions: [(entry: AuditLogEntry, details: String)],
        issues: [ReimbursementApprovalIssue]
    ) -> ReimbursementApprovalReportRow {
        let requestID = request.id
        let needle = requestID.uuidString.lowercased()
        let relatedAudit = (auditByRecordID[requestID] ?? [])
            + auditMentions.filter { $0.entry.recordID != requestID && $0.details.contains(needle) }.map(\.entry)
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

    private static func requesterIdentity(
        for request: ReimbursementRequest,
        peopleByID: [UUID: PersonRecord],
        familyNamesByID: [UUID: String]
    ) -> DisbursementControlIdentity? {
        guard let requesterID = request.requesterPersonID else { return nil }
        // The live disbursement-control screen compares households by family name; the exported report must
        // evaluate the same rule or the audit package omits the very conflict the screen warns about.
        let person = peopleByID[requesterID]
        let household = person?.familyID.flatMap { familyNamesByID[$0] } ?? ""
        return DisbursementControlIdentity(personID: requesterID, name: person?.displayName ?? "", household: household)
    }

    private static func dateString(_ date: Date) -> String {
        date.formatted(.iso8601)
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
