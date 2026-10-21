import AppKit
import CoreText
import Foundation
import LogicPluginSweeperCore

struct ReportPDFExporter: Sendable {
    func make(scan: ScanSummary, usage: LogicProjectUsageSummary?) -> Data? {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let output = NSMutableData()
        var mediaBox = pageRect
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        let lines = reportLines(scan: scan, usage: usage)
        var lineIndex = 0
        while lineIndex < lines.count {
            context.beginPDFPage(nil)
            var y: CGFloat = pageRect.height - 48
            while lineIndex < lines.count && y > 44 {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: lineIndex == 0 ? NSFont.boldSystemFont(ofSize: 18) : NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.black
                ]
                let attributedLine = NSAttributedString(string: lines[lineIndex], attributes: attributes)
                let line = CTLineCreateWithAttributedString(attributedLine)
                context.textPosition = CGPoint(x: 42, y: y)
                CTLineDraw(line, context)
                y -= lineIndex == 0 ? 30 : 16
                lineIndex += 1
            }
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    private func reportLines(scan: ScanSummary, usage: LogicProjectUsageSummary?) -> [String] {
        var lines = [
            L10n.text("pdf.title"),
            L10n.format("pdf.generated", scan.scannedAt.formatted(date: .abbreviated, time: .shortened)),
            "",
            L10n.format("pdf.plugins", scan.plugins.count),
            L10n.format("pdf.disk", ByteCountFormatter.string(fromByteCount: scan.totalBytes, countStyle: .file)),
            L10n.format("pdf.crashes", scan.crashLogCount),
            ""
        ]
        if let usage {
            lines += [L10n.format("pdf.projects", usage.analyzedProjectCount), L10n.text("pdf.references")]
            lines += usage.pluginUsage.prefix(20).map { "• \($0.pluginName) — \($0.projectCount) projet(s)" }
            lines.append("")
        }
        lines.append(L10n.text("pdf.inventory"))
        lines += scan.plugins.map { plugin in
            let version = plugin.version ?? L10n.text("format.versionUnknown")
            return L10n.format("pdf.pluginLine", plugin.name, plugin.format.rawValue, version, ByteCountFormatter.string(fromByteCount: plugin.totalBytes, countStyle: .file))
        }
        return lines
    }
}
