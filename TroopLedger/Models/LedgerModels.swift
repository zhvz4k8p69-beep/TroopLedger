import Foundation
import SwiftData

enum AccountKind: String, CaseIterable, Identifiable, Codable {
    case checking = "Checking"
    case savings = "Savings"
    case cash = "Cash on Hand"
    case undepositedFunds = "Undeposited Funds"
    case other = "Other"

    var id: String { rawValue }
}

enum TransactionDirection: String, CaseIterable, Identifiable, Codable {
    case income = "Income"
    case expense = "Expense"

    var id: String { rawValue }
}

enum BudgetStatus: String, CaseIterable, Identifiable, Codable {
    case working = "Working"
    case approved = "Approved"

    var id: String { rawValue }
}

enum ReimbursementStatus: String, CaseIterable, Identifiable, Codable {
    case submitted = "Submitted"
    case approved = "Approved"
    case declined = "Declined"
    case paid = "Paid"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .submitted: "clock.badge.questionmark"
        case .approved: "checkmark.seal"
        case .declined: "xmark.seal"
        case .paid: "checkmark.circle.fill"
        }
    }
}

enum PersonRole: String, CaseIterable, Identifiable, Codable {
    case scout = "Scout"
    case leader = "Leader"
    case parent = "Parent/Guardian"
    case other = "Other"

    var id: String { rawValue }
}

enum ScoutsBSARank: String, CaseIterable, Identifiable, Codable {
    case none = "none"
    case scout = "scout"
    case tenderfoot = "tenderfoot"
    case secondClass = "secondClass"
    case firstClass = "firstClass"
    case star = "star"
    case life = "life"
    case eagle = "eagle"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "No rank recorded"
        case .scout: "Scout"
        case .tenderfoot: "Tenderfoot"
        case .secondClass: "Second Class"
        case .firstClass: "First Class"
        case .star: "Star"
        case .life: "Life"
        case .eagle: "Eagle"
        }
    }

    static func matching(_ value: String) -> ScoutsBSARank? {
        var normalized = value.normalizedScoutingLabel
        guard !normalized.isEmpty else { return nil }
        if let alias = aliases[normalized] { return alias }
        // Scoutbook exports write "Life Scout" and "Eagle Scout"; drop the suffix but leave a bare "Scout" alone.
        let scoutSuffix = "scout"
        if normalized.count > scoutSuffix.count, normalized.hasSuffix(scoutSuffix) {
            normalized.removeLast(scoutSuffix.count)
        }
        return allCases.first { $0 != .none && $0.displayName.normalizedScoutingLabel == normalized }
    }

    private static let aliases: [String: ScoutsBSARank] = [
        "1stclass": .firstClass,
        "2ndclass": .secondClass,
        "1stclassscout": .firstClass,
        "2ndclassscout": .secondClass,
    ]
}

enum TroopPositionCategory: String, CaseIterable, Identifiable, Codable {
    case youth = "Youth leadership"
    case adult = "Adult leadership and committee"

    var id: String { rawValue }
}

enum TroopPosition: String, CaseIterable, Identifiable, Codable {
    // Youth troop positions
    case seniorPatrolLeader
    case assistantSeniorPatrolLeader
    case patrolLeader
    case assistantPatrolLeader
    case troopGuide
    case quartermaster
    case scribe
    case denChief
    case chaplainAide
    case historian
    case instructor
    case librarian
    case webmaster
    case bugler
    case orderOfTheArrowRepresentative
    case outdoorEthicsGuide
    case juniorAssistantScoutmaster

    // Adult troop and committee positions
    case scoutmaster
    case assistantScoutmaster
    case committeeChair
    case committeeMember
    case charteredOrganizationRepresentative
    case secretary
    case treasurer
    case outdoorActivitiesCoordinator
    case advancementCoordinator
    case chaplain
    case trainingCoordinator
    case equipmentCoordinator
    case membershipCoordinator

    var id: String { rawValue }

    var category: TroopPositionCategory {
        switch self {
        case .seniorPatrolLeader, .assistantSeniorPatrolLeader, .patrolLeader, .assistantPatrolLeader,
             .troopGuide, .quartermaster, .scribe, .denChief, .chaplainAide, .historian, .instructor,
             .librarian, .webmaster, .bugler, .orderOfTheArrowRepresentative, .outdoorEthicsGuide,
             .juniorAssistantScoutmaster:
            .youth
        default:
            .adult
        }
    }

