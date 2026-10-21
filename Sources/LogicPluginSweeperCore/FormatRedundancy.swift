import Foundation

public struct FormatRedundancyCandidate: Identifiable, Sendable {
    public let id: UUID
    public let audioUnit: PluginRecord
    public let alternative: PluginRecord
    public let confidence: RecommendationConfidence

    public init(audioUnit: PluginRecord, alternative: PluginRecord, confidence: RecommendationConfidence = .medium) {
        id = alternative.id
        self.audioUnit = audioUnit
        self.alternative = alternative
        self.confidence = confidence
    }
}

public struct FormatRedundancyAnalyzer: Sendable {
    public init() {}

    public func candidates(in plugins: [PluginRecord]) -> [FormatRedundancyCandidate] {
        let audioUnits = Dictionary(grouping: plugins.filter { $0.format == .audioUnit }, by: { identityKey(for: $0) })
        return plugins
            .filter { $0.format == .vst || $0.format == .vst3 }
            .compactMap { alternative in
                guard let key = identityKey(for: alternative), let audioUnit = audioUnits[key]?.first else { return nil }
                return FormatRedundancyCandidate(audioUnit: audioUnit, alternative: alternative)
            }
            .sorted { $0.alternative.name.localizedStandardCompare($1.alternative.name) == .orderedAscending }
    }

    private func identityKey(for plugin: PluginRecord) -> String? {
        guard let manufacturer = plugin.manufacturer?.trimmingCharacters(in: .whitespacesAndNewlines), !manufacturer.isEmpty,
              let version = plugin.version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else { return nil }
        return [manufacturer, plugin.name, version]
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
            .joined(separator: "\u{1F}")
    }
}
