import CryptoKit
import Foundation
import SwiftData

enum ScoutbookCSVKind: String, CaseIterable, Identifiable {
    case members = "Scouts / Members"
    case leadersAndParents = "Leaders & Parents"
    case paymentLog = "Payment Log"

    var id: String { rawValue }
}

struct ScoutbookCSVRow: Identifiable {
    let id: Int
    let values: [String: String]

    func value(_ aliases: [String]) -> String {
        for alias in aliases {
            let key = ScoutbookCSVDocument.normalizedHeader(alias)
            if let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return ""
    }
}

struct ScoutbookCSVDocument {
    let sourceName: String
    let fingerprint: String
    let headers: [String]
    let rows: [ScoutbookCSVRow]
    let detectedKind: ScoutbookCSVKind

    static func normalizedHeader(_ header: String) -> String {
        String(
            header.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber }
        ).lowercased()
    }
}

struct ScoutbookImportPreview {
    let document: ScoutbookCSVDocument
    let kind: ScoutbookCSVKind
    let validRowCount: Int
    let issues: [String]

    var invalidRowCount: Int { document.rows.count - validRowCount }
}

struct ScoutbookImportResult {
    let inserted: Int
    let updated: Int
    let skipped: Int
    let issues: [String]
}

enum ScoutbookImportError: LocalizedError, Equatable {
    case fileTooLarge
    case unreadableText
    case emptyFile
    case unsupportedHeaders
    case alreadyImported
    case noImportableRows

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: "The selected file is larger than the 5 MB import limit. Export a smaller date range from Scoutbook."
        case .unreadableText: "The selected file could not be decoded as a text CSV or TSV file."
        case .emptyFile: "The selected export contains no data rows."
        case .unsupportedHeaders: "The file does not contain recognizable Scoutbook roster or payment-log columns."
        case .alreadyImported: "This exact Scoutbook export has already been imported."
        case .noImportableRows: "No rows passed validation. Review the preview issues and export type."
        }
    }
}

enum ScoutbookImporter {
    private static let firstNameAliases = ["First Name", "First", "Given Name", "Member First Name"]
    private static let lastNameAliases = ["Last Name", "Last", "Surname", "Family Name", "Member Last Name"]
    private static let fullNameAliases = ["Name", "Member Name", "Person", "Scout Name", "Leader Name", "Parent Name"]
    private static let memberIDAliases = ["Member ID", "BSA Member ID", "Scouting Member ID", "BSA ID", "Person ID"]
    private static let dateAliases = ["Date", "Transaction Date", "Entry Date", "Posted Date", "Created Date"]
    private static let amountAliases = ["Amount", "Transaction Amount", "Value", "Debit/Credit", "Debit Credit"]

    static let maximumFileBytes = 5 * 1_024 * 1_024

    static func parse(data: Data, sourceName: String) throws -> ScoutbookCSVDocument {
        guard data.count <= maximumFileBytes else { throw ScoutbookImportError.fileTooLarge }
        guard let text = decode(data) else { throw ScoutbookImportError.unreadableText }
        let commaCount = text.prefix(2_000).filter { $0 == "," }.count
        let tabCount = text.prefix(2_000).filter { $0 == "\t" }.count
        let delimiter: Character = tabCount > commaCount ? "\t" : ","
        let table = parseTable(text, delimiter: delimiter)
        guard let rawHeaders = table.first, !rawHeaders.isEmpty else { throw ScoutbookImportError.emptyFile }

        let headers = rawHeaders.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let normalizedHeaders = headers.map(ScoutbookCSVDocument.normalizedHeader)
        let rows = table.dropFirst().enumerated().compactMap { offset, cells -> ScoutbookCSVRow? in
            guard cells.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
            var values: [String: String] = [:]
            for (index, header) in normalizedHeaders.enumerated() where !header.isEmpty {
                values[header] = index < cells.count ? cells[index] : ""
            }
            return ScoutbookCSVRow(id: offset + 2, values: values)
        }
        guard !rows.isEmpty else { throw ScoutbookImportError.emptyFile }

        let kind = try detectKind(headers: normalizedHeaders, sourceName: sourceName)
        return ScoutbookCSVDocument(
            sourceName: sourceName,
            fingerprint: sha256(data),
            headers: headers,
            rows: rows,
            detectedKind: kind
        )
    }

