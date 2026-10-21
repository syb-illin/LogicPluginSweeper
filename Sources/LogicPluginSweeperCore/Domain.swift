import Foundation

public enum PluginFormat: String, Codable, CaseIterable, Sendable {
    case audioUnit = "AU"
    case vst = "VST"
    case vst3 = "VST3"
    case aax = "AAX"
    case clap = "CLAP"
    case unknown = "Unknown"
}

public enum PluginHealth: String, Codable, CaseIterable, Sendable {
    case healthy
    case warning
    case failed
    case notChecked
}

public enum LicenseStatus: String, Codable, Sendable {
    case active
    case expired
    case unknown
}

public enum RecommendationConfidence: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low

    public var label: String {
        switch self { case .high: "Élevée"; case .medium: "Moyenne"; case .low: "Faible" }
    }
}

public struct PluginRecommendation: Identifiable, Codable, Sendable {
    public let id: UUID
    public let pluginID: UUID
    public let title: String
    public let reason: String
    public let confidence: RecommendationConfidence
    public let recoverableBytes: Int64

    public init(plugin: PluginRecord, title: String, reason: String, confidence: RecommendationConfidence) {
        id = UUID()
        pluginID = plugin.id
        self.title = title
        self.reason = reason
        self.confidence = confidence
        recoverableBytes = plugin.totalBytes
    }
}

public struct PluginFile: Codable, Hashable, Sendable {
    public let path: URL
    public let byteCount: Int64
    public let modifiedAt: Date

    public init(path: URL, byteCount: Int64, modifiedAt: Date) {
        self.path = path
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public struct PluginRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let manufacturer: String?
    public let version: String?
    public let format: PluginFormat
    public let files: [PluginFile]
    public let health: PluginHealth
    public let license: LicenseStatus
    public let officialURL: URL?
    public let scannedAt: Date
    public let healthMessage: String?
    public let bundleURL: URL?
    public let fileCount: Int
    private let measuredBytes: Int64?

    public var totalBytes: Int64 {
        if let measuredBytes { return measuredBytes }
        return files.reduce(Int64(0)) { total, file in
            let result = total.addingReportingOverflow(file.byteCount)
            return result.overflow ? Int64.max : result.partialValue
        }
    }

    public init(id: UUID = UUID(), name: String, manufacturer: String? = nil, version: String? = nil,
                format: PluginFormat, files: [PluginFile], health: PluginHealth = .notChecked,
                license: LicenseStatus = .unknown, officialURL: URL? = nil,
                scannedAt: Date = .now, healthMessage: String? = nil, bundleURL: URL? = nil,
                measuredBytes: Int64? = nil, fileCount: Int? = nil) {
        self.id = id; self.name = name; self.manufacturer = manufacturer; self.version = version
        self.format = format; self.files = files; self.health = health; self.license = license
        self.officialURL = officialURL; self.scannedAt = scannedAt; self.healthMessage = healthMessage
        self.bundleURL = bundleURL
        self.fileCount = fileCount ?? files.count
        self.measuredBytes = measuredBytes
    }

    public func withHealth(_ health: PluginHealth, message: String?) -> PluginRecord {
        PluginRecord(id: id, name: name, manufacturer: manufacturer, version: version, format: format,
                     files: files, health: health, license: license, officialURL: officialURL,
                     scannedAt: scannedAt, healthMessage: message, bundleURL: bundleURL,
                     measuredBytes: measuredBytes, fileCount: fileCount)
    }
}

public struct RemovalRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let pluginName: String
    public let originalPaths: [URL]
    public let quarantineURL: URL
    public let byteCount: Int64
    public let removedAt: Date
    public var restoredAt: Date?
    public let contentHash: String?
    public let contentHashes: [String: String]?