    var displayName: String {
        switch self {
        case .seniorPatrolLeader: "Senior Patrol Leader"
        case .assistantSeniorPatrolLeader: "Assistant Senior Patrol Leader"
        case .patrolLeader: "Patrol Leader"
        case .assistantPatrolLeader: "Assistant Patrol Leader"
        case .troopGuide: "Troop Guide"
        case .quartermaster: "Quartermaster"
        case .scribe: "Scribe"
        case .denChief: "Den Chief"
        case .chaplainAide: "Chaplain Aide"
        case .historian: "Historian"
        case .instructor: "Instructor"
        case .librarian: "Librarian"
        case .webmaster: "Webmaster"
        case .bugler: "Bugler"
        case .orderOfTheArrowRepresentative: "Order of the Arrow Representative"
        case .outdoorEthicsGuide: "Outdoor Ethics Guide"
        case .juniorAssistantScoutmaster: "Junior Assistant Scoutmaster"
        case .scoutmaster: "Scoutmaster"
        case .assistantScoutmaster: "Assistant Scoutmaster"
        case .committeeChair: "Committee Chair"
        case .committeeMember: "Committee Member"
        case .charteredOrganizationRepresentative: "Chartered Organization Representative"
        case .secretary: "Secretary"
        case .treasurer: "Treasurer"
        case .outdoorActivitiesCoordinator: "Outdoor Activities Coordinator"
        case .advancementCoordinator: "Advancement Coordinator"
        case .chaplain: "Chaplain"
        case .trainingCoordinator: "Training Coordinator"
        case .equipmentCoordinator: "Equipment Coordinator"
        case .membershipCoordinator: "Membership Coordinator"
        }
    }

    /// The current Scouts BSA advancement requirement does not count Assistant Patrol Leader or Bugler.
    var fulfillsYouthPositionOfResponsibility: Bool {
        category == .youth && self != .assistantPatrolLeader && self != .bugler
    }

    static func matching(_ value: String) -> TroopPosition? {
        let normalized = value.normalizedScoutingLabel
        guard !normalized.isEmpty else { return nil }
        if let exact = allCases.first(where: { $0.displayName.normalizedScoutingLabel == normalized }) {
            return exact
        }
        if let alias = aliases[normalized] { return alias }
        return allCases
            .sorted { $0.displayName.count > $1.displayName.count }
            .first { normalized.contains($0.displayName.normalizedScoutingLabel) }
    }

    private static let aliases: [String: TroopPosition] = [
        "spl": .seniorPatrolLeader,
        "aspl": .assistantSeniorPatrolLeader,
        "pl": .patrolLeader,
        "apl": .assistantPatrolLeader,
        "oarepresentative": .orderOfTheArrowRepresentative,
        "oatrooprepresentative": .orderOfTheArrowRepresentative,
        "jasm": .juniorAssistantScoutmaster,
        "sm": .scoutmaster,
        "asm": .assistantScoutmaster,
        "committee chairman": .committeeChair,
        "committee chairperson": .committeeChair,
        "cc": .committeeChair,
        "chartered organization rep": .charteredOrganizationRepresentative,
        "charter organization representative": .charteredOrganizationRepresentative,
        "cor": .charteredOrganizationRepresentative,
        "outdoor activities chair": .outdoorActivitiesCoordinator,
        "advancement chair": .advancementCoordinator,
        "training chair": .trainingCoordinator,
        "equipment chair": .equipmentCoordinator,
        "membership chair": .membershipCoordinator
    ].reduce(into: [:]) { result, item in
        result[item.key.normalizedScoutingLabel] = item.value
    }
}

enum MemberEntryKind: String, CaseIterable, Identifiable, Codable {
    case charge = "Charge"
    case payment = "Payment"
    case credit = "Credit"
    case adjustmentIncrease = "Balance Increase"
    case adjustmentDecrease = "Balance Decrease"

    var id: String { rawValue }

    var balanceMultiplier: Int64 {
        switch self {
        case .charge, .adjustmentIncrease: 1
        case .payment, .credit, .adjustmentDecrease: -1
        }
    }
}

enum RecurringChargeBatchKind: String, CaseIterable, Identifiable, Codable {
    case dues = "Recurring Dues"
    case registration = "Registration Charges"

    var id: String { rawValue }
}

enum EventStatus: String, CaseIterable, Identifiable, Codable {
    case planning = "Planning"
    case open = "Registration Open"
    case closed = "Registration Closed"
    case completed = "Completed"
    case cancelled = "Cancelled"

    var id: String { rawValue }
}

enum EventClassification: String, CaseIterable, Identifiable, Codable {
    case troop = "Troop Event"
    case district = "District Event"
    case council = "Council Event"
    case national = "National Event"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .troop: "person.3"
        case .district: "map"
        case .council: "building.2"
        case .national: "flag"
        }
    }
}

