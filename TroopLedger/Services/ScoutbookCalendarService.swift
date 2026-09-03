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
    var isCancelled: Bool = false
}

struct CalendarSyncResult: Sendable {
    let inserted: Int
    let updated: Int
    let removed: Int
    let detached: Int
    let eventCount: Int
    var insertedTitles: [String] = []
    var removedTitles: [String] = []
    var detachedTitles: [String] = []
}

enum ScoutbookCalendarError: LocalizedError, Equatable {
    case invalidURL
    case insecureURL
    case embeddedCredentials
    case subscriptionRemoved
    case badResponse
    case oversizedFeed
    case tooManyEvents
    case unreadableFeed
    case noEvents

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter the complete Scoutbook calendar subscription URL."
        case .insecureURL: "Scoutbook calendar subscriptions must use a secure HTTPS URL, including after any redirect."
        case .embeddedCredentials: "Remove the username and password from the calendar URL. TroopLedger never sends sign-in credentials to a calendar host."
        case .subscriptionRemoved: "This calendar subscription was removed while it was syncing."
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
    /// Per-field ceilings for feed text. A CloudKit record is limited to about 1 MB, so one oversized
    /// DESCRIPTION would make its event unsyncable on every device.
    static let maximumTitleLength = 500
    static let maximumLocationLength = 1_000
    static let maximumNotesLength = 20_000

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
        // userinfo in a URL is sent as HTTP Basic credentials to whatever host the URL names.
        guard url.user == nil, url.password == nil else { throw ScoutbookCalendarError.embeddedCredentials }
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
            // EXDATE may appear on several lines; a later line must not discard the earlier exclusions.
            if name == "EXDATE", let existing = current?[name] {
                current?[name] = (existing.value + "," + value, existing.parameters.merging(parameters) { current, _ in current })
            } else {
                current?[name] = (value, parameters)
            }
        }

        var results: [ScoutbookCalendarEvent] = []
        var overrides: [String: ScoutbookCalendarEvent] = [:]
        for raw in rawEvents {
            guard let startProperty = raw["DTSTART"],
                  let parsedStart = parseDate(startProperty.value, parameters: startProperty.parameters) else { continue }
            let endProperty = raw["DTEND"]
            // RFC 5545 allows DURATION in place of DTEND; feeds from Outlook and Google use it.
            var end = endProperty.flatMap { parseDate($0.value, parameters: $0.parameters)?.date }
                ?? raw["DURATION"].flatMap { parseDuration($0.value) }.map { parsedStart.date.addingTimeInterval($0) }
                ?? parsedStart.date
            if endProperty?.parameters["VALUE"]?.uppercased() == "DATE" || parsedStart.isDateOnly {
                if end > parsedStart.date {
                    end = Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end
                }
            }
            if end < parsedStart.date { end = parsedStart.date }

            let title = String(decodeText(raw["SUMMARY"]?.value ?? "Scoutbook Event").prefix(maximumTitleLength))
            let location = String(decodeText(raw["LOCATION"]?.value ?? "").prefix(maximumLocationLength))
            let notes = String(decodeText(raw["DESCRIPTION"]?.value ?? "").prefix(maximumNotesLength))
            let modified = raw["LAST-MODIFIED"].flatMap { parseDate($0.value, parameters: $0.parameters)?.date }
            let recurrenceID = raw["RECURRENCE-ID"].flatMap { parseDate($0.value, parameters: $0.parameters)?.date }
            let uid = raw["UID"]?.value ?? stableID("\(title)|\(parsedStart.date.timeIntervalSince1970)|\(location)")
            let externalID = recurrenceID.map { "\(uid)#\(Int($0.timeIntervalSince1970))" } ?? uid
            let isCancelled = raw["STATUS"]?.value.trimmingCharacters(in: .whitespaces).uppercased() == "CANCELLED"
            let exclusions = raw["EXDATE"].map { property in
                property.value.split(separator: ",").compactMap { parseDate(String($0).trimmingCharacters(in: .whitespaces), parameters: property.parameters)?.date }
            } ?? []
            let base = ScoutbookCalendarEvent(externalID: externalID, title: title, startDate: parsedStart.date, endDate: end, location: location, notes: notes, isAllDay: parsedStart.isDateOnly, modifiedAt: modified, isCancelled: isCancelled)
            if recurrenceID != nil {
                // A RECURRENCE-ID VEVENT replaces one occurrence of its series. Hold it aside so it wins
                // regardless of whether the feed lists it before or after the master event.
                overrides[externalID] = base
                continue
            }
            results.append(contentsOf: expand(base, rule: raw["RRULE"]?.value, exclusions: exclusions))
            // Every recurring VEVENT can expand to hundreds of records; bound the total so a feed cannot
            // flood the database (and CloudKit) with millions of synchronized events.
            guard results.count + overrides.count <= maximumExpandedEvents else { throw ScoutbookCalendarError.tooManyEvents }
        }
        var unmatchedOverrides = overrides
        results = results.map { occurrence in
            guard let override = unmatchedOverrides.removeValue(forKey: occurrence.externalID) else { return occurrence }
            return override
        }
        results.append(contentsOf: unmatchedOverrides.values.sorted { $0.startDate < $1.startDate })
        guard !results.isEmpty else { throw ScoutbookCalendarError.noEvents }
        return results
    }

    @MainActor
    static func sync(subscription: ExternalCalendarSubscription, into modelContext: ModelContext) async throws -> CalendarSyncResult {
        // Persist unrelated pending edits first so a failed sync can roll back only its own partial writes.
        if modelContext.hasChanges { try modelContext.save() }
        do {
            let url = try validatedURL(subscription.feedURLString)
            let feedEvents = try await fetch(url: url)
            // The user may have deleted the subscription while the download was in flight.
            guard !subscription.isDeleted else { throw ScoutbookCalendarError.subscriptionRemoved }
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
                    // Counts alone cannot show which events a sync added or took away.
                    ("Added events", result.insertedTitles.prefix(50).joined(separator: "\n")),
                    ("Removed events", result.removedTitles.prefix(50).joined(separator: "\n")),
                    ("Detached events", result.detachedTitles.prefix(50).joined(separator: "\n")),
                ]),
                in: modelContext
            )
            try modelContext.save()
            return result
        } catch {
            // Never leave a half-applied feed behind: inserted, updated, and deleted events from this attempt
            // are discarded together, then only the error is recorded.
            modelContext.rollback()
            if !subscription.isDeleted {
                subscription.lastError = error.localizedDescription
                try? modelContext.save()
            }
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
        // Events that were detached earlier (they vanished from the feed but carried local records) keep
        // their external ID. If the feed lists them again, re-attach instead of inserting a duplicate.
        for event in storedEvents where event.calendarSubscriptionID == nil
            && event.sourceSystem == "Scoutbook Calendar" && !event.externalSourceID.isEmpty {
            byExternalID[event.externalSourceID] = event
        }
        for event in subscribedEvents where !event.externalSourceID.isEmpty {
            byExternalID[event.externalSourceID] = event
        }

        var inserted = 0
        var updated = 0
        var insertedTitles: [String] = []
        var removedTitles: [String] = []
        var detachedTitles: [String] = []
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
                insertedTitles.append("\(source.title) (\(source.startDate.formatted(date: .numeric, time: .omitted)))")
            }
            // A detached event may carry notes the treasurer typed; do not blank them when the feed has none.
            let wasDetached = event.calendarSubscriptionID == nil
            event.name = source.title
            event.category = "Scoutbook Calendar"
            event.startDate = source.startDate
            event.endDate = source.endDate
            event.location = source.location
            if !(wasDetached && source.notes.isEmpty) { event.notes = source.notes }
            if event.closedAt == nil { event.status = source.isCancelled ? .cancelled : .planning }
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
            let label = "\(event.name) (\(event.startDate.formatted(date: .numeric, time: .omitted)))"
            if canDelete(event, dependencies: dependencies) {
                modelContext.delete(event)
                removed += 1
                removedTitles.append(label)
            } else {
                event.calendarSubscriptionID = nil
                event.isReadOnly = false
                detached += 1
                detachedTitles.append(label)
            }
        }

        return CalendarSyncResult(
            inserted: inserted,
            updated: updated,
            removed: removed,
            detached: detached,
            eventCount: feedEvents.count,
            insertedTitles: insertedTitles,
            removedTitles: removedTitles,
            detachedTitles: detachedTitles
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

    /// Feeds produced by Outlook/Exchange label times with Windows zone names, which Foundation does not know.
    /// Falling back to the local zone shifted every meeting for a troop whose feed came from another region.
    static let windowsTimeZones: [String: String] = [
        "Eastern Standard Time": "America/New_York", "Central Standard Time": "America/Chicago",
        "Mountain Standard Time": "America/Denver", "US Mountain Standard Time": "America/Phoenix",
        "Pacific Standard Time": "America/Los_Angeles", "Alaskan Standard Time": "America/Anchorage",
        "Hawaiian Standard Time": "Pacific/Honolulu", "Atlantic Standard Time": "America/Halifax",
        "Newfoundland Standard Time": "America/St_Johns", "GMT Standard Time": "Europe/London",
        "W. Europe Standard Time": "Europe/Berlin", "Central Europe Standard Time": "Europe/Budapest",
        "Romance Standard Time": "Europe/Paris", "UTC": "UTC", "Coordinated Universal Time": "UTC",
    ]

    static func timeZone(forTZID identifier: String) -> TimeZone? {
        let trimmed = identifier.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"/"))
        return TimeZone(identifier: trimmed) ?? windowsTimeZones[trimmed].flatMap(TimeZone.init(identifier:))
    }

    private static func parseDate(_ value: String, parameters: [String: String]) -> (date: Date, isDateOnly: Bool)? {
        let isDateOnly = parameters["VALUE"]?.uppercased() == "DATE" || (value.count == 8 && !value.contains("T"))
        let timeZone = parameters["TZID"].flatMap(timeZone(forTZID:)) ?? .current
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

    /// Parses an RFC 5545 duration such as `PT1H30M`, `P1D`, or `P2W` into seconds.
    static func parseDuration(_ value: String) -> TimeInterval? {
        var text = Substring(value.trimmingCharacters(in: .whitespaces).uppercased())
        var sign: Double = 1
        if text.hasPrefix("-") { sign = -1; text = text.dropFirst() } else if text.hasPrefix("+") { text = text.dropFirst() }
        guard text.hasPrefix("P") else { return nil }
        text = text.dropFirst()
        var total: Double = 0
        var number = ""
        var inTime = false
        var sawComponent = false
        for character in text {
            if character.isNumber { number.append(character); continue }
            if character == "T" { inTime = true; continue }
            guard let amount = Double(number) else { return nil }
            number = ""
            sawComponent = true
            switch (character, inTime) {
            case ("W", false): total += amount * 7 * 86_400
            case ("D", false): total += amount * 86_400
            case ("H", true): total += amount * 3_600
            case ("M", true): total += amount * 60
            case ("S", true): total += amount
            default: return nil
            }
        }
        guard number.isEmpty, sawComponent else { return nil }
        return sign * total
    }

    private static func expand(_ event: ScoutbookCalendarEvent, rule: String?, exclusions: [Date] = []) -> [ScoutbookCalendarEvent] {
        let calendarForExclusions = Calendar.current
        func isExcluded(_ start: Date) -> Bool {
            exclusions.contains { excluded in
                event.isAllDay ? calendarForExclusions.isDate(excluded, inSameDayAs: start) : abs(excluded.timeIntervalSince(start)) < 1
            }
        }
        guard let rule else { return [event] }
        // A feed line such as `RRULE:FREQ=WEEKLY;FREQ=DAILY` must not trap; keep the first value for a repeated key.
        let values = Dictionary(rule.split(separator: ";").compactMap { component -> (String, String)? in
            let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
            return pair.count == 2 ? (pair[0].uppercased(), pair[1]) : nil
        }, uniquingKeysWith: { first, _ in first })
        guard let frequency = values["FREQ"]?.uppercased() else { return [event] }
        let interval = max(1, Int(values["INTERVAL"] ?? "1") ?? 1)
        let count = min(500, max(1, Int(values["COUNT"] ?? "500") ?? 500))
        // A date-only UNTIL covers its whole day; treating it as midnight dropped the final occurrence.
        let until: Date? = values["UNTIL"].flatMap { value in
            guard let parsed = parseDate(value, parameters: [:]) else { return nil }
            guard parsed.isDateOnly, let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: parsed.date) else { return parsed.date }
            return nextDay.addingTimeInterval(-1)
        }
        let horizon = Calendar.current.date(byAdding: .year, value: 2, to: Date()) ?? Date().addingTimeInterval(63_072_000)
        let component: Calendar.Component
        switch frequency {
        case "DAILY": component = .day
        case "WEEKLY": component = .weekOfYear
        case "MONTHLY": component = .month
        case "YEARLY": component = .year
        default: return [event]
        }

        let calendar = Calendar.current
        let duration = event.endDate.timeIntervalSince(event.startDate)
        // All-day spans are measured in calendar days; adding raw seconds shifts the end by an hour across a
        // daylight-saving change and drops the last day of a multi-day occurrence.
        let dayCount = calendar.dateComponents([.day], from: calendar.startOfDay(for: event.startDate), to: calendar.startOfDay(for: event.endDate)).day ?? 0
        func occurrence(startingAt start: Date) -> ScoutbookCalendarEvent {
            let end = event.isAllDay
                ? (calendar.date(byAdding: .day, value: dayCount, to: start) ?? start.addingTimeInterval(duration))
                : start.addingTimeInterval(duration)
            return ScoutbookCalendarEvent(
                externalID: "\(event.externalID)#\(Int(start.timeIntervalSince1970))",
                title: event.title,
                startDate: start,
                endDate: end,
                location: event.location,
                notes: event.notes,
                isAllDay: event.isAllDay,
                modifiedAt: event.modifiedAt,
                isCancelled: event.isCancelled
            )
        }

        // Candidate start dates in order. WEEKLY rules may name several weekdays (BYDAY=MO,WE); a rule that
        // only repeated the DTSTART weekday silently dropped the other meeting nights.
        let byDays: [Int] = frequency == "WEEKLY"
            ? (values["BYDAY"] ?? "").split(separator: ",").compactMap { token in
                let code = token.trimmingCharacters(in: .whitespaces).suffix(2).uppercased()
                return ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7][code]
            }
            : []
        // MONTHLY rules such as "the second Tuesday" (BYDAY=2TU) or "the last Friday" (BYDAY=-1FR).
        let monthlyWeekdays: [(ordinal: Int, weekday: Int)] = frequency == "MONTHLY"
            ? (values["BYDAY"] ?? "").split(separator: ",").compactMap { token in
                let text = token.trimmingCharacters(in: .whitespaces).uppercased()
                guard text.count >= 3, let weekday = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7][String(text.suffix(2))],
                      let ordinal = Int(text.dropLast(2)), ordinal != 0, abs(ordinal) <= 5 else { return nil }
                return (ordinal, weekday)
            }
            : []
        // MONTHLY rules such as "the 1st and 15th" or "the last day" (BYMONTHDAY=-1).
        let byMonthDays: [Int] = frequency == "MONTHLY"
            ? (values["BYMONTHDAY"] ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 != 0 && abs($0) <= 31 }
            : []
        func candidates() -> [Date] {
            var dates: [Date] = []
            // COUNT sizes the recurrence set before EXDATE removes members from it, so generate exactly
            // COUNT candidates and let the exclusions thin them out afterwards.
            if !monthlyWeekdays.isEmpty {
                var month = 0
                let timeParts = calendar.dateComponents([.hour, .minute, .second], from: event.startDate)
                while dates.count < count, month < 1_200 {
                    guard let monthStart = calendar.date(byAdding: .month, value: month * interval, to: calendar.date(from: calendar.dateComponents([.year, .month], from: event.startDate)) ?? event.startDate),
                          let dayRange = calendar.range(of: .day, in: .month, for: monthStart) else { break }
                    var inMonth: [Date] = []
                    for rule in monthlyWeekdays {
                        // Collect every matching weekday in the month, then take the nth from the front or back.
                        var matches: [Date] = []
                        for day in dayRange {
                            var components = calendar.dateComponents([.year, .month], from: monthStart)
                            components.day = day
                            components.hour = timeParts.hour
                            components.minute = timeParts.minute
                            components.second = timeParts.second
                            if let date = calendar.date(from: components), calendar.component(.weekday, from: date) == rule.weekday { matches.append(date) }
                        }
                        let index = rule.ordinal > 0 ? rule.ordinal - 1 : matches.count + rule.ordinal
                        if matches.indices.contains(index), matches[index] >= event.startDate { inMonth.append(matches[index]) }
                    }
                    let sorted = inMonth.sorted()
                    if let first = sorted.first, first > horizon || (until.map { first > $0 } ?? false) { break }
                    dates.append(contentsOf: sorted.filter { date in date <= horizon && (until.map { date <= $0 } ?? true) })
                    month += 1
                }
                return Array(dates.prefix(count))
            }
            if !byMonthDays.isEmpty {
                var month = 0
                let timeParts = calendar.dateComponents([.hour, .minute, .second], from: event.startDate)
                while dates.count < count, month < 1_200 {
                    guard let monthStart = calendar.date(byAdding: .month, value: month * interval, to: calendar.date(from: calendar.dateComponents([.year, .month], from: event.startDate)) ?? event.startDate),
                          let dayRange = calendar.range(of: .day, in: .month, for: monthStart) else { break }
                    var inMonth: [Date] = []
                    for requested in byMonthDays {
                        let day = requested > 0 ? requested : dayRange.count + 1 + requested
                        guard dayRange.contains(day) else { continue }
                        var components = calendar.dateComponents([.year, .month], from: monthStart)
                        components.day = day
                        components.hour = timeParts.hour
                        components.minute = timeParts.minute
                        components.second = timeParts.second
                        if let date = calendar.date(from: components), date >= event.startDate { inMonth.append(date) }
                    }
                    let sorted = inMonth.sorted()
                    if let first = sorted.first, first > horizon || (until.map { first > $0 } ?? false) { break }
                    dates.append(contentsOf: sorted.filter { date in date <= horizon && (until.map { date <= $0 } ?? true) })
                    month += 1
                }
                return Array(dates.prefix(count))
            }
            if byDays.isEmpty {
                var index = 0
                while dates.count < count {
                    guard let start = calendar.date(byAdding: component, value: index * interval, to: event.startDate) else { break }
                    if start > horizon || (until.map { start > $0 } ?? false) { break }
                    dates.append(start)
                    index += 1
                }
                return dates
            }
            var week = 0
            while dates.count < count, week < 2_000 {
                guard let weekStart = calendar.date(byAdding: .weekOfYear, value: week * interval, to: event.startDate) else { break }
                var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear, .hour, .minute, .second], from: weekStart)
                var inWeek: [Date] = []
                for weekday in byDays {
                    components.weekday = weekday
                    if let date = calendar.date(from: components), date >= event.startDate { inWeek.append(date) }
                }
                let sorted = inWeek.sorted()
                if let first = sorted.first, first > horizon || (until.map { first > $0 } ?? false) { break }
                dates.append(contentsOf: sorted.filter { date in date <= horizon && (until.map { date <= $0 } ?? true) })
                week += 1
            }
            return Array(dates.prefix(count))
        }

        var results: [ScoutbookCalendarEvent] = []
        for start in candidates() {
            if let until, start > until { break }
            if start > horizon { break }
            if isExcluded(start) { continue }
            results.append(occurrence(startingAt: start))
        }
        return results.isEmpty ? [event] : results
    }

    private static func stableID(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
