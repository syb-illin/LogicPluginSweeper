import Foundation

public struct UninstallService: Sendable {
    public struct Inventory: Sendable {
        public let cacheFileCount: Int
        public let cacheBytes: Int64
        public let cacheLastModified: Date?
        public let preservedBytes: Int64
        public let removalCount: Int
        public let hasHistory: Bool
        public let hasExportableData: Bool
    }

    public enum DataChoice: Sendable {
        case keep
        case delete
    }

    public let supportDirectory: URL
    public let preferencesURL: URL
    private let preferencesDomain: String

    public init(supportDirectory: URL? = nil, preferencesURL: URL? = nil, preferencesDomain: String = "com.syb-illin.LogicPluginSweeper") {
        let manager = FileManager.default
        let applicationSupport = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.supportDirectory = supportDirectory ?? applicationSupport.appendingPathComponent("LogicPluginSweeper", isDirectory: true)
        self.preferencesURL = preferencesURL ?? manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.syb-illin.LogicPluginSweeper.plist")
        self.preferencesDomain = preferencesDomain
    }

    public var cacheDirectory: URL { supportDirectory.appendingPathComponent("LogicProjectCache", isDirectory: true) }

    public func inventory() throws -> Inventory {
        let manager = FileManager.default
        let cache = try measure(cacheDirectory)
        let preserved = try measure(supportDirectory)
        let quarantine = supportDirectory.appendingPathComponent("Quarantine", isDirectory: true)
        let removalCount = manager.fileExists(atPath: quarantine.path)
            ? try manager.contentsOfDirectory(atPath: quarantine.path).count : 0
        return Inventory(cacheFileCount: cache.count, cacheBytes: cache.bytes, cacheLastModified: cache.latest,
                         preservedBytes: max(0, preserved.bytes - cache.bytes), removalCount: removalCount,
                         hasHistory: manager.fileExists(atPath: supportDirectory.appendingPathComponent("history.sqlite").path),
                         hasExportableData: manager.fileExists(atPath: supportDirectory.path) || manager.fileExists(atPath: preferencesURL.path))
    }

    public func exportData(to destination: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: supportDirectory.path) || manager.fileExists(atPath: preferencesURL.path) else { throw UninstallError.noDataToExport }
        let source = supportDirectory.resolvingSymlinksInPath().standardizedFileURL
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard target.path != source.path, !target.path.hasPrefix(source.path + "/"),
              !source.path.hasPrefix(target.path + "/") else { throw UninstallError.invalidExportDestination }
        guard !manager.fileExists(atPath: target.path) else { throw UninstallError.exportAlreadyExists }
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        do {
            if manager.fileExists(atPath: source.path) {
                try manager.copyItem(at: source, to: target.appendingPathComponent("LogicPluginSweeper", isDirectory: true))
            }
            if manager.fileExists(atPath: preferencesURL.path) {
                let preferences = target.appendingPathComponent("Preferences", isDirectory: true)
                try manager.createDirectory(at: preferences, withIntermediateDirectories: true)
                try manager.copyItem(at: preferencesURL, to: preferences.appendingPathComponent(preferencesURL.lastPathComponent))
            }
        } catch {
            try? manager.removeItem(at: target)
            throw error
        }
    }

    public func clearCache() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: cacheDirectory.path) { try manager.removeItem(at: cacheDirectory) }
    }

    public func removeData(choice: DataChoice) throws {
        switch choice {
        case .keep:
            try clearCache()
        case .delete:
            let manager = FileManager.default
            if manager.fileExists(atPath: supportDirectory.path) { try manager.removeItem(at: supportDirectory) }
            if manager.fileExists(atPath: preferencesURL.path) { try manager.removeItem(at: preferencesURL) }
            UserDefaults.standard.removePersistentDomain(forName: preferencesDomain)
        }
    }

    public enum UninstallError: LocalizedError {
        case noDataToExport
        case invalidExportDestination
        case exportAlreadyExists

        public var errorDescription: String? {
            switch self {
            case .noDataToExport: "No local data was found to export."
            case .invalidExportDestination: "Choose a destination outside the application data folder."
            case .exportAlreadyExists: "The destination already exists. Choose a new folder name."
            }
        }
    }

    private func measure(_ root: URL) throws -> (count: Int, bytes: Int64, latest: Date?) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return (0, 0, nil) }
        var directories = [root]
        var count = 0
        var bytes: Int64 = 0
        var latest: Date?
        while let directory = directories.popLast() {
            for file in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) {
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true { directories.append(file); continue }
                guard values.isRegularFile == true else { continue }
                count += 1
                let result = bytes.addingReportingOverflow(Int64(values.fileSize ?? 0))
                bytes = result.overflow ? Int64.max : result.partialValue
                if let date = values.contentModificationDate, date > (latest ?? .distantPast) { latest = date }
            }
        }
        return (count, bytes, latest)
    }
}