    public init(id: UUID = UUID(), pluginName: String, originalPaths: [URL], quarantineURL: URL,
                byteCount: Int64, removedAt: Date = .now, restoredAt: Date? = nil) {
        self.id = id; self.pluginName = pluginName; self.originalPaths = originalPaths
        self.quarantineURL = quarantineURL; self.byteCount = byteCount; self.removedAt = removedAt
        self.restoredAt = restoredAt; self.contentHash = nil; self.contentHashes = nil
    }

    public init(id: UUID = UUID(), pluginName: String, originalPaths: [URL], quarantineURL: URL,
                byteCount: Int64, removedAt: Date = .now, restoredAt: Date? = nil, contentHash: String?, contentHashes: [String: String]? = nil) {
        self.id = id; self.pluginName = pluginName; self.originalPaths = originalPaths
        self.quarantineURL = quarantineURL; self.byteCount = byteCount; self.removedAt = removedAt
        self.restoredAt = restoredAt; self.contentHash = contentHash; self.contentHashes = contentHashes
    }
}

public struct ProjectDependencyReport: Sendable {
    public let projectURL: URL
    public let status: Status
    public let details: String

    public enum Status: String, Sendable { case referenced, noEvidence, unreadable, notImplemented }
}

public struct PluginUsageStats: Identifiable, Codable, Sendable {
    public let id: UUID
    public let pluginName: String
    public let format: PluginFormat
    public let projectCount: Int
    public let projectURLs: [URL]

    public init(plugin: PluginRecord, projectURLs: [URL]) {
        id = plugin.id
        pluginName = plugin.name
        format = plugin.format
        projectCount = projectURLs.count
        self.projectURLs = projectURLs
    }
}

public struct LogicProjectPluginUsage: Identifiable, Codable, Sendable {
    public let id: UUID
    public let pluginID: UUID
    public let pluginName: String
    public let manufacturer: String?
    public let format: PluginFormat
    public let trackName: String?
    public let confidence: RecommendationConfidence

    public init(plugin: PluginRecord, trackName: String? = nil, confidence: RecommendationConfidence = .medium) {
        id = UUID()
        pluginID = plugin.id
        pluginName = plugin.name
        manufacturer = plugin.manufacturer
        format = plugin.format
        self.trackName = trackName
        self.confidence = confidence
    }

    public var scopeLabel: String {
        trackName ?? "project"
    }
}

public struct LogicProjectAnalysis: Identifiable, Codable, Sendable {
    public let id: UUID
    public let projectURL: URL
    public let pluginUsages: [LogicProjectPluginUsage]
    public let isReadable: Bool

    public init(projectURL: URL, pluginUsages: [LogicProjectPluginUsage], isReadable: Bool = true) {
        id = UUID()
        self.projectURL = projectURL
        self.pluginUsages = pluginUsages
        self.isReadable = isReadable
    }
}

public struct LogicProjectUsageSummary: Codable, Sendable {
    public let analyzedProjectCount: Int
    public let unreadableProjectCount: Int
    public let pluginUsage: [PluginUsageStats]
    public let projectAnalyses: [LogicProjectAnalysis]

    public init(analyzedProjectCount: Int, unreadableProjectCount: Int, pluginUsage: [PluginUsageStats], projectAnalyses: [LogicProjectAnalysis] = []) {
        self.analyzedProjectCount = analyzedProjectCount
        self.unreadableProjectCount = unreadableProjectCount
        self.pluginUsage = pluginUsage
        self.projectAnalyses = projectAnalyses
    }
}

public struct ScanSummary: Sendable {
    public let plugins: [PluginRecord]
    public let crashLogCount: Int
    public let scannedAt: Date
    public init(plugins: [PluginRecord], crashLogCount: Int, scannedAt: Date) {
        self.plugins = plugins; self.crashLogCount = crashLogCount; self.scannedAt = scannedAt
    }
    public var totalBytes: Int64 {
        plugins.reduce(Int64(0)) { total, plugin in
            let result = total.addingReportingOverflow(plugin.totalBytes)
            return result.overflow ? Int64.max : result.partialValue
        }
    }
}
