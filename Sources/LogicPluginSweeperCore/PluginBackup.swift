import Foundation

public struct PluginBackupService: Sendable {
    public init() {}

    public func createArchive(for plugin: PluginRecord, footprint: PluginFootprint? = nil, in destinationFolder: URL) throws -> URL {
        let fileManager = FileManager.default
        guard let bundleURL = plugin.bundleURL, fileManager.fileExists(atPath: bundleURL.path) else {
            throw BackupError.bundleUnavailable
        }
        try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent("LogicPluginSweeper-Backup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let discoveredLocations = footprint?.locations.filter { fileManager.fileExists(atPath: $0.path.path) } ?? PluginFootprintScanner().scan(plugin: plugin).locations
        let locations = discoveredLocations.isEmpty ? [PluginLocation(path: bundleURL, kind: .pluginBundle, byteCount: plugin.totalBytes, fileCount: plugin.fileCount)] : discoveredLocations
        var archiveEntries: [(location: PluginLocation, archivePath: String)] = []
        for (index, location) in locations.enumerated() {
            let archivePath = "Files/\(String(format: "%02d", index))/\(location.path.lastPathComponent)"
            let destination = temporaryRoot.appendingPathComponent(archivePath, isDirectory: location.path.hasDirectoryPath)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: location.path, to: destination)
            archiveEntries.append((location, archivePath))
        }
        let manifestURL = temporaryRoot.appendingPathComponent("LogicPluginSweeper-Backup.txt")
        try manifest(for: plugin, entries: archiveEntries).write(to: manifestURL, atomically: true, encoding: .utf8)

        let baseName = sanitized(plugin.name.isEmpty ? bundleURL.deletingPathExtension().lastPathComponent : plugin.name)
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let archiveURL = destinationFolder.appendingPathComponent("\(baseName)-\(stamp).zip")
        try archive(source: temporaryRoot, destination: archiveURL)
        return archiveURL
    }

    private func archive(source: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BackupError.archiveFailed(details)
        }
    }

    private func manifest(for plugin: PluginRecord, entries: [(location: PluginLocation, archivePath: String)]) -> String {
        var lines = [
            "LogicPluginSweeper backup",
            "Plugin: \(plugin.name)",
            "Format: \(plugin.format.rawValue)",
            "Created: \(ISO8601DateFormatter().string(from: .now))",
            "",
            "Restore instructions",
            "1. Close Logic Pro and compatible audio applications.",
            "2. Extract this ZIP archive.",
            "3. Copy the complete plugin bundle back to its original location below.",
            "4. Restart Logic Pro and rescan plugins if required.",
            "",
            "Original locations:",
            "",
            "Every item below is included under its archive path:"
        ]
        for entry in entries {
            lines.append("\(entry.archivePath) -> \(entry.location.path.path) (\(entry.location.byteCount) bytes, \(entry.location.fileCount) file(s))")
            if entry.location.fileCount > 0, let enumerator = FileManager.default.enumerator(at: entry.location.path, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
                for case let fileURL as URL in enumerator {
                    guard let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]), values.isDirectory != true else { continue }
                    let relativePath = fileURL.path.replacingOccurrences(of: entry.location.path.path + "/", with: "")
                    lines.append("  \(entry.archivePath)/\(relativePath) -> \(fileURL.path) (\(values.fileSize ?? 0) bytes)")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func sanitized(_ value: String) -> String {
        let allowed = value.unicodeScalars.map { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == " ") ? String(scalar) : "-"
        }.joined()
        return allowed.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "--", with: "-")
    }

    public enum BackupError: Error, LocalizedError, Sendable {
        case bundleUnavailable
        case archiveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .bundleUnavailable: "The plugin bundle is no longer available."
            case .archiveFailed(let details): details.isEmpty ? "The backup archive could not be created." : details
            }
        }
    }
}
