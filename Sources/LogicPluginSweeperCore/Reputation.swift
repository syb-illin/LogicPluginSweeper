import Foundation

public struct PluginReputation: Codable, Sendable, Equatable {
    public let score: Double
    public let maximumScore: Double
    public let reviewCount: Int
    public let sourceName: String
    public let sourceURL: URL
    public let capturedAt: Date
    public let confidence: RecommendationConfidence

    public init(score: Double, maximumScore: Double = 5, reviewCount: Int, sourceName: String, sourceURL: URL, capturedAt: Date = .now, confidence: RecommendationConfidence) {
        self.score = min(max(score, 0), maximumScore)
        self.maximumScore = maximumScore
        self.reviewCount = max(reviewCount, 0)
        self.sourceName = sourceName
        self.sourceURL = sourceURL
        self.capturedAt = capturedAt
        self.confidence = confidence
    }
}

public enum PluginReputationSearch {
    public static func url(for plugin: PluginRecord) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        let identity = [plugin.manufacturer, plugin.name, plugin.version]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
        components?.queryItems = [URLQueryItem(name: "q", value: "\"\(identity)\" plugin reviews")]
        return components?.url
    }
}
