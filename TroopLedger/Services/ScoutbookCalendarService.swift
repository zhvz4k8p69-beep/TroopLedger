import CryptoKit
import Foundation
import SwiftData

struct ScoutbookCalendarEvent: Equatable, Sendable {
    let externalID: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String
    let notes: String
    let isAllDay: Bool
    let modifiedAt: Date?
}

struct CalendarSyncResult: Sendable {
    let inserted: Int
    let updated: Int
    let removed: Int
    let detached: Int
    let eventCount: Int
}

enum ScoutbookCalendarError: LocalizedError, Equatable {
    case invalidURL
    case insecureURL
    case badResponse
    case oversizedFeed
    case tooManyEvents
    case unreadableFeed
    case noEvents

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter the complete Scoutbook calendar subscription URL."
        case .insecureURL: "Scoutbook calendar subscriptions must use a secure HTTPS URL, including after any redirect."
        case .badResponse: "Scoutbook did not return a successful calendar response."
        case .oversizedFeed: "The calendar feed is larger than the app's 5 MB safety limit."
        case .tooManyEvents: "The calendar feed expands to more than \(ScoutbookCalendarService.maximumExpandedEvents) events, which exceeds the app's safety limit."
        case .unreadableFeed: "The downloaded file is not a readable iCalendar feed."
        case .noEvents: "The calendar feed did not contain any events."
        }
    }
}

/// Only follows redirects that stay on HTTPS. A feed host that bounces to plain HTTP (or a redirect injected
/// on the network) must not silently downgrade a private calendar to cleartext.
private final class FeedRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}

enum ScoutbookCalendarService {
    static let maximumFeedBytes = 5_000_000
    static let maximumExpandedEvents = 5_000

