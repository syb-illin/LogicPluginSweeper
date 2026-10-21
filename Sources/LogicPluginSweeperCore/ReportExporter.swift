import Foundation

public struct ReportExporter: Sendable {
    public init() {}

    public func json(scan: ScanSummary, usage: LogicProjectUsageSummary? = nil) throws -> Data {
        struct Payload: Codable {
            let generatedAt: Date
            let plugins: [PluginRecord]
            let usage: LogicProjectUsageSummary?
        }
        return try JSONEncoder.prettyPrinted.encode(Payload(generatedAt: .now, plugins: scan.plugins, usage: usage))
    }

    public func csv(scan: ScanSummary) -> Data {
        var lines = ["name,manufacturer,version,format,bytes,health,license,path"]
        lines += scan.plugins.map { plugin in
            [plugin.name, plugin.manufacturer ?? "", plugin.version ?? "", plugin.format.rawValue,
             String(plugin.totalBytes), plugin.health.rawValue, plugin.license.rawValue, plugin.bundleURL?.path ?? ""]
            .map(csvField).joined(separator: ",")
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func csvField(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
