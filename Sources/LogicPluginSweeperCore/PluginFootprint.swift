import Foundation

public struct PluginLocation: Codable, Hashable, Identifiable, Sendable {
    public let id: URL
    public let path: URL
    public let kind: Kind
    public let byteCount: Int64
    public let fileCount: Int

    public enum Kind: String, Codable, Sendable {
        case pluginBundle
        case presets
        case applicationSupport
        case preferences
        case cache
        case other
    }

    public init(path: URL, kind: Kind, byteCount: Int64, fileCount: Int) {
        id = path.standardizedFileURL
        self.path = path
        self.kind = kind
        self.byteCount = byteCount
        self.fileCount = fileCount
    }
}

public struct PluginFootprint: Codable, Sendable {
    public let locations: [PluginLocation]
    public let evidence: [PluginDependencyEvidence]
    public let isComplete: Bool

    public init(locations: [PluginLocation], evidence: [PluginDependencyEvidence] = [], isComplete: Bool) {
        self.locations = locations
        self.evidence = evidence
        self.isComplete = isComplete
    }

    public var totalBytes: Int64 {
        locations.reduce(Int64(0)) { total, location in
            let result = total.addingReportingOverflow(location.byteCount)
            return result.overflow ? Int64.max : result.partialValue
        }
    }
}

public struct PluginDependencyEvidence: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let value: String
    public let source: Source

    public enum Source: String, Codable, Sendable {
        case bundleIdentifier
        case infoPlist
        case embeddedPath
    }

    public init(value: String, source: Source) {
        id = UUID()
        self.value = value
        self.source = source
    }
}

public struct PluginFootprintScanner: Sendable {
    public init() {}

    public func scan(plugin: PluginRecord) -> PluginFootprint {
        scan(plugin: plugin, isCancelled: { false })
    }

    public func scan(plugin: PluginRecord, isCancelled: @Sendable () -> Bool) -> PluginFootprint {
        guard let bundleURL = plugin.bundleURL else { return PluginFootprint(locations: [], isComplete: false) }
        let fileManager = FileManager.default
        let inspection = PluginBundleInspector().inspect(bundleURL: bundleURL)
        var locations: [PluginLocation] = []
        var seen = Set<URL>()
        var isComplete = appendLocation(bundleURL, kind: .pluginBundle, to: &locations, seen: &seen)

        let identity = [plugin.name, inspection.bundleIdentifier]
            .compactMap { $0 }
            .map(normalizedToken)
            .filter { $0.count >= 3 }
        let homeLibrary = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        let roots: [(URL, PluginLocation.Kind)] = [
            (homeLibrary.appendingPathComponent("Audio/Presets", isDirectory: true), .presets),
            (homeLibrary.appendingPathComponent("Application Support", isDirectory: true), .applicationSupport),
            (homeLibrary.appendingPathComponent("Preferences", isDirectory: true), .preferences),
            (homeLibrary.appendingPathComponent("Caches", isDirectory: true), .cache),
            (URL(fileURLWithPath: "/Library/Audio/Presets", isDirectory: true), .presets),
            (URL(fileURLWithPath: "/Library/Application Support", isDirectory: true), .applicationSupport)
        ]
        for (root, kind) in roots where fileManager.fileExists(atPath: root.path) {
            if isCancelled() { return PluginFootprint(locations: locations, evidence: inspection.evidence, isComplete: false) }
            var locationsWereComplete = true
            let rootWasComplete = findMatches(in: root, identity: identity, fileManager: fileManager, isCancelled: isCancelled) { url in
                locationsWereComplete = appendLocation(url, kind: kind, to: &locations, seen: &seen) && locationsWereComplete
            }
            isComplete = isComplete && rootWasComplete && locationsWereComplete
        }
        return PluginFootprint(locations: locations.sorted {
            if $0.kind == .pluginBundle { return $1.kind != .pluginBundle }
            if $1.kind == .pluginBundle { return false }
            return $0.path.path.localizedStandardCompare($1.path.path) == .orderedAscending
        }, evidence: inspection.evidence, isComplete: isComplete)
    }

    private func findMatches(in root: URL, identity: [String], fileManager: FileManager, isCancelled: @Sendable () -> Bool, match: (URL) -> Void) -> Bool {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return false }
        var inspected = 0
        for case let url as URL in enumerator {
            if isCancelled() { return false }
            inspected += 1
            if inspected > 5_000 { return false }
            let pathComponents = url.path.split(separator: "/").map { normalizedToken(String($0)) }
            let identityMatch = identity.contains { token in pathComponents.contains(token) }
            guard identityMatch else { continue }
            match(url)
            if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true {
                enumerator.skipDescendants()
            }
        }
        return true
    }

    @discardableResult
    private func appendLocation(_ url: URL, kind: PluginLocation.Kind, to locations: inout [PluginLocation], seen: inout Set<URL>) -> Bool {
        let normalized = url.standardizedFileURL
        guard seen.insert(normalized).inserted else { return true }
        guard let inventory = inventory(at: normalized) else { return false }
        locations.append(PluginLocation(path: normalized, kind: kind, byteCount: inventory.bytes, fileCount: inventory.files))
        return true
    }

    private func normalizedToken(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func inventory(at url: URL) -> (bytes: Int64, files: Int)? {
        let fileManager = FileManager.default
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]), fileManager.fileExists(atPath: url.path) else { return nil }
        if values.isDirectory != true { return (Int64(max(values.fileSize ?? 0, 0)), 1) }
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return nil }
        var bytes: Int64 = 0
        var files = 0
        for case let fileURL as URL in enumerator {
            guard let fileValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]), fileValues.isDirectory != true else { continue }
            let result = bytes.addingReportingOverflow(Int64(max(fileValues.fileSize ?? 0, 0)))
            bytes = result.overflow ? Int64.max : result.partialValue
            files += 1
        }
        return (bytes, files)
    }
}

