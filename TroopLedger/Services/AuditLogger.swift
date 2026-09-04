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
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }()
}

@MainActor
enum AuditLogger {
    /// The treasurer-name fallback used to run a store fetch on every audit write on iOS. The name only
    /// changes when the troop profile is saved, so it is cached per container and cleared by the profile editor.
    private static var cachedTreasurerIdentity: (container: ObjectIdentifier, value: String)?

    static func invalidateTreasurerIdentity() {
        cachedTreasurerIdentity = nil
    }

    private static func treasurerIdentity(in modelContext: ModelContext) -> String {
        let containerID = ObjectIdentifier(modelContext.container)
        if let cached = cachedTreasurerIdentity, cached.container == containerID {
            return cached.value
        }
        var descriptor = FetchDescriptor<TroopProfileRecord>(sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        let treasurer = (try? modelContext.fetch(descriptor))?.first?.treasurerName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = treasurer.isEmpty ? "" : "\(treasurer) (troop profile)"
        cachedTreasurerIdentity = (containerID, value)
        return value
    }

    /// Keeps audit `details` bounded when a change touches hundreds of records; the row syncs through
    /// CloudKit and is re-rendered in the audit log, so a multi-kilobyte string in one field is a cost.
    static func truncatedList(_ items: [String], limit: Int = 50) -> String {
        guard items.count > limit else { return items.joined(separator: "\n") }
        return items.prefix(limit).joined(separator: "\n") + "\n… and \(items.count - limit) more"
    }

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
            userIdentity = treasurerIdentity(in: modelContext)
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