    /// Ephemeral session: nothing from a private calendar feed is written to the shared cookie jar, credential
    /// store, or on-disk URL cache, and redirects are constrained by `FeedRedirectPolicy`.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration, delegate: FeedRedirectPolicy(), delegateQueue: nil)
    }()

    static func validatedURL(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil else {
            throw ScoutbookCalendarError.invalidURL
        }
        guard url.scheme?.lowercased() == "https" else { throw ScoutbookCalendarError.insecureURL }
        return url
    }

    static func fetch(url: URL) async throws -> [ScoutbookCalendarEvent] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue("text/calendar, text/plain;q=0.9", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw ScoutbookCalendarError.badResponse
        }
        guard response.url?.scheme?.lowercased() == "https" else { throw ScoutbookCalendarError.insecureURL }
        if response.expectedContentLength > Int64(maximumFeedBytes) { throw ScoutbookCalendarError.oversizedFeed }

        // Stream the body and stop as soon as the limit is crossed instead of buffering an arbitrarily large
        // response first and checking its size afterwards.
        var data = Data()
        data.reserveCapacity(Int(max(0, min(response.expectedContentLength, Int64(maximumFeedBytes)))))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumFeedBytes { throw ScoutbookCalendarError.oversizedFeed }
        }
        return try parse(data: data)
    }

    static func parse(data: Data) throws -> [ScoutbookCalendarEvent] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              text.uppercased().contains("BEGIN:VCALENDAR") else {
            throw ScoutbookCalendarError.unreadableFeed
        }
        let lines = unfoldLines(text)
        var rawEvents: [[String: (value: String, parameters: [String: String])]] = []
        var current: [String: (value: String, parameters: [String: String])]?

        for line in lines {
            if line.uppercased() == "BEGIN:VEVENT" {
                current = [:]
                continue
            }
            if line.uppercased() == "END:VEVENT" {
                if let current { rawEvents.append(current) }
                current = nil
                continue
            }
            guard current != nil, let colon = line.firstIndex(of: ":") else { continue }
            let left = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
            let pieces = left.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            let name = pieces[0].uppercased()
            var parameters: [String: String] = [:]
            for piece in pieces.dropFirst() {
                let pair = piece.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { parameters[pair[0].uppercased()] = pair[1] }
            }
            current?[name] = (value, parameters)
        }

        var results: [ScoutbookCalendarEvent] = []
        for raw in rawEvents {
            guard let startProperty = raw["DTSTART"],
                  let parsedStart = parseDate(startProperty.value, parameters: startProperty.parameters) else { continue }
            let endProperty = raw["DTEND"]
            var end = endProperty.flatMap { parseDate($0.value, parameters: $0.parameters)?.date } ?? parsedStart.date
            if endProperty?.parameters["VALUE"]?.uppercased() == "DATE" || parsedStart.isDateOnly {
                if end > parsedStart.date {
                    end = Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end
                }
            }
            if end < parsedStart.date { end = parsedStart.date }

            let title = decodeText(raw["SUMMARY"]?.value ?? "Scoutbook Event")
            let location = decodeText(raw["LOCATION"]?.value ?? "")
            let notes = decodeText(raw["DESCRIPTION"]?.value ?? "")
            let modified = raw["LAST-MODIFIED"].flatMap { parseDate($0.value, parameters: $0.parameters)?.date }
            let recurrenceID = raw["RECURRENCE-ID"].flatMap { parseDate($0.value, parameters: $0.parameters)?.date }
            let uid = raw["UID"]?.value ?? stableID("\(title)|\(parsedStart.date.timeIntervalSince1970)|\(location)")
            let externalID = recurrenceID.map { "\(uid)#\(Int($0.timeIntervalSince1970))" } ?? uid
            let base = ScoutbookCalendarEvent(externalID: externalID, title: title, startDate: parsedStart.date, endDate: end, location: location, notes: notes, isAllDay: parsedStart.isDateOnly, modifiedAt: modified)
            results.append(contentsOf: expand(base, rule: raw["RRULE"]?.value))
            // Every recurring VEVENT can expand to hundreds of records; bound the total so a feed cannot
            // flood the database (and CloudKit) with millions of synchronized events.
            guard results.count <= maximumExpandedEvents else { throw ScoutbookCalendarError.tooManyEvents }
        }
        guard !results.isEmpty else { throw ScoutbookCalendarError.noEvents }
        return results
    }

    @MainActor
    static func sync(subscription: ExternalCalendarSubscription, into modelContext: ModelContext) async throws -> CalendarSyncResult {
        do {
            let url = try validatedURL(subscription.feedURLString)
            let feedEvents = try await fetch(url: url)
            let result = try apply(feedEvents: feedEvents, to: subscription, in: modelContext)

            subscription.lastSyncedAt = Date()
            subscription.lastError = ""
            subscription.lastEventCount = feedEvents.count
            AuditLogger.record(
                .sync,
                recordType: "Calendar Subscription",
                recordID: subscription.id,
                summary: "Synced Scoutbook calendar \(subscription.name)",
                details: AuditLogger.details([
                    ("Events received", String(feedEvents.count)),
                    ("Inserted", String(result.inserted)),
                    ("Updated", String(result.updated)),
                    ("Removed", String(result.removed)),
                    ("Preserved with local data", String(result.detached)),
                ]),
                in: modelContext
            )
            try modelContext.save()
            return result
        } catch {
            subscription.lastError = error.localizedDescription
            try? modelContext.save()
            throw error
        }
    }

    @MainActor
    static func apply(
        feedEvents: [ScoutbookCalendarEvent],
        to subscription: ExternalCalendarSubscription,
        in modelContext: ModelContext
    ) throws -> CalendarSyncResult {
        let storedEvents = try modelContext.fetch(FetchDescriptor<EventRecord>())
        let subscribedEvents = storedEvents.filter { $0.calendarSubscriptionID == subscription.id }
        var byExternalID: [String: EventRecord] = [:]
        for event in subscribedEvents where !event.externalSourceID.isEmpty {
            byExternalID[event.externalSourceID] = event
        }

        var inserted = 0
        var updated = 0
        let receivedIDs = Set(feedEvents.map(\.externalID))
        for source in feedEvents {
            let event: EventRecord
            if let existing = byExternalID[source.externalID] {
                event = existing
                updated += 1
            } else {
                event = EventRecord(name: source.title, startDate: source.startDate, endDate: source.endDate)
                modelContext.insert(event)
                byExternalID[source.externalID] = event
                inserted += 1
            }
            event.name = source.title
            event.category = "Scoutbook Calendar"
            event.startDate = source.startDate
            event.endDate = source.endDate
            event.location = source.location
            event.notes = source.notes
            if event.closedAt == nil { event.status = .planning }
            event.dateIsApproximate = false
            event.sourceSystem = "Scoutbook Calendar"
            event.externalSourceID = source.externalID
            event.calendarSubscriptionID = subscription.id
            event.isReadOnly = true
            event.isAllDay = source.isAllDay
            event.externalModifiedAt = source.modifiedAt
        }

        let dependencies = try eventDependencies(in: modelContext)
        var removed = 0
        var detached = 0
        for event in subscribedEvents where !receivedIDs.contains(event.externalSourceID) {
            if canDelete(event, dependencies: dependencies) {
                modelContext.delete(event)
                removed += 1
            } else {
                event.calendarSubscriptionID = nil
                event.isReadOnly = false
                detached += 1
            }
        }

        return CalendarSyncResult(
            inserted: inserted,
            updated: updated,
            removed: removed,
            detached: detached,
            eventCount: feedEvents.count
        )
    }

    @MainActor
    static func remove(subscription: ExternalCalendarSubscription, from modelContext: ModelContext) throws {
        let events = try modelContext.fetch(FetchDescriptor<EventRecord>())
        let dependencies = try eventDependencies(in: modelContext)
        var removedCount = 0
        var detachedCount = 0
        for event in events where event.calendarSubscriptionID == subscription.id {
            if canDelete(event, dependencies: dependencies) {
                modelContext.delete(event)
                removedCount += 1
            } else {
                event.calendarSubscriptionID = nil
                event.isReadOnly = false
                detachedCount += 1
            }
        }
        AuditLogger.record(
            .delete,
            recordType: "Calendar Subscription",
            recordID: subscription.id,
            summary: "Removed Scoutbook calendar \(subscription.name)",
            details: "Removed \(removedCount) synchronized events and preserved \(detachedCount) events that contain local records.",
            in: modelContext
        )
        modelContext.delete(subscription)
        try modelContext.save()
    }

    private struct EventDependencies {
        let transactions: [LedgerTransaction]
        let depositAllocations: [DepositAllocationRecord]
        let reimbursements: [ReimbursementRequest]
        let memberEntries: [MemberLedgerEntry]
        let feeSchedules: [EventFeeScheduleRecord]
        let participants: [EventParticipant]
        let closeouts: [EventCloseoutRecord]
        let closeoutAllocations: [EventCloseoutAllocationRecord]
        let financialEntries: [EventFinancialEntry]
    }

    @MainActor
    private static func eventDependencies(in modelContext: ModelContext) throws -> EventDependencies {
        EventDependencies(
            transactions: try modelContext.fetch(FetchDescriptor<LedgerTransaction>()),
            depositAllocations: try modelContext.fetch(FetchDescriptor<DepositAllocationRecord>()),
            reimbursements: try modelContext.fetch(FetchDescriptor<ReimbursementRequest>()),
            memberEntries: try modelContext.fetch(FetchDescriptor<MemberLedgerEntry>()),
            feeSchedules: try modelContext.fetch(FetchDescriptor<EventFeeScheduleRecord>()),
            participants: try modelContext.fetch(FetchDescriptor<EventParticipant>()),
            closeouts: try modelContext.fetch(FetchDescriptor<EventCloseoutRecord>()),
            closeoutAllocations: try modelContext.fetch(FetchDescriptor<EventCloseoutAllocationRecord>()),
            financialEntries: try modelContext.fetch(FetchDescriptor<EventFinancialEntry>())
        )
    }

    private static func canDelete(_ event: EventRecord, dependencies: EventDependencies) -> Bool {
        RecordDeletionPolicy.canDeleteEvent(
            event.id,
            transactions: dependencies.transactions,
            depositAllocations: dependencies.depositAllocations,
            reimbursements: dependencies.reimbursements,
            memberEntries: dependencies.memberEntries,
            feeSchedules: dependencies.feeSchedules,
            participants: dependencies.participants,
            closeouts: dependencies.closeouts,
            closeoutAllocations: dependencies.closeoutAllocations,
            financialEntries: dependencies.financialEntries
        )
    }

    private static func unfoldLines(_ text: String) -> [String] {
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        for line in raw {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !result.isEmpty {
                result[result.count - 1] += line.dropFirst()
            } else {
                result.append(line)
            }
        }
        return result
    }

    private static func parseDate(_ value: String, parameters: [String: String]) -> (date: Date, isDateOnly: Bool)? {
        let isDateOnly = parameters["VALUE"]?.uppercased() == "DATE" || (value.count == 8 && !value.contains("T"))
        let timeZone = parameters["TZID"].flatMap(TimeZone.init(identifier:)) ?? .current
        let formats = isDateOnly
            ? ["yyyyMMdd"]
            : value.hasSuffix("Z") ? ["yyyyMMdd'T'HHmmss'Z'", "yyyyMMdd'T'HHmm'Z'"] : ["yyyyMMdd'T'HHmmss", "yyyyMMdd'T'HHmm"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = value.hasSuffix("Z") ? TimeZone(secondsFromGMT: 0) : timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return (date, isDateOnly) }
        }
        return nil
    }

    /// Single-pass RFC 5545 TEXT unescaping. Sequential `replacingOccurrences` calls decode `\\n`
    /// (an escaped backslash followed by the letter n) as a newline; scanning once keeps escapes independent.
    private static func decodeText(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var result = ""
        result.reserveCapacity(value.count)
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let escaped = iterator.next() else {
                result.append(character)
                continue
            }
            switch escaped {
            case "n", "N": result.append("\n")
            case ",", ";", "\\": result.append(escaped)
            default:
                result.append("\\")
                result.append(escaped)
            }
        }
        return result
    }

    private static func expand(_ event: ScoutbookCalendarEvent, rule: String?) -> [ScoutbookCalendarEvent] {
        guard let rule else { return [event] }
        // A feed line such as `RRULE:FREQ=WEEKLY;FREQ=DAILY` must not trap; keep the first value for a repeated key.
        let values = Dictionary(rule.split(separator: ";").compactMap { component -> (String, String)? in
            let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
            return pair.count == 2 ? (pair[0].uppercased(), pair[1]) : nil
        }, uniquingKeysWith: { first, _ in first })
        guard let frequency = values["FREQ"]?.uppercased() else { return [event] }
        let interval = max(1, Int(values["INTERVAL"] ?? "1") ?? 1)
        let count = min(500, max(1, Int(values["COUNT"] ?? "500") ?? 500))
        let until = values["UNTIL"].flatMap { parseDate($0, parameters: [:])?.date }
        let horizon = Calendar.current.date(byAdding: .year, value: 2, to: Date()) ?? Date().addingTimeInterval(63_072_000)
        let component: Calendar.Component
        switch frequency {
        case "DAILY": component = .day
        case "WEEKLY": component = .weekOfYear
        case "MONTHLY": component = .month
        case "YEARLY": component = .year
        default: return [event]
        }

        let duration = event.endDate.timeIntervalSince(event.startDate)
        var results: [ScoutbookCalendarEvent] = []
        for index in 0..<count {
            guard let start = Calendar.current.date(byAdding: component, value: index * interval, to: event.startDate) else { break }
            if let until, start > until { break }
            if start > horizon { break }
            let occurrenceID = "\(event.externalID)#\(Int(start.timeIntervalSince1970))"
            results.append(ScoutbookCalendarEvent(
                externalID: occurrenceID,
                title: event.title,
                startDate: start,
                endDate: start.addingTimeInterval(duration),
                location: event.location,
                notes: event.notes,
                isAllDay: event.isAllDay,
                modifiedAt: event.modifiedAt
            ))
        }
        return results.isEmpty ? [event] : results
    }

    private static func stableID(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