enum ParticipantStatus: String, CaseIterable, Identifiable, Codable {
    case invited = "Invited"
    case registered = "Registered"
    case waitlisted = "Waitlisted"
    case attended = "Attended"
    case cancelled = "Cancelled"
    case noShow = "No Show"

    var id: String { rawValue }
}

enum RegistrationStatus: String, CaseIterable, Identifiable, Codable {
    case pending = "Pending"
    case current = "Current"
    case expired = "Expired"
    case transferred = "Transferred"

    var id: String { rawValue }
}

enum AuditAction: String, CaseIterable, Identifiable, Codable {
    case create = "Created"
    case edit = "Edited"
    case delete = "Deleted"
    case importData = "Imported"
    case reconcile = "Reconciled"
    case lockPeriod = "Locked Period"
    case adjustment = "Adjustment"
    case sync = "Synced"
    case export = "Exported"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .create: "plus.circle"
        case .edit: "pencil.circle"
        case .delete: "trash.circle"
        case .importData: "square.and.arrow.down"
        case .reconcile: "checkmark.seal"
        case .lockPeriod: "lock.circle"
        case .adjustment: "arrow.uturn.left.circle"
        case .sync: "arrow.triangle.2.circlepath.circle"
        case .export: "square.and.arrow.up.circle"
        }
    }
}

@Model
final class TroopProfileRecord {
    var id: UUID = UUID()
    var troopName: String = ""
    var troopNumber: String = ""
    var council: String = ""
    var district: String = ""
    var charteredOrganization: String = ""
    var addressLine1: String = ""
    var addressLine2: String = ""
    var city: String = ""
    var stateOrProvince: String = ""
    var postalCode: String = ""
    var country: String = ""
    var unitEmail: String = ""
    var unitPhone: String = ""
    var website: String = ""
    var treasurerName: String = ""
    var treasurerPreferredName: String = ""
    var treasurerTitle: String = "Treasurer"
    var treasurerEmail: String = ""
    var treasurerPhone: String = ""
    var committeeChairName: String = ""
    var notes: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    init() {}

    var formalName: String {
        let name = troopName.trimmed
        let number = troopNumber.trimmed
        if name.isEmpty { return number.isEmpty ? "TroopLedger" : "Troop \(number)" }
        guard !number.isEmpty else { return name }
        if name.localizedCaseInsensitiveContains(number) { return name }
        return "\(name) • Troop \(number)"
    }

    var greetingName: String {
        let preferred = treasurerPreferredName.trimmed
        if !preferred.isEmpty { return preferred }
        return treasurerName.trimmed.split(separator: " ").first.map(String.init) ?? ""
    }

    var organizationLine: String {
        [council.trimmed.nonemptyValue, district.trimmed.nonemptyValue, charteredOrganization.trimmed.nonemptyValue]
            .compactMap { $0 }
            .joined(separator: " • ")
    }

    var mailingAddress: String {
        let locality = [city.trimmed.nonemptyValue, stateOrProvince.trimmed.nonemptyValue, postalCode.trimmed.nonemptyValue]
            .compactMap { $0 }
            .joined(separator: " ")
        return [addressLine1.trimmed.nonemptyValue, addressLine2.trimmed.nonemptyValue, locality.nonemptyValue, country.trimmed.nonemptyValue]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    var treasurerLine: String {
        let name = treasurerName.trimmed
        guard !name.isEmpty else { return "" }
        let title = treasurerTitle.trimmed
        return title.isEmpty ? name : "\(title): \(name)"
    }
}

struct TroopReportIdentity: Equatable {
    let formalName: String
    let troopNumber: String
    let council: String
    let district: String
    let organizationLine: String
    let mailingAddress: String
    let treasurerName: String
    let treasurerLine: String

    init(profile: TroopProfileRecord?) {
        formalName = profile?.formalName ?? "TroopLedger"
        troopNumber = profile?.troopNumber.trimmed ?? ""
        council = profile?.council.trimmed ?? ""
        district = profile?.district.trimmed ?? ""
        organizationLine = profile?.organizationLine ?? ""
        mailingAddress = profile?.mailingAddress ?? ""
        treasurerName = profile?.treasurerName.trimmed ?? ""
        treasurerLine = profile?.treasurerLine ?? ""
    }

    var hasProfile: Bool {
        formalName != "TroopLedger" || !organizationLine.isEmpty || !mailingAddress.isEmpty || !treasurerName.isEmpty
    }
}

@Model
final class AccountRecord {
    var id: UUID = UUID()
    var name: String = ""
    var institution: String = ""
    var kindRaw: String = AccountKind.checking.rawValue
    var openingBalanceCents: Int64 = 0
    var isActive: Bool = true
    var notes: String = ""
    var createdAt: Date = Date()