public struct PluginBundleContents: Sendable {
    public let files: [PluginFile]
    public let isComplete: Bool

    public init(files: [PluginFile], isComplete: Bool) {
        self.files = files
        self.isComplete = isComplete
    }
}

public struct PluginBundleContentScanner: Sendable {
    public init() {}

    public func scan(bundleURL: URL, isCancelled: @Sendable () -> Bool = { false }) -> PluginBundleContents {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: Array(keys)) else {
            return PluginBundleContents(files: [], isComplete: false)
        }
        var files: [PluginFile] = []
        let limit = 10_000
        for case let url as URL in enumerator {
            if isCancelled() { return PluginBundleContents(files: files, isComplete: false) }
            guard let values = try? url.resourceValues(forKeys: keys), values.isDirectory != true else { continue }
            guard let fileSize = values.fileSize, let modifiedAt = values.contentModificationDate else { continue }
            files.append(PluginFile(path: url, byteCount: Int64(max(fileSize, 0)), modifiedAt: modifiedAt))
            if files.count >= limit { return PluginBundleContents(files: files, isComplete: false) }
        }
        return PluginBundleContents(files: files.sorted { $0.path.path.localizedStandardCompare($1.path.path) == .orderedAscending }, isComplete: true)
    }
}

public struct PluginBundleInspector: Sendable {
    public init() {}

    public func inspect(bundleURL: URL) -> Inspection {
        let bundle = Bundle(url: bundleURL)
        let info = bundle?.infoDictionary ?? [:]
        let bundleIdentifier = (info["CFBundleIdentifier"] as? String)?.lowercased()
        var evidence: [PluginDependencyEvidence] = []
        var searchTokens: [String] = []
        if let bundleIdentifier {
            evidence.append(PluginDependencyEvidence(value: bundleIdentifier, source: .bundleIdentifier))
            searchTokens.append(bundleIdentifier)
        }
        let infoValues = propertyListStrings(from: info)
        for value in infoValues where value.count >= 3 {
            if value.contains("/") || value.contains(".") {
                evidence.append(PluginDependencyEvidence(value: value, source: .infoPlist))
                searchTokens.append(contentsOf: searchableTokens(from: value))
            }
        }
        for value in embeddedPathStrings(in: bundleURL) {
            evidence.append(PluginDependencyEvidence(value: value, source: .embeddedPath))
            searchTokens.append(contentsOf: searchableTokens(from: value))
        }
        return Inspection(bundleIdentifier: bundleIdentifier, evidence: Array(Set(evidence)).prefix(40).map { $0 }, searchTokens: Array(Set(searchTokens)))
    }

    public struct Inspection: Sendable {
        public let bundleIdentifier: String?
        public let evidence: [PluginDependencyEvidence]
        public let searchTokens: [String]
    }

    private func embeddedPathStrings(in bundleURL: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        var values: [String] = []
        var inspected = 0
        for case let url as URL in enumerator {
            inspected += 1
            if inspected > 64 { break }
            guard let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]), resourceValues.isDirectory != true,
                  (resourceValues.fileSize ?? 0) <= 8 * 1024 * 1024,
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
            for run in printableRuns(in: data) where isDependencyHint(run) {
                values.append(String(run.prefix(180)))
                if values.count == 80 { return values }
            }
        }
        return values
    }

    private func isDependencyHint(_ value: String) -> Bool {
        let lower = value.lowercased()
        let pathMarkers = ["/library/", "~/library/", ".plist", ".preset", ".db", ".json", ".xml", ".dat", ".cache", ".settings"]
        return pathMarkers.contains { lower.contains($0) }
    }

    private func searchableTokens(from value: String) -> [String] {
        let ignored: Set<String> = ["com", "org", "net", "library", "audio", "plug", "plugin", "ins", "support", "application", "presets", "cache", "caches", "preferences"]
        return value.split { character in
            character == "/" || character == "\\" || character == ":" || character == " " || character == "_" || character == "-"
        }.map(String.init).filter { $0.count >= 4 && !ignored.contains($0.lowercased()) }
    }

    private func propertyListStrings(from value: Any) -> [String] {
        switch value {
        case let string as String: return [string]
        case let values as [Any]: return values.flatMap { propertyListStrings(from: $0) }
        case let values as [String: Any]: return values.values.flatMap { propertyListStrings(from: $0) }
        default: return []
        }
    }

    private func printableRuns(in data: Data) -> [String] {
        var result: [String] = []
        var current: [UInt8] = []
        for byte in data {
            if byte >= 0x20 && byte <= 0x7E { current.append(byte) }
            else if current.count >= 4 { result.append(String(decoding: current, as: UTF8.self)); current.removeAll(keepingCapacity: true) }
            else { current.removeAll(keepingCapacity: true) }
        }
        if current.count >= 4 { result.append(String(decoding: current, as: UTF8.self)) }
        return result
    }
}
