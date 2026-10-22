import Foundation
import CryptoKit

public struct LogicProjectCache: Sendable {
    private let directory: URL

    public static var defaultDirectory: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent("LogicPluginSweeper/LogicProjectCache", isDirectory: true)
    }

    public struct Statistics: Sendable {
        public let fileCount: Int
        public let latestModificationDate: Date?

        public init(fileCount: Int, latestModificationDate: Date?) {
            self.fileCount = fileCount
            self.latestModificationDate = latestModificationDate
        }
    }

    public init(directory: URL) {
        self.directory = directory
    }

    public func statistics() throws -> Statistics {
        let files = try cacheFiles()
        let dates = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        return Statistics(fileCount: files.count, latestModificationDate: dates.max())
    }

    public func clear() throws {
        for file in try cacheFiles() {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func cacheFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "json" }
    }

    public func fingerprint(for project: URL, pluginKeys: [String]) -> String? {
        guard let enumerator = FileManager.default.enumerator(at: project, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        var fileDescriptions: [String] = []
        for case let url as URL in enumerator {
            if Task.isCancelled { return nil }
            if url.lastPathComponent == "Project File Backups" || url.lastPathComponent == "Media" {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]), values.isDirectory != true else { continue }
            let name = url.lastPathComponent.lowercased()
            guard name == "projectdata" || ["plist", "xml", "json", "txt"].contains(url.pathExtension.lowercased()) else { continue }
            fileDescriptions.append("\(url.path)|\(values.fileSize ?? -1)|\(values.contentModificationDate?.timeIntervalSince1970 ?? -1)")
        }
        guard !fileDescriptions.isEmpty else { return nil }
        return digest((["logic-project-cache-v3"] + fileDescriptions.sorted() + pluginKeys.sorted()).joined(separator: "\n"))
    }

    public func load(project: URL, fingerprint: String) -> [CachedUsage]? {
        guard let data = try? Data(contentsOf: entryURL(for: project)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.fingerprint == fingerprint else { return nil }
        return entry.usages
    }

    public func save(project: URL, fingerprint: String, usages: [CachedUsage]) {
        guard let data = try? JSONEncoder().encode(Entry(fingerprint: fingerprint, usages: usages)) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: entryURL(for: project), options: .atomic)
        } catch { }
    }

    public struct CachedUsage: Codable, Sendable {
        public let pluginKey: String
        public let trackName: String?

        public init(pluginKey: String, trackName: String?) {
            self.pluginKey = pluginKey
            self.trackName = trackName
        }
    }

    private struct Entry: Codable {
        let fingerprint: String
        let usages: [CachedUsage]
    }

    private func entryURL(for project: URL) -> URL {
        directory.appendingPathComponent(digest(project.standardizedFileURL.path) + ".json")
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
