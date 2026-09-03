import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
import PDFKit
#endif

@MainActor
enum EventRosterPrinter {
    static func printRoster(_ roster: EventRosterSnapshot) {
        guard let pdf = EventRosterPDFRenderer.render(roster) else { return }

        #if os(iOS)
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = "\(roster.eventName) Roster"
        info.outputType = .general
        controller.printInfo = info
        controller.printingItem = pdf
        controller.present(animated: true)
        #elseif os(macOS)
        guard let document = PDFDocument(data: pdf) else { return }
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.orientation = .portrait
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        guard let operation = document.printOperation(for: printInfo, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
        operation.jobTitle = "\(roster.eventName) Roster"
        operation.run()
        #endif
    }
}