    init(name: String, institution: String = "", kind: AccountKind = .checking, openingBalanceCents: Int64 = 0) {
        self.name = name
        self.institution = institution
        self.kindRaw = kind.rawValue
        self.openingBalanceCents = openingBalanceCents
    }

    var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }
}

@Model
final class LedgerCategoryRecord {
    var id: UUID = UUID()
    var name: String = ""
    var directionRaw: String = TransactionDirection.expense.rawValue
    var isActive: Bool = true
    var isStandard: Bool = false
    var sortOrder: Int = 0
    var notes: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    init(name: String, direction: TransactionDirection, isStandard: Bool = false, sortOrder: Int = 0) {
        self.name = name
        self.directionRaw = direction.rawValue
        self.isStandard = isStandard
        self.sortOrder = sortOrder
    }

    var direction: TransactionDirection {
        get { TransactionDirection(rawValue: directionRaw) ?? .expense }
        set { directionRaw = newValue.rawValue }
    }
}

@Model
final class OperatingBudgetRecord {
    var id: UUID = UUID()
    var reportingYearStart: Int = 0
    var statusRaw: String = BudgetStatus.working.rawValue
    var revision: Int = 0
    var notes: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var approvedAt: Date?

    init(reportingYearStart: Int, status: BudgetStatus = .working, revision: Int = 0) {
        self.reportingYearStart = reportingYearStart
        self.statusRaw = status.rawValue
        self.revision = revision
    }

    var status: BudgetStatus {
        get { BudgetStatus(rawValue: statusRaw) ?? .working }
        set { statusRaw = newValue.rawValue }
    }

    var reportingPeriod: ReportingPeriod {
        ReportingPeriod(basis: .schoolYear, startingYear: reportingYearStart)
    }
}

@Model
final class BudgetLineRecord {
    var id: UUID = UUID()
    var budgetID: UUID?
    var categoryID: UUID?
    var categoryName: String = ""
    var directionRaw: String = TransactionDirection.expense.rawValue
    var amountCents: Int64 = 0
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    init(
        budgetID: UUID?,
        categoryID: UUID?,
        categoryName: String,
        direction: TransactionDirection,
        amountCents: Int64
    ) {
        self.budgetID = budgetID
        self.categoryID = categoryID
        self.categoryName = categoryName
        self.directionRaw = direction.rawValue
        self.amountCents = amountCents
    }

    var direction: TransactionDirection {
        get { TransactionDirection(rawValue: directionRaw) ?? .expense }
        set { directionRaw = newValue.rawValue }
    }
}

@Model
final class LedgerTransaction {
    var id: UUID = UUID()
    var accountID: UUID?
    var date: Date = Date()
    var directionRaw: String = TransactionDirection.expense.rawValue
    var amountCents: Int64 = 0
    var checkNumber: String = ""
    var payee: String = ""
    var category: String = "Uncategorized"
    var memo: String = ""
    var personID: UUID?
    var eventID: UUID?
    var isCleared: Bool = false
    var reconciledAt: Date?
    var reconciliationID: UUID?
    var isAdjustment: Bool = false
    var adjustsTransactionID: UUID?
    var adjustmentReason: String = ""
    var isTransfer: Bool = false
    var transferGroupID: UUID?
    var depositBatchID: UUID?
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var sourceSheet: String = ""
    var sourceRow: Int = 0

    init(accountID: UUID?, date: Date, direction: TransactionDirection, amountCents: Int64, payee: String, category: String) {
        self.accountID = accountID
        self.date = date
        self.directionRaw = direction.rawValue
        self.amountCents = amountCents
        self.payee = payee
        self.category = category
    }

    var direction: TransactionDirection {
        get { TransactionDirection(rawValue: directionRaw) ?? .expense }
        set { directionRaw = newValue.rawValue }
    }

    var signedAmountCents: Int64 {
        direction == .income ? amountCents : -amountCents
    }
}

@Model
final class DepositBatchRecord {
    var id: UUID = UUID()
    var undepositedFundsAccountID: UUID?
    var destinationAccountID: UUID?
    var depositDate: Date = Date()
    var totalCents: Int64 = 0
    var reference: String = ""
    var notes: String = ""
    var holdingTransactionID: UUID?
    var bankTransactionID: UUID?
    var createdAt: Date = Date()
    var postedAt: Date = Date()

    init(undepositedFundsAccountID: UUID?, destinationAccountID: UUID?, depositDate: Date, totalCents: Int64) {
        self.undepositedFundsAccountID = undepositedFundsAccountID
        self.destinationAccountID = destinationAccountID
        self.depositDate = depositDate
        self.totalCents = totalCents
    }
}

