import AppKit

/// Print and PDF output for a document.
///
/// Both go through `NSPrintOperation` rather than a hand-rolled paginator: AppKit
/// already knows how to break a text view across pages, apply the printer's printable
/// area and honour the system's paper size, and reimplementing that is where printing
/// bugs come from. The one thing this has to get right is the measure - a document laid
/// out for the screen is wrapped for the screen, so it has to be re-laid-out at the
/// page's printable width before the operation runs.
@MainActor
enum PrintService {
    /// `NSPrintInfo` for a document: the system's paper, but the original's own margins.
    ///
    /// The scales are set to 1 so the output is the document's real size; letting
    /// AppKit shrink to fit would make a long document illegible rather than paginated.
    /// A copy, not the shared instance: mutating `NSPrintInfo.shared` leaked the
    /// margins into every other print job in the process and accumulated across calls.
    static func printInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.orientation = .portrait
        info.topMargin = 56
        info.bottomMargin = 56
        info.leftMargin = 56
        info.rightMargin = 56
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    /// The width the document should be laid out at for the given paper.
    static func measureWidth(for info: NSPrintInfo) -> CGFloat {
        let paper = info.paperSize
        let margins = info.leftMargin + info.rightMargin
        return max(200, paper.width - margins)
    }

    /// A print operation for a document, with its panel up.
    ///
    /// The caller restores the measure afterwards, because the panel is modal and the
    /// editor must be usable again the moment the user cancels.
    static func operation(for view: NSView, title: String) -> NSPrintOperation {
        let operation = NSPrintOperation(view: view, printInfo: printInfo())
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation
    }

    /// Renders a document straight to a PDF file.
    ///
    /// AppKit has no "export to PDF" call: the way to get a PDF out of a view is to
    /// run a print job whose disposition is `.save` and whose job settings carry the
    /// destination. `NSPrintOperation.run()` is the modern spelling of the synchronous
    /// run - `runOperation()` was renamed, and `NSPrintJob` no longer exists.
    static func writePDF(of view: NSView, title: String, to url: URL) throws {
        let info = printInfo()
        info.jobDisposition = .save
        // `NSPrintJobSavingURL` is the documented key the disposition reads.
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = title
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw CocoaError(.fileWriteUnknown) }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
    }
}
