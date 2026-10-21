import Foundation

public struct LogicProjectAnalyzer: Sendable {
    private let cache: LogicProjectCache?

    public init(cache: LogicProjectCache? = nil) {
        self.cache = cache
    }

    public func analyze(projects: [URL], plugin: PluginRecord) -> [ProjectDependencyReport] {
        let signatures = audioUnitSignatures(for: plugin)
        return projects.map { project in
            guard FileManager.default.isReadableFile(atPath: project.path) else {
                return ProjectDependencyReport(projectURL: project, status: .unreadable, details: "Le projet n’est pas lisible.")
            }
            guard let contents = searchableContents(of: project) else {
                return ProjectDependencyReport(projectURL: project, status: .unreadable, details: "Les métadonnées du projet ne sont pas lisibles.")
            }
            if matches(plugin, signatures: signatures, in: contents) {
                return ProjectDependencyReport(projectURL: project, status: .referenced, details: "Une référence textuelle au plugin a été trouvée dans les métadonnées du projet.")
            }
            return ProjectDependencyReport(projectURL: project, status: .noEvidence, details: "Aucune référence textuelle trouvée ; cela ne prouve pas que le plugin est inutilisé.")
        }
    }

    public func analyze(projects: [URL], plugins: [PluginRecord], onProjectStarted: (@Sendable (URL) -> Void)? = nil, onProgress: (@Sendable (Int, LogicProjectAnalysis) -> Void)? = nil) -> LogicProjectUsageSummary {
        let pluginsWithSignatures = plugins.map { ($0, audioUnitSignatures(for: $0)) }
        let patterns = pluginsWithSignatures.enumerated().flatMap { index, entry -> [(String, PatternMatch)] in
            let name = normalized(entry.0.name)
            let names = name.count >= 3 ? [(name, PatternMatch(pluginIndex: index, isSignature: false))] : []
            return names + entry.1.map { ($0, PatternMatch(pluginIndex: index, isSignature: true)) }
        }
        let matcher = MultiPatternMatcher(patterns: patterns)
        let pluginsByKey = Dictionary(plugins.map { (pluginKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        let pluginsByID = Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, $0) })
        let pluginKeys = pluginsWithSignatures.map { plugin, signatures in
            "\(pluginKey(plugin))|\(plugin.name)|\(plugin.version ?? "")|\(signatures.joined(separator: ","))"
        }
        var projectURLsByPlugin: [UUID: [URL]] = [:]
        var projectAnalyses: [LogicProjectAnalysis] = []
        var analyzedProjectCount = 0
        var unreadableProjectCount = 0

        for project in projects {
            if Task.isCancelled { break }
            onProjectStarted?(project)
            let fingerprint = cache?.fingerprint(for: project, pluginKeys: pluginKeys)
            if let fingerprint, let cached = cache?.load(project: project, fingerprint: fingerprint),
               cached.allSatisfy({ pluginsByKey[$0.pluginKey] != nil }) {
                let usages = cached.compactMap { item -> LogicProjectPluginUsage? in
                    guard let plugin = pluginsByKey[item.pluginKey] else { return nil }
                    return LogicProjectPluginUsage(plugin: plugin, trackName: item.trackName, confidence: item.trackName == nil ? .low : .medium)
                }
                for usage in usages where !projectURLsByPlugin[usage.pluginID, default: []].contains(project) {
                    projectURLsByPlugin[usage.pluginID, default: []].append(project)
                }
                analyzedProjectCount += 1
                projectAnalyses.append(LogicProjectAnalysis(projectURL: project, pluginUsages: usages))
                if let analysis = projectAnalyses.last { onProgress?(projectAnalyses.count, analysis) }
                continue
            }
            guard let content = searchableContent(of: project) else {
                if Task.isCancelled { break }
                unreadableProjectCount += 1
                projectAnalyses.append(LogicProjectAnalysis(projectURL: project, pluginUsages: [], isReadable: false))
                if let analysis = projectAnalyses.last { onProgress?(projectAnalyses.count, analysis) }
                continue
            }
            var usages: [LogicProjectPluginUsage] = []
            let candidateMatches = matcher.matches(in: content.text)
            if Task.isCancelled { break }
            analyzedProjectCount += 1
            let normalizedRuns = candidateMatches.names.isEmpty && candidateMatches.signatures.isEmpty ? [] : content.runs.map(normalized)
            for index in candidateMatches.names.union(candidateMatches.signatures).sorted() {
                let plugin = pluginsWithSignatures[index].0
                let hasSignatureEvidence = candidateMatches.signatures.contains(index)
                if !hasSignatureEvidence {
                    let hasBoundedName = containsBounded(normalized(plugin.name), in: normalizedRuns)
                    guard hasBoundedName else { continue }
                    if let manufacturer = plugin.manufacturer {
                        let normalizedManufacturer = normalized(manufacturer)
                        guard normalizedManufacturer.count >= 3,
                              containsPluginMetadata(name: normalized(plugin.name), manufacturer: normalizedManufacturer, in: normalizedRuns) else { continue }
                    } else {
                        guard normalized(plugin.name).filter({ $0.isLetter || $0.isNumber }).count >= 5 else { continue }
                    }
                }
                if !projectURLsByPlugin[plugin.id, default: []].contains(project) {
                    projectURLsByPlugin[plugin.id, default: []].append(project)
                }
                let trackName = nearbyTrackName(for: plugin, in: content.runs, normalizedRuns: normalizedRuns)
                usages.append(LogicProjectPluginUsage(plugin: plugin, trackName: trackName, confidence: trackName == nil ? .low : .medium))
            }
            projectAnalyses.append(LogicProjectAnalysis(projectURL: project, pluginUsages: usages))
            if let fingerprint {
                let cachedUsages = usages.compactMap { usage -> LogicProjectCache.CachedUsage? in
                    guard let plugin = pluginsByID[usage.pluginID] else { return nil }
                    return LogicProjectCache.CachedUsage(pluginKey: pluginKey(plugin), trackName: usage.trackName)
                }
                cache?.save(project: project, fingerprint: fingerprint, usages: cachedUsages)
            }
            if let analysis = projectAnalyses.last { onProgress?(projectAnalyses.count, analysis) }
        }

        let stats = plugins.compactMap { plugin -> PluginUsageStats? in
            guard let projectURLs = projectURLsByPlugin[plugin.id], !projectURLs.isEmpty else { return nil }
            return PluginUsageStats(plugin: plugin, projectURLs: projectURLs)
        }
        .sorted { $0.projectCount > $1.projectCount || ($0.projectCount == $1.projectCount && $0.pluginName.localizedStandardCompare($1.pluginName) == .orderedAscending) }
        return LogicProjectUsageSummary(analyzedProjectCount: analyzedProjectCount, unreadableProjectCount: unreadableProjectCount, pluginUsage: stats, projectAnalyses: projectAnalyses)
    }

