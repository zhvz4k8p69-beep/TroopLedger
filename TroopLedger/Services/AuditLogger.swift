import Foundation
import SwiftData

struct AuditIdentity: Equatable {
    let deviceName: String
    let operatingSystem: String
    let userIdentity: String

    static var current: AuditIdentity {
        let process = ProcessInfo.processInfo
#if os(macOS)
        let localUser = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
#else
        let localUser = ""
#endif
        return AuditIdentity(
            deviceName: process.hostName,
            operatingSystem: process.operatingSystemVersionString,
            userIdentity: localUser
        )
    }
}

@MainActor
enum AuditLogger {
    @discardableResult
    static func record(
        _ action: AuditAction,
        recordType: String,
        recordID: UUID?,
        summary: String,
        details: String = "",
        at timestamp: Date = Date(),
        identity: AuditIdentity = .current,
        in modelContext: ModelContext
    ) -> AuditLogEntry {
        let entry = AuditLogEntry(
            timestamp: timestamp,
            action: action,
            recordType: recordType,
            recordID: recordID,
            summary: summary,
            details: details,
            deviceName: identity.deviceName,
            operatingSystem: identity.operatingSystem,
            userIdentity: identity.userIdentity
        )
        modelContext.insert(entry)
        return entry
    }

    static func details(_ fields: [(String, String?)]) -> String {
        fields.compactMap { label, value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return "\(label): \(value)"
        }
        .joined(separator: "\n")
    }
}
