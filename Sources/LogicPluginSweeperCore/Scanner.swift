import Foundation

private let supportedPluginExtensions: Set<String> = ["component", "vst", "vst3", "aaxplugin", "clap"]

public struct PluginScanConfiguration: Sendable {
    public var roots: [URL]
    public var includeSystemLocations: Bool
    public var collectFileDetails: Bool

    public static var `default`: PluginScanConfiguration {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let relativeRoots = [
            "Library/Audio/Plug-Ins/Components", "Library/Audio/Plug-Ins/VST",
            "Library/Audio/Plug-Ins/VST3", "Library/Audio/Plug-Ins/CLAP", "Library/Audio/Plug-Ins/AAX"
        ]
        return PluginScanConfiguration(roots: relativeRoots.map { home.appendingPathComponent($0) }, includeSystemLocations: true)
    }

    public init(roots: [URL], includeSystemLocations: Bool = true, collectFileDetails: Bool = false) {
        self.roots = roots; self.includeSystemLocations = includeSystemLocations; self.collectFileDetails = collectFileDetails
    }
}

public struct PluginScanner: Sendable {
    private let configuration: PluginScanConfiguration

    public init(configuration: PluginScanConfiguration = .default) {
        self.configuration = configuration
    }

    public func manufacturer(for plugin: PluginRecord) -> String? {
        guard let bundleURL = plugin.bundleURL, let bundle = Bundle(url: bundleURL) else { return plugin.manufacturer }
        return manufacturerValue(for: bundle, pluginName: plugin.name) ?? plugin.manufacturer
    }

    public func scan() -> ScanSummary {
        scan(isCancelled: { false })
    }

    public func scan(isCancelled: @Sendable () -> Bool) -> ScanSummary {
        let roots = uniqueURLs(configuration.roots + (configuration.includeSystemLocations ? systemRoots : []))
        var records: [PluginRecord] = []
        var seenBundles = Set<URL>()
        for root in roots where !isCancelled() && FileManager.default.fileExists(atPath: root.path) {
            for record in scanRoot(root, isCancelled: isCancelled) where seenBundles.insert(record.bundleURL?.standardizedFileURL ?? URL(fileURLWithPath: record.name)).inserted {
                records.append(record)
            }
        }
        let crashes = isCancelled() ? 0 : CrashLogScanner().recentPluginCrashCount()
        LogicPluginSweeperLog.scanner.info("Scan completed: \(records.count, privacy: .public) plugin bundles")
        return ScanSummary(plugins: records.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, crashLogCount: crashes, scannedAt: .now)
    }

    private var systemRoots: [URL] {
        ["/Library/Audio/Plug-Ins/Components", "/Library/Audio/Plug-Ins/VST", "/Library/Audio/Plug-Ins/VST3", "/Library/Audio/Plug-Ins/CLAP", "/Library/Audio/Plug-Ins/AAX"].map(URL.init(fileURLWithPath:))
    }

    private func scanRoot(_ root: URL, isCancelled: @Sendable () -> Bool) -> [PluginRecord] {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
        var records: [PluginRecord] = []
        for case let url as URL in enumerator {
            if isCancelled() { break }
            guard isPluginBundle(url) else { continue }
            let inventory = sizeFiles(in: url, keys: keys, collectDetails: configuration.collectFileDetails, isCancelled: isCancelled)
            if isCancelled() { break }
            let format = PluginFormat(pathExtension: url.pathExtension, root: root)
            let bundle = Bundle(url: url)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? url.deletingPathExtension().lastPathComponent
            let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let manufacturer = manufacturerValue(for: bundle, pluginName: name)
            records.append(PluginRecord(name: name, manufacturer: manufacturer, version: version, format: format, files: inventory.files, officialURL: nil, bundleURL: url, measuredBytes: inventory.byteCount, fileCount: inventory.fileCount))
            enumerator.skipDescendants()
        }
        return records
    }

    private func isPluginBundle(_ url: URL) -> Bool {
        supportedPluginExtensions.contains(url.pathExtension.lowercased())
    }

    private func manufacturerValue(for bundle: Bundle?, pluginName: String) -> String? {
        guard let info = bundle?.infoDictionary else { return nil }
        let metadataKeys = ["CFBundleVendor", "CFBundleManufacturer", "Manufacturer", "Vendor", "CompanyName", "AAXManufacturer", "kAudioUnitManufacturer", "VST3Vendor"]
        for key in metadataKeys {
            if let value = cleanManufacturer(info[key] as? String, pluginName: pluginName) { return value }
        }
        if let components = info["AudioComponents"] as? [[String: Any]] {
            for component in components {
                guard let displayName = component["name"] as? String,
                      let separator = displayName.firstIndex(of: ":") else { continue }
                let value = String(displayName[..<separator])
                if let value = cleanManufacturer(value, pluginName: pluginName) { return value }
            }
        }
        guard let identifier = info["CFBundleIdentifier"] as? String else { return nil }
        let ignored = Set(["com", "org", "net", "io", "co", "au", "vst", "vst2", "vst3", "clap", "aax", "audio", "plugin", "plugins"])
        for component in identifier.split(separator: ".").map(String.init) where !ignored.contains(component.lowercased()) {
            if let value = cleanManufacturer(component.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " "), pluginName: pluginName) {
                return value
            }
        }
        return nil
    }

    private func cleanManufacturer(_ value: String?, pluginName: String) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 2, cleaned.count <= 80,
              cleaned.localizedCaseInsensitiveCompare(pluginName) != .orderedSame else { return nil }
        return cleaned
    }

    private func sizeFiles(in bundle: URL, keys: Set<URLResourceKey>, collectDetails: Bool, isCancelled: @Sendable () -> Bool) -> FileInventory {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: bundle, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return FileInventory() }
        var files: [PluginFile] = []
        var totalByteCount: Int64 = 0
        var fileCount = 0
        if collectDetails { files.reserveCapacity(32) }
        for case let url as URL in enumerator {
            if isCancelled() { break }
            autoreleasepool {
                guard let values = try? url.resourceValues(forKeys: keys), values.isDirectory != true else { return }
                let rawByteCount = max(values.fileSize ?? 0, 0)
                let fileBytes = Int64(rawByteCount)
                add(fileBytes, to: &totalByteCount)
                fileCount += 1
                if collectDetails { files.append(PluginFile(path: url, byteCount: fileBytes, modifiedAt: values.contentModificationDate ?? .distantPast)) }
            }
        }
        return FileInventory(files: files, byteCount: totalByteCount, fileCount: fileCount)
    }

    private func add(_ value: Int64, to total: inout Int64) {
        let result = total.addingReportingOverflow(value)
        total = result.overflow ? Int64.max : result.partialValue
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { seen.insert($0.standardizedFileURL).inserted }
    }
}

private struct FileInventory {
    var files: [PluginFile] = []
    var byteCount: Int64 = 0
    var fileCount = 0
}

private extension PluginFormat {
    init(pathExtension: String, root: URL) {
        switch pathExtension.lowercased() { case "component": self = .audioUnit; case "vst": self = .vst; case "vst3": self = .vst3; case "aaxplugin": self = .aax; case "clap": self = .clap; default: self = .unknown }
    }
}

public struct CrashLogScanner: Sendable {
    public init() {}

    public func recentPluginCrashCount() -> Int {
        let directories = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"), URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")]
        return directories.reduce(0) { partial, directory in
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            return partial + urls.filter { $0.pathExtension == "ips" && $0.lastPathComponent.localizedCaseInsensitiveContains("audio") }.count
        }
    }
}