    private func matches(_ plugin: PluginRecord, signatures: [String], in contents: String) -> Bool {
        if signatures.contains(where: contents.contains) { return true }
        let name = normalized(plugin.name)
        guard name.count >= 3, containsBounded(name, in: [contents]) else { return false }
        let manufacturer = plugin.manufacturer.flatMap { value in
            let value = normalized(value)
            return value.count >= 3 ? value : nil
        }
        if let manufacturer { return containsBounded(manufacturer, in: [contents]) }
        return true
    }

    private func pluginKey(_ plugin: PluginRecord) -> String {
        plugin.bundleURL?.standardizedFileURL.path ?? "\(plugin.format.rawValue)|\(plugin.manufacturer ?? "")|\(plugin.name)"
    }

    private func audioUnitSignatures(for plugin: PluginRecord) -> [String] {
        guard plugin.format == .audioUnit, let bundleURL = plugin.bundleURL,
              let components = Bundle(url: bundleURL)?.infoDictionary?["AudioComponents"] as? [[String: Any]] else { return [] }
        return components.compactMap { component in
            guard let manufacturer = component["manufacturer"] as? String,
                  let type = component["type"] as? String,
                  let subtype = component["subtype"] as? String,
                  manufacturer.utf8.count == 4, type.utf8.count == 4, subtype.utf8.count == 4 else { return nil }
            return normalized(String(manufacturer.reversed()) + String(type.reversed()) + String(subtype.reversed()))
        }
    }

    private func searchableContents(of project: URL) -> String? {
        searchableContent(of: project)?.text
    }