@Model
final class DepositAllocationRecord {
    var id: UUID = UUID()
    var batchID: UUID?
    var sourceTransactionID: UUID?
    var sourceCashReceiptID: UUID?
    var personID: UUID?
    var eventID: UUID?
    var payerNameSnapshot: String = ""
    var purposeSnapshot: String = ""
    var paymentKindSnapshot: String = ""
    var receivedAt: Date = Date()
    var amountCents: Int64 = 0
    var createdAt: Date = Date()

    init(batchID: UUID?, receivedAt: Date, amountCents: Int64) {
        self.batchID = batchID
        self.receivedAt = receivedAt
        self.amountCents = amountCents
    }
}

@Model
final class ReimbursementRequest {
    var id: UUID = UUID()
    var requesterPersonID: UUID?
    var submittedAt: Date = Date()
    var purchaseDate: Date = Date()
    var purpose: String = ""
    var category: String = "Uncategorized"
    var amountCents: Int64 = 0
    var eventID: UUID?
    var statusRaw: String = ReimbursementStatus.submitted.rawValue
    var reviewerName: String = ""
    var reviewNotes: String = ""
    var reviewedAt: Date?
    var approverPersonID: UUID?
    var approverNameSnapshot: String = ""
    var approverHouseholdSnapshot: String = ""
    var signerOnePersonID: UUID?
    var signerOneNameSnapshot: String = ""
    var signerOneHouseholdSnapshot: String = ""
    var signerTwoPersonID: UUID?
    var signerTwoNameSnapshot: String = ""
    var signerTwoHouseholdSnapshot: String = ""
    var disbursementControlNotes: String = ""
    var disbursementControlRecordedAt: Date?
    var paymentDate: Date?
    var paymentReference: String = ""
    var linkedTransactionID: UUID?
    var notes: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    init(
        requesterPersonID: UUID?,
        purchaseDate: Date,
        purpose: String,
        category: String,
        amountCents: Int64,
        eventID: UUID? = nil
    ) {
        self.requesterPersonID = requesterPersonID
        self.purchaseDate = purchaseDate
        self.purpose = purpose
        self.category = category
        self.amountCents = amountCents
        self.eventID = eventID
    }

    var status: ReimbursementStatus {
        get { ReimbursementStatus(rawValue: statusRaw) ?? .submitted }
        set { statusRaw = newValue.rawValue }
    }
}

@Model
final class DisbursementControlSettings {
    var id: UUID = UUID()
    var isEnabled: Bool = true
    var expectApprover: Bool = true
    var expectedSignerCount: Int = 2
    var warnSamePerson: Bool = true
    var warnSameHousehold: Bool = true
    var warnMissingHousehold: Bool = true
    var modifiedAt: Date = Date()

    init() {}
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonemptyValue: String? { isEmpty ? nil : self }
}

@Model
final class ReimbursementAttachment {
    var id: UUID = UUID()
    var requestID: UUID?
    var filename: String = ""
    var mediaType: String = "application/octet-stream"
    var byteCount: Int64 = 0
    var sha256: String = ""
    var createdAt: Date = Date()
    @Attribute(.externalStorage) var data: Data = Data()

    init(requestID: UUID?, filename: String, mediaType: String, byteCount: Int64, sha256: String, data: Data) {
        self.requestID = requestID
        self.filename = filename
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.data = data
    }
}

@Model
final class FamilyRecord {
    var id: UUID = UUID()
    var name: String = ""
    var notes: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    init(name: String) {
        self.name = name
    }
}

@Model
final class RecurringChargeBatchRecord {
    var id: UUID = UUID()
    var name: String = ""
    var kindRaw: String = RecurringChargeBatchKind.dues.rawValue
    var chargeDate: Date = Date()
    var category: String = "Dues"
    var programYear: String = ""
    var fixedAmountCents: Int64 = 0
    var totalCents: Int64 = 0
    var allocationCount: Int = 0
    var notes: String = ""
    var createdAt: Date = Date()
    var postedAt: Date = Date()

    init(name: String, kind: RecurringChargeBatchKind, chargeDate: Date, category: String) {
        self.name = name
        self.kindRaw = kind.rawValue
        self.chargeDate = chargeDate
        self.category = category
    }

    var kind: RecurringChargeBatchKind {
        get { RecurringChargeBatchKind(rawValue: kindRaw) ?? .dues }
        set { kindRaw = newValue.rawValue }
    }
}

@Model
final class RecurringChargeAllocationRecord {
    var id: UUID = UUID()
    var batchID: UUID?
    var personID: UUID?
    var memberEntryID: UUID?
    var registrationID: UUID?
    var personNameSnapshot: String = ""
    var chargeDate: Date = Date()
    var categorySnapshot: String = ""
    var amountCents: Int64 = 0
    var createdAt: Date = Date()

