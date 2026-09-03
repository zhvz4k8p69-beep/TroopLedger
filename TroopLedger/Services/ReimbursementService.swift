import CryptoKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

struct DisbursementControlIdentity: Equatable {
    var personID: UUID?
    var name: String
    var household: String

    static let empty = DisbursementControlIdentity(personID: nil, name: "", household: "")

    var normalized: Self {
        Self(
            personID: personID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            household: household.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var isRecorded: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct DisbursementControlPolicy: Equatable {
    var isEnabled = true
    var expectApprover = true
    var expectedSignerCount = 2
    var warnSamePerson = true
    var warnSameHousehold = true
    var warnMissingHousehold = true

    init(
        isEnabled: Bool = true,
        expectApprover: Bool = true,
        expectedSignerCount: Int = 2,
        warnSamePerson: Bool = true,
        warnSameHousehold: Bool = true,
        warnMissingHousehold: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.expectApprover = expectApprover
        self.expectedSignerCount = min(max(expectedSignerCount, 0), 2)
        self.warnSamePerson = warnSamePerson
        self.warnSameHousehold = warnSameHousehold
        self.warnMissingHousehold = warnMissingHousehold
    }

    init(settings: DisbursementControlSettings?) {
        self.init(
            isEnabled: settings?.isEnabled ?? true,
            expectApprover: settings?.expectApprover ?? true,
            expectedSignerCount: settings?.expectedSignerCount ?? 2,
            warnSamePerson: settings?.warnSamePerson ?? true,
            warnSameHousehold: settings?.warnSameHousehold ?? true,
            warnMissingHousehold: settings?.warnMissingHousehold ?? true
        )
    }
}

struct DisbursementControlAssessment: Equatable {
    let warnings: [String]
    var hasWarnings: Bool { !warnings.isEmpty }
}

enum DisbursementControlEvaluator {
    static func assess(
        approver: DisbursementControlIdentity,
        signerOne: DisbursementControlIdentity,
        signerTwo: DisbursementControlIdentity,
        policy: DisbursementControlPolicy,
        requester: DisbursementControlIdentity? = nil
    ) -> DisbursementControlAssessment {
        guard policy.isEnabled else { return DisbursementControlAssessment(warnings: []) }
        let roles = [
            ("Approver", approver.normalized),
            ("Signer 1", signerOne.normalized),
            ("Signer 2", signerTwo.normalized),
        ]
        var warnings: [String] = []
        if policy.expectApprover && !approver.isRecorded {
            warnings.append("No approver is recorded.")
        }
        let recordedSigners = [signerOne, signerTwo].filter(\.isRecorded).count
        if recordedSigners < policy.expectedSignerCount {
            warnings.append("Policy expects \(policy.expectedSignerCount) signer\(policy.expectedSignerCount == 1 ? "" : "s"); \(recordedSigners) \(recordedSigners == 1 ? "is" : "are") recorded.")
        }
        let recordedRoles = roles.filter { $0.1.isRecorded }
        // The person being reimbursed must never be their own approver or check signer. Segregation from the
        // requester is the primary purpose of dual control, so it is checked before the role-to-role comparisons.
        if let requester = requester?.normalized {
            for role in recordedRoles {
                let sameID = requester.personID != nil && role.1.personID == requester.personID
                let sameName = role.1.personID == nil && !requester.name.isEmpty
                    && normalizedComparison(role.1.name) == normalizedComparison(requester.name)
                if policy.warnSamePerson, sameID || sameName {
                    warnings.append("\(role.0) is the person requesting this reimbursement.")
                } else if policy.warnSameHousehold, !requester.household.isEmpty,
                          normalizedComparison(role.1.household) == normalizedComparison(requester.household) {
                    warnings.append("\(role.0) shares the requester's household label.")
                }
            }
        }
        if policy.warnSamePerson {
            for leftIndex in recordedRoles.indices {
                for rightIndex in recordedRoles.indices where rightIndex > leftIndex {
                    let left = recordedRoles[leftIndex]
                    let right = recordedRoles[rightIndex]
                    let sameID = left.1.personID != nil && left.1.personID == right.1.personID
                    let sameName = left.1.personID == nil && right.1.personID == nil
                        && normalizedComparison(left.1.name) == normalizedComparison(right.1.name)
                    if sameID || sameName {
                        warnings.append("\(left.0) and \(right.0) may be the same person.")
                    }
                }
            }
        }
        if policy.warnSameHousehold {
            for leftIndex in recordedRoles.indices {
                for rightIndex in recordedRoles.indices where rightIndex > leftIndex {
                    let left = recordedRoles[leftIndex]
                    let right = recordedRoles[rightIndex]
                    let leftHousehold = normalizedComparison(left.1.household)
                    let rightHousehold = normalizedComparison(right.1.household)
                    guard !leftHousehold.isEmpty, leftHousehold == rightHousehold else { continue }
                    let definitelySamePerson = left.1.personID != nil && left.1.personID == right.1.personID
                    if !definitelySamePerson {
                        warnings.append("\(left.0) and \(right.0) have the same household label.")
                    }
                }
            }
        }
        if policy.warnMissingHousehold {
            for role in recordedRoles where role.1.household.isEmpty {
                warnings.append("\(role.0) has no household label.")
            }
        }
        return DisbursementControlAssessment(warnings: warnings)
    }

    private static func normalizedComparison(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

enum ReimbursementError: LocalizedError, Equatable {
    case requesterRequired
    case purposeRequired
    case categoryRequired
    case invalidAmount
    case requestNotSubmitted
    case requestNotApproved
    case reviewerRequired
    case declineReasonRequired
    case receiptTypeUnsupported
    case receiptTooLarge
    case duplicateReceipt
    case receiptNotEditable
    case attachmentRequestMismatch
    case accountRequired
    case transactionNotFound
    case transactionMismatch
    case transferTransaction
    case transactionAlreadyLinked
    case paymentDateLocked(Date)
    case paymentDateInFuture
    case selfApproval
    case transactionBelongsToAnotherPerson
    case requestNotReopenable
    case reopenReasonRequired
    case receiptJustificationRequired

    var errorDescription: String? {
        switch self {
        case .requesterRequired: "Choose the person requesting reimbursement."
        case .purposeRequired: "Enter the business purpose for the reimbursement."
        case .categoryRequired: "Choose or enter an expense category."
        case .invalidAmount: "Enter a reimbursement amount greater than zero."
        case .requestNotSubmitted: "Only a submitted request can be reviewed."
        case .requestNotApproved: "Only an approved request can be recorded as paid."
        case .reviewerRequired: "Record the name of the person who reviewed this request."
        case .declineReasonRequired: "Explain why the request was declined."
        case .receiptTypeUnsupported: "Attach a PDF or image receipt."
        case .receiptTooLarge: "Each receipt must be 15 MB or smaller."
        case .duplicateReceipt: "That exact receipt is already attached to this request."
        case .receiptNotEditable: "Receipts cannot be changed after a request has been reviewed."
        case .attachmentRequestMismatch: "The selected receipt does not belong to this reimbursement request."
        case .accountRequired: "Choose the account used to pay this reimbursement."
        case .transactionNotFound: "The selected ledger transaction no longer exists."
        case .transactionMismatch: "The linked ledger entry must be an expense for the exact reimbursement amount."
        case .transferTransaction: "Account-transfer entries cannot be used as reimbursement payments."
        case .transactionAlreadyLinked: "That ledger transaction is already linked to another reimbursement request."
        case .paymentDateLocked(let date): "The selected account is locked through \(date.formatted(date: .long, time: .omitted)). Choose a later payment date."
        case .paymentDateInFuture: "A reimbursement payment cannot be dated in the future. Record it on the day the check or transfer is issued."
        case .selfApproval: "The person requesting a reimbursement cannot record its approval. Choose a different approver."
        case .transactionBelongsToAnotherPerson: "That ledger entry is linked to a different person and cannot pay this request."
        case .requestNotReopenable: "Only an approved-but-unpaid or declined request can be returned for review."
        case .reopenReasonRequired: "Explain why this decision is being reopened."
        case .receiptJustificationRequired: "No receipt is attached. Approve only after recording in the review notes why the request is acceptable without one."
        }
    }
}

@MainActor
enum ReimbursementService {
    static let maximumAttachmentBytes = 15 * 1_024 * 1_024

    static func validate(requesterPersonID: UUID?, purpose: String, category: String, amountCents: Int64?) throws {
        guard requesterPersonID != nil else { throw ReimbursementError.requesterRequired }
        guard !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReimbursementError.purposeRequired }
        guard !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReimbursementError.categoryRequired }
        guard let amountCents, amountCents > 0 else { throw ReimbursementError.invalidAmount }
    }

    @discardableResult
    static func addAttachment(
        to request: ReimbursementRequest,
        data: Data,
        filename: String,
        mediaType suppliedMediaType: String? = nil,
        in modelContext: ModelContext
    ) throws -> ReimbursementAttachment {
        guard request.status == .submitted else { throw ReimbursementError.receiptNotEditable }
        guard data.count <= maximumAttachmentBytes else { throw ReimbursementError.receiptTooLarge }
        let declaredMediaType = suppliedMediaType ?? UTType(filenameExtension: (filename as NSString).pathExtension)?.preferredMIMEType
        guard let declaredMediaType, declaredMediaType == UTType.pdf.preferredMIMEType || declaredMediaType.hasPrefix("image/") else {
            throw ReimbursementError.receiptTypeUnsupported
        }
        // The declared type comes from a filename extension or picker metadata; the bytes decide what is stored.
        // This rejects renamed files and scriptable formats such as SVG that merely claim to be an image.
        guard let mediaType = sniffedMediaType(data),
              (declaredMediaType == "application/pdf") == (mediaType == "application/pdf") else {
            throw ReimbursementError.receiptTypeUnsupported
        }
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let existing = try modelContext.fetch(FetchDescriptor<ReimbursementAttachment>())
        guard !existing.contains(where: { $0.requestID == request.id && $0.sha256 == fingerprint }) else {
            throw ReimbursementError.duplicateReceipt
        }
        let cleanName = sanitizedFilename(filename, fallbackExtension: mediaType == "application/pdf" ? "pdf" : "jpg")
        let attachment = ReimbursementAttachment(
            requestID: request.id,
            filename: cleanName,
            mediaType: mediaType,
            byteCount: Int64(data.count),
            sha256: fingerprint,
            data: data
        )
        modelContext.insert(attachment)
        request.modifiedAt = Date()
        AuditLogger.record(
            .create,
            recordType: "Reimbursement Attachment",
            recordID: attachment.id,
            summary: "Attached receipt to reimbursement",
            details: AuditLogger.details([
                ("Request ID", request.id.uuidString),
                ("Filename", cleanName),
                ("Media type", mediaType),
                ("Bytes", String(data.count)),
                ("SHA-256", fingerprint),
            ]),
            in: modelContext
        )
        try modelContext.save()
        return attachment
    }

    static func removeAttachment(_ attachment: ReimbursementAttachment, from request: ReimbursementRequest, in modelContext: ModelContext) throws {
        guard request.status == .submitted else { throw ReimbursementError.receiptNotEditable }
        guard attachment.requestID == request.id else { throw ReimbursementError.attachmentRequestMismatch }
        AuditLogger.record(
            .delete,
            recordType: "Reimbursement Attachment",
            recordID: attachment.id,
            summary: "Removed receipt from reimbursement",
            // Record the fingerprint of the evidence that was removed, not only its name, so a later
            // reviewer can tell exactly which file left the request.
            details: AuditLogger.details([
                ("Request ID", request.id.uuidString),
                ("Filename", attachment.filename),
                ("Media type", attachment.mediaType),
                ("Bytes", String(attachment.byteCount)),
                ("SHA-256", attachment.sha256),
            ]),
            in: modelContext
        )
        modelContext.delete(attachment)
        request.modifiedAt = Date()
        try modelContext.save()
    }

    static func review(
        _ request: ReimbursementRequest,
        approve: Bool,
        reviewerName: String,
        notes: String,
        approver: DisbursementControlIdentity? = nil,
        at date: Date = Date(),
        in modelContext: ModelContext
    ) throws {
        guard request.status == .submitted else { throw ReimbursementError.requestNotSubmitted }
        let reviewer = reviewerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reviewer.isEmpty else { throw ReimbursementError.reviewerRequired }
        if !approve && reason.isEmpty { throw ReimbursementError.declineReasonRequired }
        // Advisory warnings cover look-alike names; a definitive roster match is refused outright.
        if approve, let approverID = approver?.personID, approverID == request.requesterPersonID {
            throw ReimbursementError.selfApproval
        }
        // Approval without evidence is sometimes legitimate (a lost receipt for a small purchase), but the
        // reason must be written down at the moment of approval, not reconstructed later.
        if approve, reason.isEmpty {
            let attachments = try modelContext.fetch(FetchDescriptor<ReimbursementAttachment>())
            if !attachments.contains(where: { $0.requestID == request.id }) {
                throw ReimbursementError.receiptJustificationRequired
            }
        }
        request.status = approve ? .approved : .declined
        request.reviewerName = reviewer
        request.reviewNotes = reason
        request.reviewedAt = date
        if let approver {
            apply(approver.normalized, to: request, role: .approver)
            request.disbursementControlRecordedAt = date
        }
        request.modifiedAt = date
        AuditLogger.record(
            .edit,
            recordType: "Reimbursement Request",
            recordID: request.id,
            summary: approve ? "Approved reimbursement request" : "Declined reimbursement request",
            details: AuditLogger.details([
                ("Reviewer", reviewer),
                ("Amount", Money.currency(cents: request.amountCents)),
                ("Review notes", reason),
            ]),
            at: date,
            in: modelContext
        )
        try modelContext.save()
    }

    static func saveDisbursementControls(
        for request: ReimbursementRequest,
        approver: DisbursementControlIdentity,
        signerOne: DisbursementControlIdentity,
        signerTwo: DisbursementControlIdentity,
        notes: String,
        at date: Date = Date(),
        in modelContext: ModelContext
    ) throws {
        // Evidence can be re-recorded; the audit trail must keep the identities it replaced.
        let before = controlSnapshot(request)
        apply(approver.normalized, to: request, role: .approver)
        apply(signerOne.normalized, to: request, role: .signerOne)
        apply(signerTwo.normalized, to: request, role: .signerTwo)
        request.disbursementControlNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        request.disbursementControlRecordedAt = date
        request.modifiedAt = date
        AuditLogger.record(
            .edit,
            recordType: "Reimbursement Request",
            recordID: request.id,
            summary: "Recorded disbursement control evidence",
            details: AuditLogger.details([
                ("Approver", request.approverNameSnapshot),
                ("Signer 1", request.signerOneNameSnapshot),
                ("Signer 2", request.signerTwoNameSnapshot),
                ("Notes", request.disbursementControlNotes),
            ] + AuditLogger.changes(from: before, to: controlSnapshot(request))),
            at: date,
            in: modelContext
        )
        try modelContext.save()
    }

    static func assessment(
        for request: ReimbursementRequest,
        policy: DisbursementControlPolicy,
        requester: DisbursementControlIdentity? = nil
    ) -> DisbursementControlAssessment {
        DisbursementControlEvaluator.assess(
            approver: request.controlIdentity(for: .approver),
            signerOne: request.controlIdentity(for: .signerOne),
            signerTwo: request.controlIdentity(for: .signerTwo),
            policy: policy,
            requester: requester
        )
    }

    @discardableResult
    static func createAndLinkPayment(
        for request: ReimbursementRequest,
        accountID: UUID?,
        paymentDate: Date,
        reference: String,
        payee: String,
        reconciliations: [ReconciliationRecord],
        calendar: Calendar = .current,
        now: Date = Date(),
        in modelContext: ModelContext
    ) throws -> LedgerTransaction {
        guard request.status == .approved else { throw ReimbursementError.requestNotApproved }
        guard request.linkedTransactionID == nil else { throw ReimbursementError.transactionAlreadyLinked }
        guard calendar.startOfDay(for: paymentDate) <= calendar.startOfDay(for: now) else { throw ReimbursementError.paymentDateInFuture }
        guard let accountID,
              try modelContext.fetch(FetchDescriptor<AccountRecord>()).contains(where: { $0.id == accountID && $0.isActive }) else {
            throw ReimbursementError.accountRequired
        }
        switch PeriodLocking.validatePosting(
            accountID: accountID,
            date: paymentDate,
            isAdjustment: false,
            adjustsTransactionID: nil,
            adjustmentReason: "",
            reconciliations: reconciliations,
            calendar: calendar
        ) {
        case .valid: break
        case .locked(let lockDate): throw ReimbursementError.paymentDateLocked(lockDate)
        default: throw ReimbursementError.accountRequired
        }

        let transaction = LedgerTransaction(
            accountID: accountID,
            date: paymentDate,
            direction: .expense,
            amountCents: request.amountCents,
            payee: payee,
            category: request.category
        )
        transaction.checkNumber = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        transaction.personID = request.requesterPersonID
        transaction.eventID = request.eventID
        transaction.memo = "Reimbursement: \(request.purpose)"
        modelContext.insert(transaction)
        AuditLogger.record(
            .create,
            recordType: "Transaction",
            recordID: transaction.id,
            summary: "Created reimbursement payment transaction",
            details: AuditLogger.details([
                ("Request ID", request.id.uuidString),
                ("Amount", Money.currency(cents: request.amountCents)),
                ("Category", request.category),
            ]),
            in: modelContext
        )
        try finishPayment(request, transaction: transaction, paymentDate: paymentDate, reference: reference, in: modelContext)
        return transaction
    }

    static func linkExistingPayment(
        for request: ReimbursementRequest,
        transactionID: UUID?,
        in modelContext: ModelContext
    ) throws {
        guard request.status == .approved else { throw ReimbursementError.requestNotApproved }
        guard request.linkedTransactionID == nil else { throw ReimbursementError.transactionAlreadyLinked }
        guard let transactionID,
              let transaction = try modelContext.fetch(FetchDescriptor<LedgerTransaction>()).first(where: { $0.id == transactionID }) else {
            throw ReimbursementError.transactionNotFound
        }
        guard transaction.direction == .expense, transaction.amountCents == request.amountCents else {
            throw ReimbursementError.transactionMismatch
        }
        guard !transaction.isTransfer else { throw ReimbursementError.transferTransaction }
        if let personID = transaction.personID, personID != request.requesterPersonID {
            throw ReimbursementError.transactionBelongsToAnotherPerson
        }
        let requests = try modelContext.fetch(FetchDescriptor<ReimbursementRequest>())
        guard !requests.contains(where: { $0.id != request.id && $0.linkedTransactionID == transaction.id }) else {
            throw ReimbursementError.transactionAlreadyLinked
        }
        try finishPayment(
            request,
            transaction: transaction,
            paymentDate: transaction.date,
            reference: transaction.checkNumber,
            in: modelContext
        )
    }

    /// Returns an approved-but-unpaid or declined request to the review queue so a mistaken decision can be
    /// corrected without deleting history. The previous decision stays in the audit log.
    static func reopen(_ request: ReimbursementRequest, reason: String, at date: Date = Date(), in modelContext: ModelContext) throws {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else { throw ReimbursementError.reopenReasonRequired }
        guard request.status == .declined || (request.status == .approved && request.linkedTransactionID == nil) else {
            throw ReimbursementError.requestNotReopenable
        }
        let previousStatus = request.status
        let previousReviewer = request.reviewerName
        let previousNotes = request.reviewNotes
        request.status = .submitted
        request.reviewerName = ""
        request.reviewNotes = ""
        request.reviewedAt = nil
        request.modifiedAt = date
        AuditLogger.record(
            .edit,
            recordType: "Reimbursement Request",
            recordID: request.id,
            summary: "Reopened \(previousStatus.rawValue.lowercased()) reimbursement request for review",
            details: AuditLogger.details([
                ("Previous decision", previousStatus.rawValue),
                ("Previous reviewer", previousReviewer),
                ("Previous review notes", previousNotes),
                ("Reason for reopening", trimmedReason),
            ]),
            at: date,
            in: modelContext
        )
        try modelContext.save()
    }

    private static func finishPayment(
        _ request: ReimbursementRequest,
        transaction: LedgerTransaction,
        paymentDate: Date,
        reference: String,
        in modelContext: ModelContext
    ) throws {
        request.status = .paid
        request.paymentDate = paymentDate
        request.paymentReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        request.linkedTransactionID = transaction.id
        request.modifiedAt = Date()
        AuditLogger.record(
            .edit,
            recordType: "Reimbursement Request",
            recordID: request.id,
            summary: "Recorded reimbursement as paid",
            details: AuditLogger.details([
                ("Transaction ID", transaction.id.uuidString),
                ("Payment date", paymentDate.formatted(date: .numeric, time: .omitted)),
                ("Reference", request.paymentReference),
            ]),
            in: modelContext
        )
        try modelContext.save()
    }

    /// Identifies a receipt by its leading bytes. Only raster image formats and PDF are accepted.
    static func sniffedMediaType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        func starts(with signature: [UInt8]) -> Bool { bytes.count >= signature.count && Array(bytes[..<signature.count]) == signature }
        if starts(with: [0x25, 0x50, 0x44, 0x46]) { return "application/pdf" }               // %PDF
        if starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }                     // \x89PNG
        if starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }                     // GIF8
        if starts(with: [0x49, 0x49, 0x2A, 0x00]) || starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "image/tiff" }
        if bytes.count >= 12, Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46], Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        if bytes.count >= 12, Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] {              // ....ftyp (HEIF family)
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            if ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "heim", "heis", "avif"].contains(brand) {
                return brand == "avif" ? "image/avif" : "image/heic"
            }
        }
        if bytes.count >= 14, starts(with: [0x42, 0x4D]) { return "image/bmp" }
        return nil
    }

    private static func sanitizedFilename(_ filename: String, fallbackExtension: String) -> String {
        let lastComponent = (filename as NSString).lastPathComponent
        let cleaned = lastComponent.map { character in
            character.isLetter || character.isNumber || "._- ".contains(character) ? character : "_"
        }
        let result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "receipt.\(fallbackExtension)" : result
    }

    private static func controlSnapshot(_ request: ReimbursementRequest) -> [(String, String)] {
        func describe(_ identity: DisbursementControlIdentity) -> String {
            [identity.name, identity.household, identity.personID?.uuidString ?? ""].filter { !$0.isEmpty }.joined(separator: " / ")
        }
        return [
            ("Approver", describe(request.controlIdentity(for: .approver))),
            ("Signer 1", describe(request.controlIdentity(for: .signerOne))),
            ("Signer 2", describe(request.controlIdentity(for: .signerTwo))),
            ("Control notes", request.disbursementControlNotes),
        ]
    }

    private static func apply(_ identity: DisbursementControlIdentity, to request: ReimbursementRequest, role: DisbursementControlRole) {
        switch role {
        case .approver:
            request.approverPersonID = identity.personID
            request.approverNameSnapshot = identity.name
            request.approverHouseholdSnapshot = identity.household
        case .signerOne:
            request.signerOnePersonID = identity.personID
            request.signerOneNameSnapshot = identity.name
            request.signerOneHouseholdSnapshot = identity.household
        case .signerTwo:
            request.signerTwoPersonID = identity.personID
            request.signerTwoNameSnapshot = identity.name
            request.signerTwoHouseholdSnapshot = identity.household
        }
    }
}

enum DisbursementControlRole {
    case approver
    case signerOne
    case signerTwo
}

extension ReimbursementRequest {
    func controlIdentity(for role: DisbursementControlRole) -> DisbursementControlIdentity {
        switch role {
        case .approver:
            DisbursementControlIdentity(personID: approverPersonID, name: approverNameSnapshot, household: approverHouseholdSnapshot)
        case .signerOne:
            DisbursementControlIdentity(personID: signerOnePersonID, name: signerOneNameSnapshot, household: signerOneHouseholdSnapshot)
        case .signerTwo:
            DisbursementControlIdentity(personID: signerTwoPersonID, name: signerTwoNameSnapshot, household: signerTwoHouseholdSnapshot)
        }
    }
}
