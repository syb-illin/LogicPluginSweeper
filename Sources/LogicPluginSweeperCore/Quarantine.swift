import Foundation
import CryptoKit

public struct QuarantineService: Sendable {
    private let root: URL
    private let privilegedMover = PrivilegedFileMover()

    public init(root: URL? = nil) {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.root = root ?? applicationSupport.appendingPathComponent("LogicPluginSweeper/Quarantine", isDirectory: true)
    }

    public func quarantine(_ plugin: PluginRecord) throws -> RemovalRecord {
        guard let bundleURL = plugin.bundleURL else { throw QuarantineError.bundleUnavailable }
        let location = PluginLocation(path: bundleURL, kind: .pluginBundle, byteCount: plugin.totalBytes, fileCount: plugin.fileCount)
        return try quarantine(plugin, locations: [location])
    }

    public func quarantine(_ plugin: PluginRecord, locations: [PluginLocation]) throws -> RemovalRecord {
        let fm = FileManager.default
        let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let availableLocations = locations.filter { fm.fileExists(atPath: $0.path.path) }
        guard !availableLocations.isEmpty else {
            try? fm.removeItem(at: destination)
            throw QuarantineError.bundleUnavailable
        }
        var moved: [(URL, URL)] = []
        do {
            for (index, location) in availableLocations.enumerated() {
                let relativePath = availableLocations.count == 1 ? location.path.lastPathComponent : "items/\(String(format: "%02d-%@", index, location.path.lastPathComponent))"
                let target = destination.appendingPathComponent(relativePath, isDirectory: location.path.hasDirectoryPath)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try moveItem(from: location.path, to: target)
                moved.append((location.path, target))
            }
        } catch {
            for (original, target) in moved.reversed() where !fm.fileExists(atPath: original.path) {
                try? fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? moveItem(from: target, to: original)
            }
            try? fm.removeItem(at: destination)
            throw error
        }
        var hashes: [String: String] = [:]
        for (original, target) in moved {
            if let hash = bundleHash(at: target) { hashes[original.path] = hash }
        }
        let byteCount = availableLocations.reduce(Int64(0)) { total, location in
            let result = total.addingReportingOverflow(location.byteCount)
            return result.overflow ? Int64.max : result.partialValue
        }
        let record = RemovalRecord(pluginName: plugin.name, originalPaths: availableLocations.map(\.path), quarantineURL: destination, byteCount: byteCount, contentHash: nil, contentHashes: hashes.isEmpty ? nil : hashes)
        LogicPluginSweeperLog.quarantine.info("Quarantined \(plugin.name, privacy: .public) and preserved restore metadata")
        return record
    }

    public func restore(_ record: RemovalRecord) throws {
        let fm = FileManager.default
        var moves: [(original: URL, candidate: URL)] = []
        for (index, original) in record.originalPaths.enumerated() {
            let indexedName = String(format: "%02d-%@", index, original.lastPathComponent)
            let legacyIndexedName = String(format: "%02d-%@", index, safeName(original.lastPathComponent))
            let indexedCandidate = record.quarantineURL.appendingPathComponent("items/\(indexedName)", isDirectory: original.hasDirectoryPath)
            let legacyIndexedCandidate = record.quarantineURL.appendingPathComponent("items/\(legacyIndexedName)", isDirectory: original.hasDirectoryPath)
            let legacyCandidate = record.quarantineURL.appendingPathComponent(original.lastPathComponent, isDirectory: true)
            let candidate: URL
            if fm.fileExists(atPath: indexedCandidate.path) {
                candidate = indexedCandidate
            } else if fm.fileExists(atPath: legacyIndexedCandidate.path) {
                candidate = legacyIndexedCandidate
            } else {
                candidate = legacyCandidate
            }
            guard fm.fileExists(atPath: candidate.path) else { throw QuarantineError.quarantinedItemMissing }
            if let expectedHashes = record.contentHashes, let expectedHash = expectedHashes[original.path], bundleHash(at: candidate) != expectedHash { throw QuarantineError.integrityCheckFailed }
            if record.contentHashes == nil, let expectedHash = record.contentHash, bundleHash(at: candidate) != expectedHash { throw QuarantineError.integrityCheckFailed }
            guard !fm.fileExists(atPath: original.path) else { throw QuarantineError.originalPathOccupied }
            moves.append((original, candidate))
        }
        var restored: [(original: URL, candidate: URL)] = []
        do {
            for move in moves {
                try fm.createDirectory(at: move.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try moveItem(from: move.candidate, to: move.original)
                restored.append(move)
            }
        } catch {
            for move in restored.reversed() where !fm.fileExists(atPath: move.candidate.path) {
                try? moveItem(from: move.original, to: move.candidate)
            }
            throw error
        }
        try? fm.removeItem(at: record.quarantineURL)
    }

    public enum QuarantineError: Error {
        case bundleUnavailable
        case quarantinedItemMissing
        case originalPathOccupied
        case integrityCheckFailed
    }

    private func bundleHash(at url: URL) -> String? {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory != true,
           let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
            var digest = SHA256()
            digest.update(data: Data(url.path.utf8))
            digest.update(data: data)
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return nil }
        var digest = SHA256()
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]), values.isDirectory != true,
                  let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else { continue }
            digest.update(data: Data(fileURL.path.utf8)); digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func safeName(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
    }

    private func moveItem(from source: URL, to destination: URL) throws {
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            guard Self.isPermissionError(error) else { throw error }
            try privilegedMover.moveItem(from: source, to: destination)
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let code = (error as NSError).code
        return code == 513 || code == 257
    }
}