    init(batchID: UUID?, personID: UUID?, chargeDate: Date, amountCents: Int64) {
        self.batchID = batchID
        self.personID = personID
        self.chargeDate = chargeDate
        self.amountCents = amountCents
    }
}

@Model
final class PersonRecord {
    var id: UUID = UUID()
    var firstName: String = ""
    var lastName: String = ""
    var roleRaw: String = PersonRole.scout.rawValue
    var currentRankRaw: String = ScoutsBSARank.none.rawValue
    var troopPositionIDsRaw: String = ""
    var customPosition: String = ""
    var patrol: String = ""
    var scoutingMemberID: String = ""
    var email: String = ""
    var phone: String = ""
    var familyID: UUID?
    var joinDate: Date?
    var isActive: Bool = true
    var notes: String = ""
    var createdAt: Date = Date()

    init(firstName: String, lastName: String, role: PersonRole) {
        self.firstName = firstName
        self.lastName = lastName
        self.roleRaw = role.rawValue
    }

    var role: PersonRole {
        get { PersonRole(rawValue: roleRaw) ?? .other }
        set { roleRaw = newValue.rawValue }
    }

    var currentRank: ScoutsBSARank {
        get { ScoutsBSARank(rawValue: currentRankRaw) ?? .none }
        set { currentRankRaw = newValue.rawValue }
    }

    var troopPositions: [TroopPosition] {
        get {
            troopPositionIDsRaw
                .split(separator: "\n")
                .compactMap { TroopPosition(rawValue: String($0)) }
                .sorted { lhs, rhs in
                    guard lhs.category == rhs.category else { return lhs.category == .youth }
                    return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                }
        }
        set {
            troopPositionIDsRaw = Array(Set(newValue.map(\.rawValue))).sorted().joined(separator: "\n")
        }
    }

