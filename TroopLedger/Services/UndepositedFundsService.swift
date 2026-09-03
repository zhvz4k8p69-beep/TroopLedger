import Foundation
import SwiftData

enum UndepositedFundsError: LocalizedError, Equatable {
    case accountAlreadyExists

    var errorDescription: String? {
        switch self {
        case .accountAlreadyExists:
            "TroopLedger supports one Undeposited Funds holding account. Edit or reactivate the existing account instead."
        }
    }
}

@MainActor
enum UndepositedFundsService {
    static let defaultAccountName = "Undeposited Funds"

    static func existingAccount(in accounts: [AccountRecord]) -> AccountRecord? {
        accounts.first { $0.kind == .undepositedFunds }
    }

    static func validateUnique(kind: AccountKind, editingAccountID: UUID?, accounts: [AccountRecord]) throws {
        guard kind == .undepositedFunds else { return }
        guard !accounts.contains(where: { $0.kind == .undepositedFunds && $0.id != editingAccountID }) else {
            throw UndepositedFundsError.accountAlreadyExists
        }
    }

    @discardableResult
    static func createAccount(in modelContext: ModelContext) throws -> AccountRecord {
        let accounts = try modelContext.fetch(FetchDescriptor<AccountRecord>())
        try validateUnique(kind: .undepositedFunds, editingAccountID: nil, accounts: accounts)
        let account = AccountRecord(name: defaultAccountName, kind: .undepositedFunds)
        account.notes = "Cash and checks received by the troop but not yet included in a bank deposit."
        modelContext.insert(account)
        AuditLogger.record(
            .create,
            recordType: "Account",
            recordID: account.id,
            summary: "Created Undeposited Funds holding account",
            details: AuditLogger.details([
                ("Type", account.kind.rawValue),
                ("Opening balance", Money.currency(cents: account.openingBalanceCents)),
            ]),
            in: modelContext
        )
        try modelContext.save()
        return account
    }
}