    static func preview(document: ScoutbookCSVDocument, kind: ScoutbookCSVKind) -> ScoutbookImportPreview {
        var valid = 0
        var issues: [String] = []
        for row in document.rows {
            switch kind {
            case .members, .leadersAndParents:
                let name = parsedName(row)
                if name.first.isEmpty && name.last.isEmpty {
                    issues.append("Row \(row.id): missing member name")
                } else {
                    valid += 1
                }
            case .paymentLog:
                let name = parsedName(row)
                let memberID = row.value(memberIDAliases)
                guard !name.first.isEmpty || !name.last.isEmpty || !memberID.isEmpty else {
                    issues.append("Row \(row.id): missing member name or ID")
                    continue
                }
                guard parsedDate(row.value(dateAliases)) != nil else {
                    issues.append("Row \(row.id): unrecognized transaction date")
                    continue
                }
                guard let cents = parsedCents(row.value(amountAliases)), cents != 0, cents != Int64.min else {
                    issues.append("Row \(row.id): unrecognized or zero amount")
                    continue
                }
                valid += 1
            }
        }
        return ScoutbookImportPreview(document: document, kind: kind, validRowCount: valid, issues: Array(issues.prefix(50)))
    }

    @MainActor
    static func importDocument(_ document: ScoutbookCSVDocument, kind: ScoutbookCSVKind, into modelContext: ModelContext) throws -> ScoutbookImportResult {
        let previous = try modelContext.fetch(FetchDescriptor<ScoutbookImportRecord>())
        guard !previous.contains(where: { $0.sourceFingerprint == document.fingerprint }) else {
            throw ScoutbookImportError.alreadyImported
        }
        let preview = preview(document: document, kind: kind)
        guard preview.validRowCount > 0 else { throw ScoutbookImportError.noImportableRows }

        // rollback() below discards every unsaved change in the shared context, so persist unrelated
        // pending edits first; a failed import must only undo the import itself.
        if modelContext.hasChanges { try modelContext.save() }

        do {
            let result: ScoutbookImportResult
            switch kind {
            case .members, .leadersAndParents:
                result = try importPeople(document.rows, kind: kind, into: modelContext)
            case .paymentLog:
                result = try importPayments(document.rows, into: modelContext)
            }

            let record = ScoutbookImportRecord(sourceName: document.sourceName, sourceFingerprint: document.fingerprint, importKind: kind.rawValue)
            record.sourceRowCount = document.rows.count
            record.insertedCount = result.inserted
            record.updatedCount = result.updated
            record.skippedCount = result.skipped
            record.notes = result.issues.joined(separator: "\n")
            modelContext.insert(record)
            AuditLogger.record(
                .importData,
                recordType: "Scoutbook Import",
                recordID: record.id,
                summary: "Imported \(kind.rawValue) from \(document.sourceName)",
                details: AuditLogger.details([
                    ("Fingerprint", document.fingerprint),
                    ("Source rows", String(record.sourceRowCount)),
                    ("Inserted", String(record.insertedCount)),
                    ("Updated", String(record.updatedCount)),
                    ("Skipped", String(record.skippedCount)),
                    ("Issues", record.notes),
                ]),
                in: modelContext
            )
            try modelContext.save()
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    @MainActor
    private static func importPeople(_ rows: [ScoutbookCSVRow], kind: ScoutbookCSVKind, into modelContext: ModelContext) throws -> ScoutbookImportResult {
        var people = try modelContext.fetch(FetchDescriptor<PersonRecord>())
        var registrations = try modelContext.fetch(FetchDescriptor<RegistrationRecord>())
        var inserted = 0
        var updated = 0
        var skipped = 0
        var issues: [String] = []

        for row in rows {
            let name = parsedName(row)
            guard !name.first.isEmpty || !name.last.isEmpty else {
                skipped += 1
                issues.append("Row \(row.id): missing member name")
                continue
            }
            let memberID = row.value(memberIDAliases)
            let role = parsedRole(row, defaultKind: kind)
            let existing = findPerson(memberID: memberID, firstName: name.first, lastName: name.last, in: people)
            let person: PersonRecord
            if let existing {
                person = existing
                updated += 1
            } else {
                person = PersonRecord(firstName: name.first, lastName: name.last, role: role)
                modelContext.insert(person)
                people.append(person)
                inserted += 1
            }

            person.firstName = name.first
            person.lastName = name.last
            person.role = role
            if !memberID.isEmpty { person.scoutingMemberID = memberID }
            assignIfPresent(row.value(["Patrol", "Den", "Sub Unit", "Sub-Unit"]), to: &person.patrol)
            assignIfPresent(row.value(["Email", "Email Address", "Primary Email"]), to: &person.email)
            assignIfPresent(row.value(["Phone", "Phone Number", "Mobile Phone", "Cell Phone"]), to: &person.phone)
            if let joinDate = parsedDate(row.value(["Join Date", "Registration Date", "Registered On", "Start Date"])) {
                person.joinDate = joinDate
            }
            if let rank = ScoutsBSARank.matching(row.value(["Rank", "Current Rank", "Scouts BSA Rank", "Advancement Rank"])) {
                person.currentRank = rank
            }
            let statusText = row.value(["Status", "Registration Status", "Member Status"])
            person.isActive = !statusText.lowercased().contains("inactive") && !statusText.lowercased().contains("expired") && !statusText.lowercased().contains("past")

            let unitRole = row.value(["Position", "Role", "Unit Role", "Registered Position"])
            let importedPositions = parsedPositions(unitRole)
            if !importedPositions.isEmpty {
                person.troopPositions = Array(Set(person.troopPositions).union(importedPositions))
            }
            guard role != .parent else { continue }
            let expiration = parsedDate(row.value(["Expiration Date", "Expires", "Registration Expiration"]))
            let registrationDate = parsedDate(row.value(["Registration Date", "Registered On", "Start Date"])) ?? person.joinDate ?? Date()
            let explicitProgramYear = row.value(["Program Year", "Registration Year", "Year"])
            let programYear = explicitProgramYear.isEmpty
                ? String(Calendar.current.component(.year, from: expiration ?? registrationDate))
                : explicitProgramYear
            let registration: RegistrationRecord
            if let existingRegistration = registrations.first(where: {
                $0.personID == person.id && normalizedProgramYear($0.programYear) == normalizedProgramYear(programYear)
            }) {
                registration = existingRegistration
            } else {
                registration = RegistrationRecord(personID: person.id, programYear: programYear, unitRole: unitRole, status: person.isActive ? .current : .expired)
                modelContext.insert(registration)
                registrations.append(registration)
            }
            registration.unitRole = unitRole
            registration.status = person.isActive ? .current : .expired
            registration.expiresOn = expiration
            registration.registeredOn = registrationDate
            registration.sourceSheet = "Scoutbook Quick Export"
            registration.sourceRow = row.id
        }

        return ScoutbookImportResult(inserted: inserted, updated: updated, skipped: skipped, issues: issues)
    }

    @MainActor
    private static func importPayments(_ rows: [ScoutbookCSVRow], into modelContext: ModelContext) throws -> ScoutbookImportResult {
        var people = try modelContext.fetch(FetchDescriptor<PersonRecord>())
        var existingIDs = Set(try modelContext.fetch(FetchDescriptor<MemberLedgerEntry>()).filter { $0.sourceSystem == "Scoutbook" }.map(\.externalSourceID))
        var inserted = 0
        var skipped = 0
        var issues: [String] = []

        for row in rows {
            let name = parsedName(row)
            let memberID = row.value(memberIDAliases)
            guard !name.first.isEmpty || !name.last.isEmpty || !memberID.isEmpty,
                  let date = parsedDate(row.value(dateAliases)),
                  let rawCents = parsedCents(row.value(amountAliases)),
                  rawCents != 0,
                  rawCents != Int64.min else {
                skipped += 1
                issues.append("Row \(row.id): missing name/ID, date, or nonzero amount")
                continue
            }

            let transactionType = row.value(["Transaction Type", "Type", "Entry Type", "Payment Type"])
            let kind = parsedEntryKind(transactionType, signedCents: rawCents)
            let category = row.value(["Category", "Account", "Purpose", "Item"]).isEmpty
                ? "Scoutbook Payment Log"
                : row.value(["Category", "Account", "Purpose", "Item"])
            let description = row.value(["Description", "Memo", "Notes", "Comment", "Details"])
            let sourceID = stableRowID(memberID: memberID, name: name, date: date, type: transactionType, amount: rawCents, category: category, description: description)
            guard !existingIDs.contains(sourceID) else {
                skipped += 1
                continue
            }

            var person = findPerson(memberID: memberID, firstName: name.first, lastName: name.last, in: people)
            if person == nil {
                let created = PersonRecord(firstName: name.first, lastName: name.last, role: .other)
                created.scoutingMemberID = memberID
                created.notes = "Created from a Scoutbook payment-log import; confirm this person's role."
                modelContext.insert(created)
                people.append(created)
                person = created
            }

            let entry = MemberLedgerEntry(personID: person?.id, date: date, kind: kind, amountCents: abs(rawCents), category: category)
            entry.notes = [transactionType, description].filter { !$0.isEmpty }.joined(separator: ": ")
            entry.sourceSheet = "Scoutbook Payment Log"
            entry.sourceRow = row.id
            entry.sourceSystem = "Scoutbook"
            entry.externalSourceID = sourceID
            modelContext.insert(entry)
            existingIDs.insert(sourceID)
            inserted += 1
        }

        return ScoutbookImportResult(inserted: inserted, updated: 0, skipped: skipped, issues: issues)
    }

    private static func detectKind(headers: [String], sourceName: String) throws -> ScoutbookCSVKind {
        let set = Set(headers)
        let hasAmount = amountAliases.map(ScoutbookCSVDocument.normalizedHeader).contains(where: set.contains)
        let hasDate = dateAliases.map(ScoutbookCSVDocument.normalizedHeader).contains(where: set.contains)
        if hasAmount && hasDate { return .paymentLog }

        let hasName = (firstNameAliases + lastNameAliases + fullNameAliases).map(ScoutbookCSVDocument.normalizedHeader).contains(where: set.contains)
        let hasMemberID = memberIDAliases.map(ScoutbookCSVDocument.normalizedHeader).contains(where: set.contains)
        guard hasName || hasMemberID else { throw ScoutbookImportError.unsupportedHeaders }
        let lowerName = sourceName.lowercased()
        if lowerName.contains("leader") || lowerName.contains("parent") { return .leadersAndParents }
        return .members
    }

    private static func decode(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8.removingPrefix("\u{feff}") }
        if let windows = String(data: data, encoding: .windowsCP1252) { return windows }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Longest value kept for a single cell; see `GeneralSpreadsheetImporter.maximumCellLength`.
    static let maximumCellLength = GeneralSpreadsheetImporter.maximumCellLength

    private static func parseTable(_ text: String, delimiter: Character) -> [[String]] {
        var result: [[String]] = []
        var row: [String] = []
        var field = ""
        var fieldLength = 0
        var quoted = false
        let characters = Array(text)
        var index = 0
        func append(_ character: Character) {
            if fieldLength < maximumCellLength { field.append(character) }
            fieldLength += 1
        }
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count && characters[index + 1] == "\"" {
                        append("\"")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    append(character)
                }
            } else if character == "\"" && field.isEmpty {
                quoted = true
            } else if character == delimiter {
                row.append(field)
                field = ""
                fieldLength = 0
            } else if character == "\n" || character == "\r" {
                // Accept LF, CRLF, and bare CR line endings; a bare-CR export used to collapse into one row.
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
                row.append(field)
                result.append(row)
                row = []
                field = ""
                fieldLength = 0
            } else {
                append(character)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            result.append(row)
        }
        return result
    }

    private static func parsedName(_ row: ScoutbookCSVRow) -> (first: String, last: String) {
        let first = row.value(firstNameAliases)
        let last = row.value(lastNameAliases)
        if !first.isEmpty || !last.isEmpty { return (first, last) }
        let full = row.value(fullNameAliases)
        if full.contains(",") {
            let parts = full.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return (parts.count > 1 ? parts[1] : "", parts[0])
        }
        let parts = full.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count > 1 else { return (parts.first ?? "", "") }
        return (parts.dropLast().joined(separator: " "), parts.last ?? "")
    }

    private static func parsedRole(_ row: ScoutbookCSVRow, defaultKind: ScoutbookCSVKind) -> PersonRole {
        let memberType = row.value(["Member Type", "Registration Type", "Type"]).lowercased()
        if memberType.contains("parent") || memberType.contains("guardian") { return .parent }
        if memberType.contains("scout") || memberType.contains("youth") || memberType.contains("cub") { return .scout }
        if memberType.contains("leader") || memberType.contains("adult") { return .leader }

        let value = row.value(["Role", "Position", "Unit Role", "Registered Position"]).lowercased()
        if value.contains("parent") || value.contains("guardian") { return .parent }
        if value.contains("scout") || value.contains("youth") || value.contains("cub") { return .scout }
        if value.contains("leader") || value.contains("adult") || value.contains("committee") || value.contains("master") || value.contains("advisor") { return .leader }
        if let position = TroopPosition.matching(value) {
            return position.category == .youth ? .scout : .leader
        }
        return defaultKind == .members ? .scout : .leader
    }

    private static func parsedPositions(_ value: String) -> Set<TroopPosition> {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        if let exact = TroopPosition.matching(value) { return [exact] }
        return Set(
            value.components(separatedBy: CharacterSet(charactersIn: ",;|"))
                .compactMap(TroopPosition.matching)
        )
    }

    private static func parsedEntryKind(_ type: String, signedCents: Int64) -> MemberEntryKind {
        let value = type.lowercased()
        if value.contains("charge") || value.contains("fee") || value.contains("debit") { return .charge }
        if value.contains("payment") || value.contains("paid") || value.contains("received") { return .payment }
        if value.contains("credit") { return .credit }
        if value.contains("write off") || value.contains("decrease") || value.contains("refund") { return .adjustmentDecrease }
        return signedCents < 0 ? .charge : .payment
    }

    private static func parsedDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        // A `yyyy` pattern happily accepts a two-digit year ("1/15/24" becomes 15 January 0024), so every
        // candidate is checked for a plausible year before the two-digit `yy` patterns get their turn.
        let formats = [
            "M/d/yyyy h:mm a", "M/d/yyyy H:mm", "M/d/yyyy", "MM/dd/yyyy",
            "M/d/yy h:mm a", "M/d/yy H:mm", "M/d/yy",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd",
        ]
        let calendar = Calendar(identifier: .gregorian)
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.dateFormat = format
            if let date = formatter.date(from: value), (1900...2200).contains(calendar.component(.year, from: date)) {
                return date
            }
        }
        return nil
    }

    private static func parsedCents(_ value: String) -> Int64? {
        guard !value.isEmpty else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let negative = trimmed.hasPrefix("(") && trimmed.hasSuffix(")")
        let cleaned = trimmed.replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "(", with: "-")
            .replacingOccurrences(of: ")", with: "")
        guard let decimal = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var value = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        // int64Value silently wraps for out-of-range decimals, turning "99999999999999999999" into garbage cents.
        guard rounded <= Decimal(Money.maximumCents), rounded >= Decimal(-Money.maximumCents) else { return nil }
        let cents = NSDecimalNumber(decimal: rounded).int64Value
        return negative && cents > 0 ? -cents : cents
    }

    private static func findPerson(memberID: String, firstName: String, lastName: String, in people: [PersonRecord]) -> PersonRecord? {
        let target = normalizedName(firstName: firstName, lastName: lastName)
        if !memberID.isEmpty {
            if let match = people.first(where: { $0.scoutingMemberID == memberID }) { return match }
            // A matching name with a different nonblank member ID is a different person, not an update.
            let unnamedIDMatches = people.filter {
                $0.scoutingMemberID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && normalizedName(firstName: $0.firstName, lastName: $0.lastName) == target
            }
            return unnamedIDMatches.count == 1 ? unnamedIDMatches[0] : nil
        }
        guard !target.isEmpty else { return nil }
        let matches = people.filter { normalizedName(firstName: $0.firstName, lastName: $0.lastName) == target }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func normalizedName(firstName: String, lastName: String) -> String {
        String(
            "\(firstName) \(lastName)".folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber }
        ).lowercased()
    }

    private static func normalizedProgramYear(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func stableRowID(memberID: String, name: (first: String, last: String), date: Date, type: String, amount: Int64, category: String, description: String) -> String {
        let key = [memberID, name.first, name.last, ISO8601DateFormatter().string(from: date), type, String(amount), category, description].joined(separator: "|")
        return sha256(Data(key.utf8))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func assignIfPresent(_ newValue: String, to value: inout String) {
        if !newValue.isEmpty { value = newValue }
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
