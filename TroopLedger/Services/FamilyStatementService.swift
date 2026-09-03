import CoreGraphics
import CoreText
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct FamilyStatementSnapshot {
    struct ActivityRow: Identifiable {
        let id: UUID
        let date: Date
        let memberName: String
        let kind: MemberEntryKind
        let description: String
        let balanceEffectCents: Int64
        let runningBalanceCents: Int64
    }

    struct UpcomingRow: Identifiable {
        let id: UUID
        let date: Date
        let memberName: String
        let description: String
        let amountCents: Int64
    }

    let familyID: UUID
    let troop: TroopReportIdentity
    let familyName: String
    let memberNames: [String]
    let periodStart: Date
    let asOfDate: Date
    let generatedAt: Date
    let beginningBalanceCents: Int64
    let newChargesCents: Int64
    let paymentsAndCreditsCents: Int64
    let balanceAdjustmentsCents: Int64
    let currentBalanceCents: Int64
    let activity: [ActivityRow]
    let upcoming: [UpcomingRow]

    var periodLabel: String {
        "\(periodStart.formatted(date: .abbreviated, time: .omitted)) through \(asOfDate.formatted(date: .abbreviated, time: .omitted))"
    }
}

enum FamilyStatementError: LocalizedError, Equatable {
    case noMembers
    case invalidPeriod
    case asOfDateInFuture

    var errorDescription: String? {
        switch self {
        case .noMembers: "Assign at least one person to this family before creating a statement."
        case .invalidPeriod: "The statement start date must be on or before its as-of date."
        case .asOfDateInFuture: "A statement cannot be dated in the future; future charges would be presented as amounts already due."
        }
    }
}

