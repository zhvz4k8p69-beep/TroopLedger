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
            deviceName: cachedDeviceName,
            operatingSystem: process.operatingSystemVersionString,
            userIdentity: localUser
        )
    }

    /// `ProcessInfo.hostName` performs a synchronous reverse-DNS lookup that can stall the main thread for
    /// seconds on a slow or captive network, and it ran for every audit entry. The kernel hostname is read
    /// once without touching the network.
    private static let cachedDeviceName: String = {
#if os(macOS)
        if let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
#endif
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        return String(cString: buffer)
    }()
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

    /// Builds "Changed <field>: before → after" lines from two snapshots taken around an edit, so an audit
    /// entry shows what was altered rather than only the values that remained.
    static func changes(from before: [(String, String)], to after: [(String, String)]) -> [(String, String?)] {
        zip(before, after).compactMap { previous, current in
            guard previous.1 != current.1 else { return nil }
            let from = previous.1.isEmpty ? "(empty)" : previous.1
            let to = current.1.isEmpty ? "(empty)" : current.1
            return ("Changed \(previous.0)", "\(from) → \(to)")
        }
    }

    static func details(_ fields: [(String, String?)]) -> String {
        fields.compactMap { label, value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return "\(label): \(value)"
        }
        .joined(separator: "\n")
    }
}
