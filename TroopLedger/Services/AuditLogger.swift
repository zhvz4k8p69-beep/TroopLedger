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
            operatingSystem: "\(process.operatingSystemVersionString) • TroopLedger \(applicationVersion)",
            userIdentity: localUser
        )
    }

    /// Which build wrote an entry matters when reconstructing what a bug or an old version did to the books.
    private static let applicationVersion: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }()

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
        // iOS exposes no account name, so entries from an iPhone or iPad carried no actor at all. The troop
        // profile names the treasurer who owns this database; use that name when the system offers none.
        var userIdentity = identity.userIdentity
        if userIdentity.isEmpty {
            var descriptor = FetchDescriptor<TroopProfileRecord>(sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)])
            descriptor.fetchLimit = 1
            if let treasurer = (try? modelContext.fetch(descriptor))?.first?.treasurerName.trimmingCharacters(in: .whitespacesAndNewlines), !treasurer.isEmpty {
                userIdentity = "\(treasurer) (troop profile)"
            }
        }
        let entry = AuditLogEntry(
            timestamp: timestamp,
            action: action,
            recordType: recordType,
            recordID: recordID,
            summary: summary,
            details: details,
            deviceName: identity.deviceName,
            operatingSystem: identity.operatingSystem,
            userIdentity: userIdentity
        )
        modelContext.insert(entry)
        return entry
    }

    /// Serializes audit entries so the log can be handed to a reviewer on its own, without a full backup.
    static func csv(for entries: [AuditLogEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let header = ["id", "timestamp", "action", "record_type", "record_id", "summary", "details", "device_name", "operating_system", "user_identity"]
        let rows = entries.sorted { $0.timestamp < $1.timestamp }.map { entry in
            [entry.id.uuidString.lowercased(), formatter.string(from: entry.timestamp), entry.actionRaw, entry.recordType, entry.recordID?.uuidString.lowercased() ?? "", entry.summary, entry.details, entry.deviceName, entry.operatingSystem, entry.userIdentity]
        }
        return ([header] + rows).map { $0.map(CSVFormatting.field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
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