enum FamilyStatementService {
    static func makeSnapshot(
        family: FamilyRecord,
        people: [PersonRecord],
        entries: [MemberLedgerEntry],
        events: [EventRecord],
        periodStart: Date,
        asOfDate: Date,
        troopProfile: TroopProfileRecord? = nil,
        generatedAt: Date = Date(),
        calendar: Calendar = .current,
        now: Date = Date()
    ) throws -> FamilyStatementSnapshot {
        let members = people
            .filter { $0.familyID == family.id }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        guard !members.isEmpty else { throw FamilyStatementError.noMembers }

        let start = calendar.startOfDay(for: periodStart)
        let asOf = calendar.startOfDay(for: asOfDate)
        guard start <= asOf else { throw FamilyStatementError.invalidPeriod }
        guard asOf <= calendar.startOfDay(for: now) else { throw FamilyStatementError.asOfDateInFuture }
        guard let dayAfterAsOf = calendar.date(byAdding: .day, value: 1, to: asOf) else {
            throw FamilyStatementError.invalidPeriod
        }

        let namesByID = Dictionary(members.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let eventNamesByID = Dictionary(events.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let familyEntries = entries.filter { entry in
            entry.personID.map { namesByID[$0] != nil } ?? false
        }
        let beginningBalance = familyEntries
            .filter { $0.date < start }
            .reduce(Int64(0)) { $0 + $1.balanceEffectCents }
        let periodEntries = familyEntries
            .filter { $0.date >= start && $0.date < dayAfterAsOf }
            .sorted(by: entrySort)

        var runningBalance = beginningBalance
        let activity = periodEntries.map { entry in
            runningBalance += entry.balanceEffectCents
            return FamilyStatementSnapshot.ActivityRow(
                id: entry.id,
                date: entry.date,
                memberName: entry.personID.flatMap { namesByID[$0] } ?? "Unknown member",
                kind: entry.kind,
                description: description(for: entry, eventNamesByID: eventNamesByID),
                balanceEffectCents: entry.balanceEffectCents,
                runningBalanceCents: runningBalance
            )
        }

        let upcoming = familyEntries
            .filter { $0.kind == .charge && $0.date >= dayAfterAsOf }
            .sorted(by: entrySort)
            .map { entry in
                FamilyStatementSnapshot.UpcomingRow(
                    id: entry.id,
                    date: entry.date,
                    memberName: entry.personID.flatMap { namesByID[$0] } ?? "Unknown member",
                    description: description(for: entry, eventNamesByID: eventNamesByID),
                    amountCents: entry.amountCents
                )
            }

        return FamilyStatementSnapshot(
            familyID: family.id,
            troop: TroopReportIdentity(profile: troopProfile),
            familyName: family.name,
            memberNames: members.map(\.displayName),
            periodStart: start,
            asOfDate: asOf,
            generatedAt: generatedAt,
            beginningBalanceCents: beginningBalance,
            newChargesCents: periodEntries.filter { $0.kind == .charge }.reduce(0) { $0 + $1.amountCents },
            paymentsAndCreditsCents: periodEntries.filter { $0.kind == .payment || $0.kind == .credit }.reduce(0) { $0 + $1.amountCents },
            balanceAdjustmentsCents: periodEntries.filter { $0.kind == .adjustmentIncrease || $0.kind == .adjustmentDecrease }.reduce(0) { $0 + $1.balanceEffectCents },
            currentBalanceCents: runningBalance,
            activity: activity,
            upcoming: upcoming
        )
    }

    static func defaultFilename(for snapshot: FamilyStatementSnapshot, calendar: Calendar = .current) -> String {
        let safeName = snapshot.familyName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        // asOfDate is local midnight; ISO 8601 formatting uses UTC and names the file for the previous day east of Greenwich.
        let components = calendar.dateComponents([.year, .month, .day], from: snapshot.asOfDate)
        let date = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        return "\(safeName.isEmpty ? "Family" : safeName)-Statement-\(date).pdf"
    }

    private static func entrySort(_ lhs: MemberLedgerEntry, _ rhs: MemberLedgerEntry) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Charge and payment notes are the treasurer's working remarks and stay internal; adjustment reasons are
    /// written for the family and belong on the statement.
    private static func description(for entry: MemberLedgerEntry, eventNamesByID: [UUID: String]) -> String {
        let isAdjustment = entry.kind == .adjustmentIncrease || entry.kind == .adjustmentDecrease
        return ([entry.category, entry.eventID.flatMap { eventNamesByID[$0] }, isAdjustment ? entry.notes : nil] as [String?])
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { values, value in
                if !values.contains(value) { values.append(value) }
            }
            .joined(separator: " - ")
    }
}

struct FamilyStatementPDFDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum FamilyStatementPDFRenderer {
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 36
    private static let contentWidth = pageSize.width - margin * 2
    private static let rowHeight: CGFloat = 27

    static func render(_ statement: FamilyStatementSnapshot) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        var page = 0
        var activityIndex = 0
        var upcomingIndex = 0
        var drewUpcomingHeading = false

        repeat {
            page += 1
            context.beginPDFPage(nil)
            var top = drawHeader(statement, page: page, context: context)

            if page == 1 {
                top = drawSummary(statement, top: top, context: context)
                drawSectionTitle("Statement activity", top: top, context: context)
                top -= 24
                drawActivityHeader(top: top, context: context)
                top -= 22
            } else if activityIndex < statement.activity.count {
                drawSectionTitle("Statement activity - continued", top: top, context: context)
                top -= 24
                drawActivityHeader(top: top, context: context)
                top -= 22
            } else if drewUpcomingHeading && upcomingIndex < statement.upcoming.count {
                drawSectionTitle("Upcoming due items - continued", top: top, context: context)
                top -= 24
                drawUpcomingHeader(top: top, context: context)
                top -= 22
            }

            if statement.activity.isEmpty && page == 1 {
                drawText("No charges, payments, credits, or adjustments in this period.", in: CGRect(x: margin, y: top - 16, width: contentWidth, height: 16), size: 9, color: gray(0.35), context: context)
                top -= 36
            }

            while activityIndex < statement.activity.count, top - rowHeight >= 64 {
                drawActivityRow(statement.activity[activityIndex], top: top, context: context)
                activityIndex += 1
                top -= rowHeight
            }

            if activityIndex == statement.activity.count && !drewUpcomingHeading && top >= 142 {
                top -= 10
                drawSectionTitle("Upcoming due items", top: top, context: context)
                top -= 24
                drewUpcomingHeading = true
                if statement.upcoming.isEmpty {
                    drawText("No future-dated charges are currently recorded.", in: CGRect(x: margin, y: top - 16, width: contentWidth, height: 16), size: 9, color: gray(0.35), context: context)
                    top -= 30
                } else {
                    drawUpcomingHeader(top: top, context: context)
                    top -= 22
                }
            }

            while drewUpcomingHeading, upcomingIndex < statement.upcoming.count, top - rowHeight >= 64 {
                drawUpcomingRow(statement.upcoming[upcomingIndex], top: top, context: context)
                upcomingIndex += 1
                top -= rowHeight
            }

            drawFooter(statement, page: page, context: context)
            context.endPDFPage()
        } while activityIndex < statement.activity.count || upcomingIndex < statement.upcoming.count || !drewUpcomingHeading

        context.closePDF()
        return data as Data
    }

    private static func drawHeader(_ statement: FamilyStatementSnapshot, page: Int, context: CGContext) -> CGFloat {
        drawText(statement.troop.formalName, in: CGRect(x: margin, y: 758, width: 330, height: 18), size: 11, bold: true, color: gray(0.25), context: context)
        drawText("FAMILY STATEMENT", in: CGRect(x: 360, y: 758, width: 216, height: 18), size: 10, bold: true, alignment: .right, color: gray(0.25), context: context)
        if !statement.troop.organizationLine.isEmpty {
            drawText(statement.troop.organizationLine, in: CGRect(x: margin, y: 744, width: 520, height: 13), size: 7.5, color: gray(0.4), context: context)
        }
        if !statement.troop.mailingAddress.isEmpty {
            drawText(statement.troop.mailingAddress, in: CGRect(x: margin, y: 731, width: 520, height: 13), size: 7.5, color: gray(0.4), context: context)
        }
        drawText(statement.familyName, in: CGRect(x: margin, y: 696, width: contentWidth, height: 30), size: 22, bold: true, context: context)
        drawText("Members: \(statement.memberNames.joined(separator: ", "))", in: CGRect(x: margin, y: 672, width: contentWidth, height: 18), size: 9, color: gray(0.35), context: context)
        drawText("Statement period: \(statement.periodLabel)", in: CGRect(x: margin, y: 652, width: 360, height: 18), size: 9, context: context)
        drawText("Page \(page)", in: CGRect(x: 480, y: 652, width: 96, height: 18), size: 9, alignment: .right, context: context)
        context.setStrokeColor(gray(0.72))
        context.setLineWidth(0.7)
        context.move(to: CGPoint(x: margin, y: 644))
        context.addLine(to: CGPoint(x: pageSize.width - margin, y: 644))
        context.strokePath()
        return 626
    }

    private static func drawSummary(_ statement: FamilyStatementSnapshot, top: CGFloat, context: CGContext) -> CGFloat {
        let boxHeight: CGFloat = 72
        context.setFillColor(gray(0.96))
        context.fill(CGRect(x: margin, y: top - boxHeight, width: contentWidth, height: boxHeight))
        let labels = ["Beginning balance", "New charges", "Payments & credits", "Adjustments", "Current balance"]
        let values = [statement.beginningBalanceCents, statement.newChargesCents, -statement.paymentsAndCreditsCents, statement.balanceAdjustmentsCents, statement.currentBalanceCents]
        let columnWidth = contentWidth / CGFloat(labels.count)
        for index in labels.indices {
            let x = margin + CGFloat(index) * columnWidth
            drawText(labels[index], in: CGRect(x: x + 7, y: top - 26, width: columnWidth - 14, height: 14), size: 7.5, color: gray(0.35), context: context)
            drawText(Money.currency(cents: values[index]), in: CGRect(x: x + 7, y: top - 52, width: columnWidth - 14, height: 20), size: index == labels.count - 1 ? 11 : 9, bold: index == labels.count - 1, context: context)
        }
        let status = statement.currentBalanceCents > 0 ? "Amount due to troop" : statement.currentBalanceCents < 0 ? "Family credit" : "Paid in full"
        drawText(status, in: CGRect(x: margin, y: top - boxHeight - 18, width: contentWidth, height: 14), size: 8, bold: true, alignment: .right, color: gray(0.3), context: context)
        return top - boxHeight - 40
    }

    private static func drawSectionTitle(_ title: String, top: CGFloat, context: CGContext) {
        drawText(title, in: CGRect(x: margin, y: top - 18, width: contentWidth, height: 18), size: 11, bold: true, context: context)
    }

    private static func drawActivityHeader(top: CGFloat, context: CGContext) {
        drawTableBackground(top: top, context: context)
        drawText("DATE", in: CGRect(x: 40, y: top - 17, width: 54, height: 14), size: 7, bold: true, context: context)
        drawText("MEMBER", in: CGRect(x: 98, y: top - 17, width: 92, height: 14), size: 7, bold: true, context: context)
        drawText("DESCRIPTION", in: CGRect(x: 194, y: top - 17, width: 174, height: 14), size: 7, bold: true, context: context)
        drawText("ACTIVITY", in: CGRect(x: 372, y: top - 17, width: 84, height: 14), size: 7, bold: true, alignment: .right, context: context)
        drawText("BALANCE", in: CGRect(x: 462, y: top - 17, width: 110, height: 14), size: 7, bold: true, alignment: .right, context: context)
    }

    private static func drawActivityRow(_ row: FamilyStatementSnapshot.ActivityRow, top: CGFloat, context: CGContext) {
        drawRule(y: top - rowHeight, context: context)
        drawText(row.date.formatted(date: .numeric, time: .omitted), in: CGRect(x: 40, y: top - 21, width: 54, height: 15), size: 8, context: context)
        drawText(row.memberName, in: CGRect(x: 98, y: top - 21, width: 92, height: 15), size: 8, bold: true, context: context)
        drawText("\(row.kind.rawValue): \(row.description)", in: CGRect(x: 194, y: top - 21, width: 174, height: 15), size: 7.5, context: context)
        drawText(Money.currency(cents: row.balanceEffectCents), in: CGRect(x: 372, y: top - 21, width: 84, height: 15), size: 8, alignment: .right, context: context)
        drawText(Money.currency(cents: row.runningBalanceCents), in: CGRect(x: 462, y: top - 21, width: 110, height: 15), size: 8, bold: true, alignment: .right, context: context)
    }

    private static func drawUpcomingHeader(top: CGFloat, context: CGContext) {
        drawTableBackground(top: top, context: context)
        drawText("DUE", in: CGRect(x: 40, y: top - 17, width: 64, height: 14), size: 7, bold: true, context: context)
        drawText("MEMBER", in: CGRect(x: 110, y: top - 17, width: 120, height: 14), size: 7, bold: true, context: context)
        drawText("DESCRIPTION", in: CGRect(x: 236, y: top - 17, width: 224, height: 14), size: 7, bold: true, context: context)
        drawText("AMOUNT", in: CGRect(x: 466, y: top - 17, width: 106, height: 14), size: 7, bold: true, alignment: .right, context: context)
    }

    private static func drawUpcomingRow(_ row: FamilyStatementSnapshot.UpcomingRow, top: CGFloat, context: CGContext) {
        drawRule(y: top - rowHeight, context: context)
        drawText(row.date.formatted(date: .numeric, time: .omitted), in: CGRect(x: 40, y: top - 21, width: 64, height: 15), size: 8, context: context)
        drawText(row.memberName, in: CGRect(x: 110, y: top - 21, width: 120, height: 15), size: 8, bold: true, context: context)
        drawText(row.description, in: CGRect(x: 236, y: top - 21, width: 224, height: 15), size: 8, context: context)
        drawText(Money.currency(cents: row.amountCents), in: CGRect(x: 466, y: top - 21, width: 106, height: 15), size: 8, bold: true, alignment: .right, context: context)
    }

    private static func drawTableBackground(top: CGFloat, context: CGContext) {
        context.setFillColor(gray(0.9))
        context.fill(CGRect(x: margin, y: top - 20, width: contentWidth, height: 22))
    }

    private static func drawRule(y: CGFloat, context: CGContext) {
        context.setStrokeColor(gray(0.8))
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: margin, y: y))
        context.addLine(to: CGPoint(x: pageSize.width - margin, y: y))
        context.strokePath()
    }

    private static func drawFooter(_ statement: FamilyStatementSnapshot, page: Int, context: CGContext) {
        let note = statement.currentBalanceCents < 0
            ? "A negative balance is a credit available to this family."
            : "This statement reflects member-ledger entries recorded through the as-of date."
        drawText(note, in: CGRect(x: margin, y: 31, width: 370, height: 13), size: 7, color: gray(0.4), context: context)
        drawText("Generated \(statement.generatedAt.formatted(date: .abbreviated, time: .shortened)) - Page \(page)", in: CGRect(x: 408, y: 31, width: 168, height: 13), size: 7, alignment: .right, color: gray(0.4), context: context)
        drawText("Private family financial information - share securely.", in: CGRect(x: margin, y: 17, width: contentWidth, height: 12), size: 7, bold: true, color: gray(0.35), context: context)
    }

    private enum TextAlignment { case left, right }

    private static func drawText(
        _ text: String,
        in rect: CGRect,
        size: CGFloat,
        bold: Bool = false,
        alignment: TextAlignment = .left,
        color: CGColor = gray(0.08),
        context: CGContext
    ) {
        let printable = text
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "‑", with: "-")
            .replacingOccurrences(of: "•", with: "-")
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: printable, attributes: attributes))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x = alignment == .right ? max(rect.minX, rect.maxX - width) : rect.minX
        context.saveGState()
        context.addPath(CGPath(rect: rect, transform: nil))
        context.clip()
        context.textPosition = CGPoint(x: x, y: rect.minY + max(0, (rect.height - size) / 2))
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func gray(_ value: CGFloat) -> CGColor { CGColor(gray: value, alpha: 1) }
}
