import CoreGraphics
import CoreText
import Foundation

struct EventRosterSnapshot {
    struct Row: Identifiable {
        let id: UUID
        let name: String
        let group: String
        let status: String
        let transportation: String
        let notes: String
    }

    let eventName: String
    let troop: TroopReportIdentity
    let classification: String
    let dateRange: String
    let location: String
    let coordinator: String
    let rows: [Row]

    var scoutCount: Int { rows.count { $0.group.hasPrefix("Scout") } }
    var adultCount: Int { rows.count { $0.group.hasPrefix("Adult") } }

    init(event: EventRecord, participants: [EventParticipant], people: [PersonRecord], troopProfile: TroopProfileRecord? = nil) {
        let peopleByID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        troop = TroopReportIdentity(profile: troopProfile)
        eventName = event.name
        classification = event.classification.rawValue
        dateRange = Self.formattedDateRange(for: event)
        location = [event.location, event.address]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        coordinator = event.coordinator
        rows = participants.map { participant in
            let person = participant.personID.flatMap { peopleByID[$0] }
            return Row(
                id: participant.id,
                name: person?.displayName.nonempty ?? participant.guestName.nonempty ?? "Unnamed guest",
                group: Self.groupDescription(for: person),
                status: participant.status.rawValue,
                transportation: participant.transportation,
                notes: participant.notes
            )
        }
        .sorted { lhs, rhs in
            let leftGroup = Self.groupOrder(lhs.group)
            let rightGroup = Self.groupOrder(rhs.group)
            if leftGroup != rightGroup { return leftGroup < rightGroup }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func groupDescription(for person: PersonRecord?) -> String {
        guard let person else { return "Guest" }
        switch person.role {
        case .scout:
            return person.patrol.nonempty.map { "Scout • \($0)" } ?? "Scout"
        case .leader:
            return person.positionSummary.nonempty.map { "Adult • \($0)" } ?? "Adult leader"
        case .parent:
            return "Adult • Parent/Guardian"
        case .other:
            return "Other"
        }
    }

    private static func groupOrder(_ group: String) -> Int {
        if group.hasPrefix("Scout") { return 0 }
        if group.hasPrefix("Adult") { return 1 }
        return 2
    }

    private static func formattedDateRange(for event: EventRecord) -> String {
        if event.isAllDay {
            if Calendar.current.isDate(event.startDate, inSameDayAs: event.endDate) {
                return event.startDate.formatted(date: .long, time: .omitted)
            }
            return "\(event.startDate.formatted(date: .abbreviated, time: .omitted)) – \(event.endDate.formatted(date: .abbreviated, time: .omitted))"
        }
        if Calendar.current.isDate(event.startDate, inSameDayAs: event.endDate) {
            return "\(event.startDate.formatted(date: .long, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))"
        }
        return "\(event.startDate.formatted(date: .abbreviated, time: .shortened)) – \(event.endDate.formatted(date: .abbreviated, time: .shortened))"
    }
}

enum EventRosterPDFRenderer {
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 36
    private static let rowHeight: CGFloat = 30

    static func render(_ roster: EventRosterSnapshot) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        var rowIndex = 0
        var pageNumber = 1
        repeat {
            context.beginPDFPage(nil)
            drawPageHeader(roster, pageNumber: pageNumber, context: context)
            var top = pageSize.height - 154
            drawTableHeader(at: top, context: context)
            top -= 24

            while rowIndex < roster.rows.count, top - rowHeight >= margin + 20 {
                drawRow(roster.rows[rowIndex], index: rowIndex + 1, top: top, context: context)
                top -= rowHeight
                rowIndex += 1
            }

            drawText(
                "Printed \(Date().formatted(date: .abbreviated, time: .shortened)) • Page \(pageNumber)",
                in: CGRect(x: margin, y: 16, width: pageSize.width - margin * 2, height: 14),
                size: 8,
                color: CGColor(gray: 0.4, alpha: 1),
                context: context
            )
            context.endPDFPage()
            pageNumber += 1
        } while rowIndex < roster.rows.count

        context.closePDF()
        return data as Data
    }

    private static func drawPageHeader(_ roster: EventRosterSnapshot, pageNumber: Int, context: CGContext) {
        let unitLine = [roster.troop.formalName, roster.troop.organizationLine.nonempty]
            .compactMap { $0 }
            .joined(separator: "  •  ")
        drawText(unitLine, in: CGRect(x: margin, y: 774, width: 540, height: 12), size: 8, bold: true, color: CGColor(gray: 0.3, alpha: 1), context: context)
        drawText(roster.eventName, in: CGRect(x: margin, y: 738, width: 540, height: 30), size: 20, bold: true, context: context)
        drawText("Event roster", in: CGRect(x: margin, y: 716, width: 540, height: 20), size: 12, color: CGColor(gray: 0.35, alpha: 1), context: context)

        var details = "\(roster.classification)  •  \(roster.dateRange)"
        if !roster.location.isEmpty { details += "  •  \(roster.location)" }
        drawText(details, in: CGRect(x: margin, y: 690, width: 540, height: 18), size: 10, context: context)

        let counts = "\(roster.rows.count) people  •  \(roster.scoutCount) Scouts  •  \(roster.adultCount) adults"
        drawText(counts, in: CGRect(x: margin, y: 670, width: 300, height: 16), size: 9, context: context)
        if !roster.coordinator.isEmpty {
            drawText("Coordinator: \(roster.coordinator)", in: CGRect(x: 336, y: 670, width: 240, height: 16), size: 9, context: context)
        }
    }

    private static func drawTableHeader(at top: CGFloat, context: CGContext) {
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: margin, y: top - 20, width: pageSize.width - margin * 2, height: 22))
        drawText("#", in: CGRect(x: 40, y: top - 17, width: 18, height: 14), size: 8, bold: true, context: context)
        drawText("IN", in: CGRect(x: 60, y: top - 17, width: 20, height: 14), size: 8, bold: true, context: context)
        drawText("OUT", in: CGRect(x: 84, y: top - 17, width: 28, height: 14), size: 8, bold: true, context: context)
        drawText("NAME", in: CGRect(x: 116, y: top - 17, width: 146, height: 14), size: 8, bold: true, context: context)
        drawText("PATROL / ROLE", in: CGRect(x: 266, y: top - 17, width: 108, height: 14), size: 8, bold: true, context: context)
        drawText("STATUS", in: CGRect(x: 378, y: top - 17, width: 78, height: 14), size: 8, bold: true, context: context)
        drawText("TRANSPORTATION / NOTES", in: CGRect(x: 460, y: top - 17, width: 116, height: 14), size: 7, bold: true, context: context)
    }

    private static func drawRow(_ row: EventRosterSnapshot.Row, index: Int, top: CGFloat, context: CGContext) {
        context.setStrokeColor(CGColor(gray: 0.78, alpha: 1))
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: margin, y: top - rowHeight))
        context.addLine(to: CGPoint(x: pageSize.width - margin, y: top - rowHeight))
        context.strokePath()

        drawText("\(index)", in: CGRect(x: 40, y: top - 23, width: 18, height: 16), size: 8, context: context)
        drawCheckbox(at: CGPoint(x: 66, y: top - 18), context: context)
        drawCheckbox(at: CGPoint(x: 91, y: top - 18), context: context)
        drawText(row.name, in: CGRect(x: 116, y: top - 23, width: 146, height: 16), size: 9, bold: true, context: context)
        drawText(row.group, in: CGRect(x: 266, y: top - 23, width: 108, height: 16), size: 8, context: context)
        drawText(row.status, in: CGRect(x: 378, y: top - 23, width: 78, height: 16), size: 8, context: context)
        let detail = [row.transportation, row.notes].filter { !$0.isEmpty }.joined(separator: " • ")
        drawText(detail, in: CGRect(x: 460, y: top - 23, width: 116, height: 16), size: 7, context: context)
    }

    private static func drawCheckbox(at point: CGPoint, context: CGContext) {
        context.setStrokeColor(CGColor(gray: 0.25, alpha: 1))
        context.setLineWidth(0.7)
        context.stroke(CGRect(x: point.x, y: point.y, width: 9, height: 9))
    }

    private static func drawText(
        _ text: String,
        in rect: CGRect,
        size: CGFloat,
        bold: Bool = false,
        color: CGColor = CGColor(gray: 0.08, alpha: 1),
        context: CGContext
    ) {
        let printableText = text
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "‑", with: "-")
            .replacingOccurrences(of: "•", with: "-")
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: printableText, attributes: attributes))
        context.saveGState()
        context.textPosition = CGPoint(x: rect.minX, y: rect.minY + max(0, (rect.height - size) / 2))
        let clip = CGPath(rect: rect, transform: nil)
        context.addPath(clip)
        context.clip()
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

private extension String {
    var nonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