    var positionSummary: String {
        (troopPositions.map(\.displayName) + [customPosition].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            .joined(separator: ", ")
    }

    var displayName: String {
        [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

private extension String {
    var normalizedScoutingLabel: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
            .lowercased()
    }
}

@Model
final class MemberLedgerEntry {
    var id: UUID = UUID()
    var personID: UUID?
    var date: Date = Date()
    var kindRaw: String = MemberEntryKind.charge.rawValue
    var amountCents: Int64 = 0
    var category: String = "Dues"
    var eventID: UUID?
    var accountTransactionID: UUID?
    var chargeBatchID: UUID?
    var notes: String = ""
    var createdAt: Date = Date()
    var sourceSheet: String = ""
    var sourceRow: Int = 0
    var sourceSystem: String = ""
    var externalSourceID: String = ""

    init(personID: UUID?, date: Date, kind: MemberEntryKind, amountCents: Int64, category: String) {
        self.personID = personID
        self.date = date
        self.kindRaw = kind.rawValue
        self.amountCents = amountCents
        self.category = category
    }

    var kind: MemberEntryKind {
        get { MemberEntryKind(rawValue: kindRaw) ?? .charge }
        set { kindRaw = newValue.rawValue }
    }

    var balanceEffectCents: Int64 { amountCents * kind.balanceMultiplier }
}

@Model
final class RegistrationRecord {
    var id: UUID = UUID()
    var personID: UUID?
    var programYear: String = ""
    var unitRole: String = ""
    var statusRaw: String = RegistrationStatus.pending.rawValue
    var registeredOn: Date = Date()
    var expiresOn: Date?
    var duesAssessedCents: Int64 = 0
    var notes: String = ""
    var createdAt: Date = Date()
    var sourceSheet: String = ""
    var sourceRow: Int = 0

    init(personID: UUID?, programYear: String, unitRole: String, status: RegistrationStatus) {
        self.personID = personID
        self.programYear = programYear
        self.unitRole = unitRole
        self.statusRaw = status.rawValue
    }

    var status: RegistrationStatus {
        get { RegistrationStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }
}

@Model
final class EventRecord {
    var id: UUID = UUID()
    var name: String = ""
    var category: String = "Camping"
    var classificationRaw: String = EventClassification.troop.rawValue
    var startDate: Date = Date()
    var endDate: Date = Date()
    var registrationDeadline: Date?
    var location: String = ""
    var address: String = ""
    var locationDetails: String = ""
    var coordinator: String = ""
    var registrationReference: String = ""
    var statusRaw: String = EventStatus.planning.rawValue
    var capacity: Int = 0
    var budgetIncomeCents: Int64 = 0
    var budgetExpenseCents: Int64 = 0
    var feeCalculatorFixedCostsCents: Int64 = 0
    var feeCalculatorPerPersonCostsCents: Int64 = 0
    var feeCalculatorExpectedParticipants: Int = 0
    var feeCalculatorContingencyBasisPoints: Int = 0
    var feeCalculatorSuggestedFeeCents: Int64 = 0
    var closedAt: Date?
    var closeoutID: UUID?
    var notes: String = ""
    var dateIsApproximate: Bool = false
    var sourceSheet: String = ""
    var sourceSystem: String = ""
    var externalSourceID: String = ""
    var calendarSubscriptionID: UUID?
    var isReadOnly: Bool = false
    var isAllDay: Bool = false
    var externalModifiedAt: Date?
    var createdAt: Date = Date()

    init(name: String, startDate: Date, endDate: Date) {
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
    }

    var status: EventStatus {
        get { EventStatus(rawValue: statusRaw) ?? .planning }
        set { statusRaw = newValue.rawValue }
    }

    var classification: EventClassification {
        get { EventClassification(rawValue: classificationRaw) ?? .troop }
        set { classificationRaw = newValue.rawValue }
    }

    var mapSearchQuery: String {
        [location, address]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

@Model
final class EventFeeScheduleRecord {
    var id: UUID = UUID()
    var eventID: UUID?
    var name: String = "Standard"
    var eligibilityNotes: String = ""
    var feeCents: Int64 = 0
    var isDefault: Bool = false
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    init(eventID: UUID?, name: String, feeCents: Int64, isDefault: Bool = false) {
        self.eventID = eventID
        self.name = name
        self.feeCents = feeCents
        self.isDefault = isDefault
    }
}

@Model
final class EventParticipant {
    var id: UUID = UUID()
    var eventID: UUID?
    var personID: UUID?
    var guestName: String = ""
    var statusRaw: String = ParticipantStatus.registered.rawValue
    var feeCents: Int64 = 0
    var paidCents: Int64 = 0
    var feeScheduleID: UUID?
    var feeScheduleNameSnapshot: String = ""
    var transportation: String = ""
    var notes: String = ""
    var createdAt: Date = Date()

    init(eventID: UUID?, personID: UUID?, status: ParticipantStatus = .registered) {
        self.eventID = eventID
        self.personID = personID
        self.statusRaw = status.rawValue
    }

    var status: ParticipantStatus {
        get { ParticipantStatus(rawValue: statusRaw) ?? .registered }
        set { statusRaw = newValue.rawValue }
    }
}

@Model
final class EventCloseoutRecord {
    var id: UUID = UUID()
    var eventID: UUID?
    var closedAt: Date = Date()
    var rosterCount: Int = 0
    var actualIncomeCents: Int64 = 0
    var actualExpenseCents: Int64 = 0
    var actualParticipantCostCents: Int64 = 0
    var unpaidCents: Int64 = 0
    var refundDueCents: Int64 = 0
    var finalVarianceCents: Int64 = 0
    var postedAdjustmentCount: Int = 0
    var notes: String = ""
    var createdAt: Date = Date()

    init(eventID: UUID?, closedAt: Date) {
        self.eventID = eventID
        self.closedAt = closedAt
    }
}

@Model
final class EventCloseoutAllocationRecord {
    var id: UUID = UUID()
    var closeoutID: UUID?
    var eventID: UUID?
    var participantID: UUID?
    var personID: UUID?
    var memberEntryID: UUID?
    var participantNameSnapshot: String = ""
    var statusSnapshot: String = ""
    var feeScheduleNameSnapshot: String = ""
    var feeCents: Int64 = 0
    var paidCents: Int64 = 0
    var balanceCents: Int64 = 0
    var proposedAdjustmentCents: Int64 = 0
    var createdAt: Date = Date()

    init(closeoutID: UUID?, eventID: UUID?, participantID: UUID?) {
        self.closeoutID = closeoutID
        self.eventID = eventID
        self.participantID = participantID
    }
}

@Model
final class ReconciliationRecord {
    var id: UUID = UUID()
    var accountID: UUID?
    var statementDate: Date = Date()
    var statementEndingBalanceCents: Int64 = 0
    var clearedBalanceCents: Int64 = 0
    var completedAt: Date = Date()
    var notes: String = ""

    init(accountID: UUID?, statementDate: Date, statementEndingBalanceCents: Int64, clearedBalanceCents: Int64) {
        self.accountID = accountID
        self.statementDate = statementDate
        self.statementEndingBalanceCents = statementEndingBalanceCents
        self.clearedBalanceCents = clearedBalanceCents
    }
}

@Model
final class EventFinancialEntry {
    var id: UUID = UUID()
    var eventID: UUID?
    var date: Date = Date()
    var directionRaw: String = TransactionDirection.expense.rawValue
    var amountCents: Int64 = 0
    var entryDescription: String = ""
    var isProjected: Bool = false
    var sourceSheet: String = ""
    var sourceRow: Int = 0
    var createdAt: Date = Date()

    init(eventID: UUID?, date: Date, direction: TransactionDirection, amountCents: Int64, description: String) {
        self.eventID = eventID
        self.date = date
        self.directionRaw = direction.rawValue
        self.amountCents = amountCents
        self.entryDescription = description
    }

    var direction: TransactionDirection {
        get { TransactionDirection(rawValue: directionRaw) ?? .expense }
        set { directionRaw = newValue.rawValue }
    }
}

@Model
final class CashReceiptRecord {
    var id: UUID = UUID()
    var date: Date = Date()
    var personName: String = ""
    var purpose: String = ""
    var amountCents: Int64 = 0
    var paymentKind: String = ""
    var sourceSheet: String = ""
    var sourceRow: Int = 0
    var createdAt: Date = Date()

    init(date: Date, personName: String, purpose: String, amountCents: Int64, paymentKind: String) {
        self.date = date
        self.personName = personName
        self.purpose = purpose
        self.amountCents = amountCents
        self.paymentKind = paymentKind
    }
}

@Model
final class ImportRecord {
    var id: UUID = UUID()
    var sourceName: String = ""
    var sourceFingerprint: String = ""
    var importedAt: Date = Date()
    var accountCount: Int = 0
    var transactionCount: Int = 0
    var cashReceiptCount: Int = 0
    var peopleCount: Int = 0
    var registrationCount: Int = 0
    var memberEntryCount: Int = 0
    var eventCount: Int = 0
    var eventLineItemCount: Int = 0

    init(sourceName: String, sourceFingerprint: String) {
        self.sourceName = sourceName
        self.sourceFingerprint = sourceFingerprint
    }
}

@Model
final class GeneralSpreadsheetImportRecord {
    var id: UUID = UUID()
    var sourceName: String = ""
    var sourceFingerprint: String = ""
    var importedAt: Date = Date()
    var accountID: UUID?
    var sourceRowCount: Int = 0
    var importedCount: Int = 0
    var skippedCount: Int = 0
    var mappingSummary: String = ""
    var exceptionNotes: String = ""

    init(sourceName: String, sourceFingerprint: String, accountID: UUID?) {
        self.sourceName = sourceName
        self.sourceFingerprint = sourceFingerprint
        self.accountID = accountID
    }
}

@Model
final class ScoutbookImportRecord {
    var id: UUID = UUID()
    var sourceName: String = ""
    var sourceFingerprint: String = ""
    var importKind: String = ""
    var importedAt: Date = Date()
    var sourceRowCount: Int = 0
    var insertedCount: Int = 0
    var updatedCount: Int = 0
    var skippedCount: Int = 0
    var notes: String = ""

    init(sourceName: String, sourceFingerprint: String, importKind: String) {
        self.sourceName = sourceName
        self.sourceFingerprint = sourceFingerprint
        self.importKind = importKind
    }
}

@Model
final class ExternalCalendarSubscription {
    var id: UUID = UUID()
    var name: String = ""
    var feedURLString: String = ""
    var isEnabled: Bool = true
    var lastSyncedAt: Date?
    var lastError: String = ""
    var lastEventCount: Int = 0
    var createdAt: Date = Date()

    init(name: String, feedURLString: String) {
        self.name = name
        self.feedURLString = feedURLString
    }
}

/// Audit records are created through `AuditLogger` and intentionally have no edit or delete workflow.
@Model
final class AuditLogEntry {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var actionRaw: String = AuditAction.create.rawValue
    var recordType: String = ""
    var recordID: UUID?
    var summary: String = ""
    var details: String = ""
    var deviceName: String = ""
    var operatingSystem: String = ""
    var userIdentity: String = ""

    init(
        timestamp: Date = Date(),
        action: AuditAction,
        recordType: String,
        recordID: UUID?,
        summary: String,
        details: String = "",
        deviceName: String,
        operatingSystem: String,
        userIdentity: String
    ) {
        self.timestamp = timestamp
        self.actionRaw = action.rawValue
        self.recordType = recordType
        self.recordID = recordID
        self.summary = summary
        self.details = details
        self.deviceName = deviceName
        self.operatingSystem = operatingSystem
        self.userIdentity = userIdentity
    }

    var action: AuditAction {
        AuditAction(rawValue: actionRaw) ?? .create
    }
}