    private func searchableContent(of project: URL) -> SearchableProjectContent? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: project, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return nil }
        var chunks: [String] = []
        var runs: [String] = []
        for case let url as URL in enumerator {
            if Task.isCancelled { return nil }
            if url.lastPathComponent == "Project File Backups" || url.lastPathComponent == "Media" {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]), values.isDirectory != true else { continue }
            guard searchableFileExtensions.contains(url.lastPathComponent.lowercased()) || searchableFileExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard (values.fileSize ?? 0) <= maxMetadataFileSize else { continue }
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
            if let text = String(data: data, encoding: .utf8) {
                chunks.append(normalized(text))
                runs.append(contentsOf: printableRuns(in: data))
            } else {
                let binaryRuns = printableRuns(in: data)
                runs.append(contentsOf: binaryRuns)
                chunks.append(contentsOf: binaryRuns.map(normalized))
            }
            if let text = String(data: data, encoding: .utf16LittleEndian) { chunks.append(normalized(text)); runs.append(contentsOf: text.split(whereSeparator: { $0.isWhitespace }).map(String.init)) }
            if let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                let values = propertyListStrings(from: propertyList)
                chunks.append(normalized(values.joined(separator: "\n")))
                if !values.isEmpty { runs.append(values.joined(separator: " ")) }
                runs.append(contentsOf: values)
            }
        }
        guard !chunks.isEmpty else { return nil }
        return SearchableProjectContent(text: chunks.joined(separator: "\n"), runs: runs)
    }

    private func printableRuns(in data: Data) -> [String] {
        var result: [String] = []
        var current: [UInt8] = []
        for byte in data {
            if byte >= 0x20 && byte <= 0x7E {
                current.append(byte)
            } else if current.count >= 3 {
                result.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.removeAll(keepingCapacity: true)
            }
        }
        if current.count >= 3 { result.append(String(decoding: current, as: UTF8.self)) }
        return result
    }

    private func nearbyTrackName(for plugin: PluginRecord, in runs: [String], normalizedRuns: [String]) -> String? {
        let pluginName = normalized(plugin.name)
        for (index, run) in normalizedRuns.enumerated() where run.contains(pluginName) {
            let candidates = runs[max(0, index - 3)..<index].reversed()
            for candidate in candidates {
                let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedValue = normalized(value)
                guard value.count >= 2, value.count <= 80 else { continue }
                guard normalizedValue != pluginName else { continue }
                guard !(plugin.manufacturer.map { normalized(value).contains(normalized($0)) } ?? false) else { continue }
                guard !value.contains("/"), !value.contains("{"), !value.contains("}") else { continue }
                guard !normalizedValue.contains("plugin"), !normalizedValue.contains("channel") else { continue }
                return value
            }
        }
        return nil
    }

    private func containsBounded(_ value: String, in texts: [String]) -> Bool {
        let normalizedValue = normalized(value)
        guard !normalizedValue.isEmpty else { return false }
        return texts.contains { text in
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: normalizedValue, range: searchStart..<text.endIndex) {
                let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
                let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
                if !isWordCharacter(before) && !isWordCharacter(after) { return true }
                searchStart = range.upperBound
            }
            return false
        }
    }

    private func containsPluginMetadata(name: String, manufacturer: String, in texts: [String]) -> Bool {
        texts.contains { text in
            containsBounded(name, in: [text]) && containsBounded(manufacturer, in: [text])
        }
    }

    private func isWordCharacter(_ character: Character?) -> Bool {
        character?.isLetter == true || character?.isNumber == true
    }

    private struct SearchableProjectContent {
        let text: String
        let runs: [String]
    }

    private struct PatternMatch {
        let pluginIndex: Int
        let isSignature: Bool
    }

    private struct MultiPatternMatcher {
        private struct Node {
            var transitions: [UInt8: Int] = [:]
            var failure = 0
            var outputs: [PatternMatch] = []
        }

        private var nodes = [Node()]

        init(patterns: [(String, PatternMatch)]) {
            for (pattern, match) in patterns {
                var state = 0
                for byte in pattern.utf8 {
                    if let next = nodes[state].transitions[byte] {
                        state = next
                    } else {
                        let next = nodes.count
                        nodes.append(Node())
                        nodes[state].transitions[byte] = next
                        state = next
                    }
                }
                nodes[state].outputs.append(match)
            }
            var queue = Array(nodes[0].transitions.values)
            var cursor = 0
            while cursor < queue.count {
                let state = queue[cursor]
                cursor += 1
                for (byte, next) in nodes[state].transitions {
                    var failure = nodes[state].failure
                    while failure != 0 && nodes[failure].transitions[byte] == nil {
                        failure = nodes[failure].failure
                    }
                    nodes[next].failure = nodes[failure].transitions[byte] ?? 0
                    let inheritedOutputs = nodes[nodes[next].failure].outputs
                    nodes[next].outputs.append(contentsOf: inheritedOutputs)
                    queue.append(next)
                }
            }
        }

        func matches(in text: String) -> (names: Set<Int>, signatures: Set<Int>) {
            var names: Set<Int> = []
            var signatures: Set<Int> = []
            var state = 0
            var scannedBytes = 0
            for byte in text.utf8 {
                scannedBytes += 1
                if scannedBytes.isMultiple(of: 4096) && Task.isCancelled { break }
                while state != 0 && nodes[state].transitions[byte] == nil {
                    state = nodes[state].failure
                }
                state = nodes[state].transitions[byte] ?? 0
                for match in nodes[state].outputs {
                    if match.isSignature { signatures.insert(match.pluginIndex) }
                    else { names.insert(match.pluginIndex) }
                }
            }
            return (names, signatures)
        }
    }

    private func propertyListStrings(from value: Any) -> [String] {
        switch value {
        case let string as String:
            return [string]
        case let values as [Any]:
            return values.flatMap { propertyListStrings(from: $0) }
        case let values as [String: Any]:
            return values.flatMap { propertyListStrings(from: $0.value) }
        default:
            return []
        }
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    private let maxMetadataFileSize: Int = 32 * 1024 * 1024
    private let searchableFileExtensions: Set<String> = ["projectdata", "plist", "xml", "json", "txt"]
}

public struct LogicProjectLocator: Sendable {
    public init() {}

    public func find(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var projects: [URL] = []
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            guard url.pathExtension.lowercased() == "logicx" else { continue }
            projects.append(url)
            enumerator.skipDescendants()
        }
        return projects.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
