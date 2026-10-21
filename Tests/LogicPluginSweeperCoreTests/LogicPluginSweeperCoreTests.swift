import XCTest
@testable import LogicPluginSweeperCore

final class LogicPluginSweeperCoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testUninstallerKeepsRecoveryDataAndOnlyClearsCacheByDefault() throws {
        let support = temporaryDirectory.appendingPathComponent("LogicPluginSweeper")
        let cache = support.appendingPathComponent("LogicProjectCache")
        let quarantine = support.appendingPathComponent("Quarantine/record-1")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try Data("cached".utf8).write(to: cache.appendingPathComponent("project.json"))
        try Data("saved-plugin".utf8).write(to: quarantine.appendingPathComponent("plugin.component"))
        try Data("history".utf8).write(to: support.appendingPathComponent("history.sqlite"))
        let service = UninstallService(supportDirectory: support, preferencesURL: temporaryDirectory.appendingPathComponent("prefs.plist"), preferencesDomain: "test.\(UUID().uuidString)")
        let inventory = try service.inventory()
        XCTAssertEqual(inventory.cacheFileCount, 1)
        XCTAssertEqual(inventory.cacheBytes, 6)
        XCTAssertEqual(inventory.removalCount, 1)
        XCTAssertTrue(inventory.hasHistory)
        try service.removeData(choice: .keep)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.appendingPathComponent("plugin.component").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("history.sqlite").path))
    }

    func testUninstallerExportPreservesNamesBeforeExplicitDataDeletion() throws {
        let support = temporaryDirectory.appendingPathComponent("LogicPluginSweeper")
        let quarantine = support.appendingPathComponent("Quarantine/record-1")
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try Data("plugin".utf8).write(to: quarantine.appendingPathComponent("^MBassador.component"))
        let preferences = temporaryDirectory.appendingPathComponent("prefs.plist")
        try Data("preferences".utf8).write(to: preferences)
        let service = UninstallService(supportDirectory: support, preferencesURL: preferences, preferencesDomain: "test.\(UUID().uuidString)")
        let export = temporaryDirectory.appendingPathComponent("Export")
        try service.exportData(to: export)
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.appendingPathComponent("LogicPluginSweeper/Quarantine/record-1/^MBassador.component").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.appendingPathComponent("Preferences/prefs.plist").path))
        XCTAssertThrowsError(try service.exportData(to: support.appendingPathComponent("inside")))
        try service.removeData(choice: .delete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preferences.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.appendingPathComponent("LogicPluginSweeper/Quarantine/record-1/^MBassador.component").path))
    }

    func testPluginTotalBytesIsExactSum() {
        let plugin = PluginRecord(name: "Test", format: .vst3, files: [PluginFile(path: URL(fileURLWithPath: "/tmp/a"), byteCount: 10, modifiedAt: .now), PluginFile(path: URL(fileURLWithPath: "/tmp/b"), byteCount: 32, modifiedAt: .now)])
        XCTAssertEqual(plugin.totalBytes, 42)
    }

    func testPluginTotalBytesSaturatesOnOverflow() {
        let plugin = PluginRecord(name: "Huge", format: .vst, files: [
            PluginFile(path: URL(fileURLWithPath: "/tmp/a"), byteCount: Int64.max, modifiedAt: .now),
            PluginFile(path: URL(fileURLWithPath: "/tmp/b"), byteCount: 1, modifiedAt: .now)
        ])
        XCTAssertEqual(plugin.totalBytes, Int64.max)
    }

    func testRecommendationAndConfidenceLabels() {
        let plugin = PluginRecord(name: "Suggested", format: .clap, files: [])
        let recommendation = PluginRecommendation(plugin: plugin, title: "Vérifier", reason: "Test", confidence: .high)
        XCTAssertEqual(recommendation.pluginID, plugin.id)
        XCTAssertEqual(recommendation.recoverableBytes, 0)
        XCTAssertEqual(RecommendationConfidence.high.label, "Élevée")
        XCTAssertEqual(RecommendationConfidence.medium.label, "Moyenne")
        XCTAssertEqual(RecommendationConfidence.low.label, "Faible")
    }

    func testSemanticVersionFollowsSemVerPrecedence() {
        let alpha = SemanticVersion(tag: "v1.0.0-alpha")!
        let alphaOne = SemanticVersion(tag: "1.0.0-alpha.1")!
        let beta = SemanticVersion(tag: "1.0.0-beta")!
        let release = SemanticVersion(tag: "1.0.0")!
        let next = SemanticVersion(tag: "1.1.0")!
        XCTAssertTrue(alpha < alphaOne)
        XCTAssertTrue(alphaOne < beta)
        XCTAssertTrue(beta < release)
        XCTAssertTrue(release < next)
        XCTAssertEqual(SemanticVersion(tag: "1.0.0+build.5"), release)
        XCTAssertNil(SemanticVersion(tag: "nightly-32"))
        XCTAssertNil(SemanticVersion(tag: "1.0"))
    }

    func testReleaseOfferPrefersDMGAndKeepsReleaseURL() throws {
        let release = GitHubRelease(
            tagName: "v1.2.0",
            name: "LogicPluginSweeper 1.2.0",
            htmlURL: URL(string: "https://github.com/syb-illin/LogicPluginSweeper/releases/tag/v1.2.0")!,
            prerelease: false,
            assets: [
                GitHubReleaseAsset(name: "LogicPluginSweeper.zip", browserDownloadURL: URL(string: "https://example.com/app.zip")!),
                GitHubReleaseAsset(name: "LogicPluginSweeper.dmg", browserDownloadURL: URL(string: "https://example.com/app.dmg")!)
            ]
        )
        let offer = try UpdateOffer(release: release)
        XCTAssertEqual(offer.version.description, "1.2.0")
        XCTAssertEqual(offer.downloadURL.absoluteString, "https://example.com/app.dmg")
        XCTAssertEqual(offer.releaseURL, release.htmlURL)
        XCTAssertFalse(offer.prerelease)
    }

    func testReleaseSelectionRespectsStableAndNightlyChannels() throws {
        let stable = GitHubRelease(tagName: "v1.1.0", name: "Stable", htmlURL: URL(string: "https://example.com/stable")!, prerelease: false, assets: [])
        let nightly = GitHubRelease(tagName: "v1.2.0-nightly.4", name: "Nightly", htmlURL: URL(string: "https://example.com/nightly")!, prerelease: true, assets: [])
        let oldNightly = GitHubRelease(tagName: "nightly-2", name: "Legacy", htmlURL: URL(string: "https://example.com/legacy")!, prerelease: true, assets: [])
        XCTAssertEqual(try ReleaseService.selectLatest(releases: [stable, nightly, oldNightly], channel: .stable).tagName, "v1.1.0")
        XCTAssertEqual(try ReleaseService.selectLatest(releases: [stable, nightly, oldNightly], channel: .nightly).tagName, "v1.2.0-nightly.4")
        XCTAssertThrowsError(try ReleaseService.selectLatest(releases: [oldNightly], channel: .stable))
        XCTAssertTrue(ReleaseService.isNewer(SemanticVersion(tag: "1.1.0-nightly.5")!, than: SemanticVersion(tag: "1.1.0")!, channel: .nightly))
        XCTAssertFalse(ReleaseService.isNewer(SemanticVersion(tag: "1.0.9-nightly.5")!, than: SemanticVersion(tag: "1.1.0")!, channel: .nightly))
    }

    func testUpdateChannelsAndReleaseErrorsHaveUserMessages() {
        XCTAssertEqual(UpdateChannel.stable.rawValue, "stable")
        XCTAssertEqual(UpdateChannel.nightly.rawValue, "nightly")
        XCTAssertFalse(ReleaseService.ReleaseServiceError.invalidURL.localizedDescription.isEmpty)
        XCTAssertFalse(ReleaseService.ReleaseServiceError.httpStatus(503).localizedDescription.isEmpty)
        XCTAssertFalse(ReleaseService.ReleaseServiceError.noSemanticRelease.localizedDescription.isEmpty)
        XCTAssertFalse(ReleaseService.ReleaseServiceError.invalidVersion("bad").localizedDescription.isEmpty)
    }

    func testScannerRecognizesSupportedBundleExtensions() throws {
        let root = temporaryDirectory.appendingPathComponent("Plugins")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Example.vst3"), withIntermediateDirectories: true)
        let result = PluginScanner(configuration: PluginScanConfiguration(roots: [root], includeSystemLocations: false)).scan()
        XCTAssertEqual(result.plugins.first?.format, .vst3)
    }

    func testScannerReadsBundleMetadataAndDetailedFiles() throws {
        let bundle = temporaryDirectory.appendingPathComponent("Metadata.component")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundleDisplayName": "Metadata Synth",
            "CFBundleShortVersionString": "3.2.1",
            "CFBundleVendor": "Acme Audio"
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try Data(repeating: 0x42, count: 12).write(to: contents.appendingPathComponent("binary"))

        let configuration = PluginScanConfiguration(roots: [temporaryDirectory], includeSystemLocations: false, collectFileDetails: true)
        let result = PluginScanner(configuration: configuration).scan()
        let plugin = try XCTUnwrap(result.plugins.first)
        XCTAssertEqual(plugin.name, "Metadata Synth")
        XCTAssertEqual(plugin.manufacturer, "Acme Audio")
        XCTAssertEqual(plugin.version, "3.2.1")
        XCTAssertEqual(plugin.format, .audioUnit)
        XCTAssertEqual(plugin.fileCount, 2)
        XCTAssertEqual(plugin.files.count, 2)
        XCTAssertEqual(plugin.totalBytes, Int64(plist.count + 12))
    }

    func testScannerRecognizesEverySupportedFormat() throws {
        let root = temporaryDirectory.appendingPathComponent("Plugins")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for suffix in ["component", "vst", "vst3", "aaxplugin", "clap"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Plugin.\(suffix)"), withIntermediateDirectories: true)
        }

        let result = PluginScanner(configuration: PluginScanConfiguration(roots: [root], includeSystemLocations: false)).scan()
        XCTAssertEqual(Set(result.plugins.map(\.format)), Set([.audioUnit, .vst, .vst3, .aax, .clap]))
    }

    func testScannerDeduplicatesOverlappingRoots() throws {
        let root = temporaryDirectory.appendingPathComponent("Plugins")
        let pluginURL = root.appendingPathComponent("Example.vst3")
        try FileManager.default.createDirectory(at: pluginURL, withIntermediateDirectories: true)
        try Data("plugin".utf8).write(to: pluginURL.appendingPathComponent("binary"))
        let result = PluginScanner(configuration: PluginScanConfiguration(roots: [root, root], includeSystemLocations: false)).scan()
        XCTAssertEqual(result.plugins.count, 1)
        XCTAssertEqual(result.plugins.first?.totalBytes, 6)
        XCTAssertTrue(result.plugins.first?.files.isEmpty == true)
    }

    func testScannerCanStopBeforeWalkingRoots() throws {
        let root = temporaryDirectory.appendingPathComponent("Plugins")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Example.vst3"), withIntermediateDirectories: true)
        let result = PluginScanner(configuration: PluginScanConfiguration(roots: [root], includeSystemLocations: false)).scan(isCancelled: { true })
        XCTAssertTrue(result.plugins.isEmpty)
    }

    func testScannerReturnsEmptyResultForMissingRoot() {
        let root = temporaryDirectory.appendingPathComponent("does-not-exist")
        let result = PluginScanner(configuration: PluginScanConfiguration(roots: [root], includeSystemLocations: false)).scan()
        XCTAssertTrue(result.plugins.isEmpty)
        XCTAssertEqual(result.crashLogCount, 0)
    }

    func testScannerCanIncludeSystemLocations() throws {
        let root = temporaryDirectory.appendingPathComponent("UserPlugins")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = PluginScanner(configuration: PluginScanConfiguration(roots: [root], includeSystemLocations: true)).scan(isCancelled: { true })
        XCTAssertTrue(result.plugins.isEmpty)
    }

    func testDomainTotalsAndDefaults() {
        let plugin = PluginRecord(name: "Unknown", format: .unknown, files: [], healthMessage: "not checked")
        let summary = ScanSummary(plugins: [plugin], crashLogCount: 0, scannedAt: .now)
        XCTAssertEqual(plugin.license, .unknown)
        XCTAssertEqual(plugin.health, .notChecked)
        XCTAssertEqual(summary.totalBytes, 0)
        XCTAssertEqual(ProjectDependencyReport.Status.notImplemented.rawValue, "notImplemented")
    }

    func testLegacyRemovalRecordDefaultsToNoHash() {
        let record = RemovalRecord(pluginName: "Legacy", originalPaths: [], quarantineURL: temporaryDirectory, byteCount: 12)
        XCTAssertNil(record.contentHash)
        XCTAssertNil(record.restoredAt)
    }

    func testDefaultScannerUsesExpectedAudioPluginRoots() {
        let configuration = PluginScanConfiguration.default
        XCTAssertTrue(configuration.includeSystemLocations)
        XCTAssertEqual(configuration.roots.count, 5)
        XCTAssertTrue(configuration.roots.allSatisfy { $0.path.contains("Library/Audio/Plug-Ins") })
    }

    func testFormatRedundancyRequiresMatchingIdentity() {
        let audioUnit = PluginRecord(name: "Synth", manufacturer: "Acme", version: "1.2", format: .audioUnit, files: [])
        let vst = PluginRecord(name: "Synth", manufacturer: "Acme", version: "1.2", format: .vst, files: [])
        let differentVersion = PluginRecord(name: "Synth", manufacturer: "Acme", version: "2.0", format: .vst3, files: [])
        let candidates = FormatRedundancyAnalyzer().candidates(in: [audioUnit, vst, differentVersion])
        XCTAssertEqual(candidates.map(\.alternative.id), [vst.id])
    }

    func testFormatRedundancyIgnoresIncompleteIdentity() {
        let audioUnit = PluginRecord(name: "Synth", manufacturer: "Acme", version: "1.2", format: .audioUnit, files: [])
        let missingManufacturer = PluginRecord(name: "Synth", version: "1.2", format: .vst, files: [])
        let missingVersion = PluginRecord(name: "Synth", manufacturer: "Acme", format: .vst3, files: [])
        XCTAssertTrue(FormatRedundancyAnalyzer().candidates(in: [audioUnit, missingManufacturer, missingVersion]).isEmpty)
    }

    func testLogicProjectAnalyzerIsConservative() throws {
        let project = temporaryDirectory.appendingPathComponent("Demo.logicx")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("Acme Demo 1.0".utf8).write(to: project.appendingPathComponent("projectData"))
        let plugin = PluginRecord(name: "Demo", manufacturer: "Acme", version: "1.0", format: .audioUnit, files: [])
        let reports = LogicProjectAnalyzer().analyze(projects: [project, temporaryDirectory.appendingPathComponent("missing.logicx")], plugin: plugin)
        XCTAssertEqual(reports.map(\.status), [.referenced, .unreadable])
    }

    func testLogicProjectUsageAggregatesReferencedPlugins() throws {
        let project = temporaryDirectory.appendingPathComponent("Demo.logicx")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("Acme Demo 1.0".utf8).write(to: project.appendingPathComponent("projectData"))
        let plugin = PluginRecord(name: "Demo", manufacturer: "Acme", version: "1.0", format: .audioUnit, files: [])
        let summary = LogicProjectAnalyzer().analyze(projects: [project], plugins: [plugin])
        XCTAssertEqual(summary.analyzedProjectCount, 1)
        XCTAssertEqual(summary.pluginUsage.first?.projectCount, 1)
        XCTAssertEqual(summary.projectAnalyses.first?.pluginUsages.first?.manufacturer, "Acme")
    }

    func testLogicProjectAnalysisCountsDistinctPluginsOnly() {
        let plugin = PluginRecord(name: "Demo", format: .audioUnit, files: [])
        let duplicateUsages = [
            LogicProjectPluginUsage(plugin: plugin, trackName: "Track 1"),
            LogicProjectPluginUsage(plugin: plugin, trackName: "Track 2")
        ]
        let analysis = LogicProjectAnalysis(projectURL: temporaryDirectory.appendingPathComponent("Demo.logicx"), pluginUsages: duplicateUsages)

        XCTAssertEqual(analysis.distinctPluginCount, 1)
        XCTAssertEqual(analysis.distinctPluginIDs, [plugin.id])
    }

    func testLogicProjectDoesNotAssociateSameNameWithWrongManufacturer() throws {
        let project = temporaryDirectory.appendingPathComponent("Demo.logicx")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("Acme Demo 1.0".utf8).write(to: project.appendingPathComponent("ProjectData"))
        let installed = PluginRecord(name: "Demo", manufacturer: "Other Vendor", format: .audioUnit, files: [])

        let summary = LogicProjectAnalyzer().analyze(projects: [project], plugins: [installed])

        XCTAssertEqual(summary.analyzedProjectCount, 1)
        XCTAssertTrue(summary.pluginUsage.isEmpty)
    }

    func testLogicProjectIgnoresShortPluginNameInsideLargerWords() throws {
        let project = temporaryDirectory.appendingPathComponent("FalsePositive.logicx")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("Project Profile Processor".utf8).write(to: project.appendingPathComponent("ProjectData"))
        let plugin = PluginRecord(name: "Pro", manufacturer: "Acme", format: .audioUnit, files: [])

        let summary = LogicProjectAnalyzer().analyze(projects: [project], plugins: [plugin])

        XCTAssertTrue(summary.pluginUsage.isEmpty)
        XCTAssertEqual(summary.projectAnalyses.first?.distinctPluginCount, 0)
    }

    func testLogicProjectDoesNotCombineNameAndManufacturerFromSeparateMetadataRuns() throws {
        let project = temporaryDirectory.appendingPathComponent("SeparatedMetadata.logicx")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("Acme\nUnrelated Demo project".utf8).write(to: project.appendingPathComponent("ProjectData"))
        let plugin = PluginRecord(name: "Demo", manufacturer: "Acme", format: .audioUnit, files: [])

        let summary = LogicProjectAnalyzer().analyze(projects: [project], plugins: [plugin])

        XCTAssertTrue(summary.pluginUsage.isEmpty)
        XCTAssertEqual(summary.projectAnalyses.first?.distinctPluginCount, 0)
    }

    func testLogicProjectMatchesOverlappingNamesInOnePass() throws {
        let project = temporaryDirectory.appendingPathComponent("Overlapping.logicx")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("Acme Piano Pro".utf8).write(to: project.appendingPathComponent("ProjectData"))
        let piano = PluginRecord(name: "Piano", manufacturer: "Acme", format: .audioUnit, files: [])
        let pianoPro = PluginRecord(name: "Piano Pro", manufacturer: "Acme", format: .audioUnit, files: [])
        let other = PluginRecord(name: "Synth", manufacturer: "Acme", format: .audioUnit, files: [])

        let summary = LogicProjectAnalyzer().analyze(projects: [project], plugins: [piano, pianoPro, other])

        XCTAssertEqual(Set(summary.pluginUsage.map(\.id)), Set([piano.id, pianoPro.id]))
    }

    func testLogicProjectUsageReadsBinaryProjectDataAndKeepsProjectRelationship() throws {
        let project = temporaryDirectory.appendingPathComponent("Binary.logicx")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var bytes = Array("Lead Piano\0Acme Piano Pro\0".utf8)
        bytes.append(contentsOf: [0, 1, 2, 3, 0])
        bytes.append(contentsOf: Array("Instrument Names\0".utf8))
        try Data(bytes).write(to: project.appendingPathComponent("ProjectData"))
        let plugin = PluginRecord(name: "Piano Pro", manufacturer: "Acme", format: .audioUnit, files: [])

        let summary = LogicProjectAnalyzer().analyze(projects: [project], plugins: [plugin])

        XCTAssertEqual(summary.analyzedProjectCount, 1)
        XCTAssertEqual(summary.pluginUsage.first?.projectURLs, [project])
        XCTAssertEqual(summary.projectAnalyses.first?.pluginUsages.first?.pluginName, "Piano Pro")
    }

    func testLogicProjectMatchesAudioUnitIdentifierWhenDisplayNameIsAbsent() throws {
        let bundle = temporaryDirectory.appendingPathComponent("ValhallaDelay.component")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["AudioComponents": [["manufacturer": "oDin", "type": "aufx", "subtype": "dLay"]]]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let project = temporaryDirectory.appendingPathComponent("Song.logicx")
        let alternative = project.appendingPathComponent("Alternatives/000")
        try FileManager.default.createDirectory(at: alternative, withIntermediateDirectories: true)
        try Data("\0niDoxfuayaLd\0".utf8).write(to: alternative.appendingPathComponent("ProjectData"))
        let plugin = PluginRecord(name: "ValhallaDelay", format: .audioUnit, files: [], bundleURL: bundle)
        let unrelated = PluginRecord(name: "Other", format: .audioUnit, files: [])

        let summary = LogicProjectAnalyzer().analyze(projects: [project], plugins: [plugin, unrelated])

        XCTAssertEqual(summary.pluginUsage.map(\.id), [plugin.id])
        XCTAssertEqual(summary.projectAnalyses.first?.pluginUsages.first?.pluginName, plugin.name)
    }

    func testLogicProjectCacheInvalidatesChangedMetadataAndPluginInventory() throws {
        let project = temporaryDirectory.appendingPathComponent("Cache.logicx")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let metadata = project.appendingPathComponent("ProjectData")
        try Data("First Synth".utf8).write(to: metadata)
        let first = PluginRecord(name: "First Synth", format: .audioUnit, files: [])
        let second = PluginRecord(name: "Second Synth", format: .audioUnit, files: [])
        let analyzer = LogicProjectAnalyzer(cache: LogicProjectCache(directory: temporaryDirectory.appendingPathComponent("Cache")))

        XCTAssertEqual(analyzer.analyze(projects: [project], plugins: [first]).pluginUsage.map(\.id), [first.id])
        XCTAssertEqual(analyzer.analyze(projects: [project], plugins: [second]).pluginUsage.count, 0)

        try Data("Second Synth with a longer project record".utf8).write(to: metadata)
        XCTAssertEqual(analyzer.analyze(projects: [project], plugins: [second]).pluginUsage.map(\.id), [second.id])
    }

    func testLogicProjectCacheReturnsSavedEntryOnlyForMatchingFingerprint() throws {
        let project = temporaryDirectory.appendingPathComponent("Cached.logicx")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let metadata = project.appendingPathComponent("ProjectData")
        try Data("Synth A".utf8).write(to: metadata)
        let cache = LogicProjectCache(directory: temporaryDirectory.appendingPathComponent("Entries"))
        let fingerprint = try XCTUnwrap(cache.fingerprint(for: project, pluginKeys: ["synth-a"]))
        cache.save(project: project, fingerprint: fingerprint, usages: [.init(pluginKey: "synth-a", trackName: nil)])
        let reopened = LogicProjectCache(directory: temporaryDirectory.appendingPathComponent("Entries"))

        XCTAssertEqual(reopened.load(project: project, fingerprint: fingerprint)?.count, 1)
        XCTAssertNil(cache.load(project: project, fingerprint: "outdated"))
        XCTAssertNotEqual(cache.fingerprint(for: project, pluginKeys: ["synth-b"]), fingerprint)
    }

    func testLogicProjectCacheStatisticsAndClearKeepUnrelatedFiles() throws {
        let directory = temporaryDirectory.appendingPathComponent("Entries")
        let cache = LogicProjectCache(directory: directory)
        XCTAssertEqual(try cache.statistics().fileCount, 0)
        let project = temporaryDirectory.appendingPathComponent("Demo.logicx")
        cache.save(project: project, fingerprint: "current", usages: [])
        let unrelated = directory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelated)

        XCTAssertEqual(try cache.statistics().fileCount, 1)
        XCTAssertNotNil(try cache.statistics().latestModificationDate)
        try cache.clear()
        XCTAssertEqual(try cache.statistics().fileCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testPluginReputationSearchContainsOnlyPluginIdentity() throws {
        let plugin = PluginRecord(name: "Piano Pro", manufacturer: "Acme Audio", version: "2.1", format: .audioUnit, files: [])
        let url = try XCTUnwrap(PluginReputationSearch.url(for: plugin))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
        XCTAssertTrue(query.contains("Piano Pro"))
        XCTAssertTrue(query.contains("Acme Audio"))
        XCTAssertFalse(query.contains("/Users/"))
    }

    func testPluginBackupContainsCompleteBundleAndRestorationManifest() throws {
        let bundle = temporaryDirectory.appendingPathComponent("Backup Demo.component")
        let nestedFile = bundle.appendingPathComponent("Contents/MacOS/^MBassador.component")
        try FileManager.default.createDirectory(at: nestedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plugin binary".utf8).write(to: nestedFile)
        let plugin = PluginRecord(name: "Backup Demo", format: .audioUnit, files: [PluginFile(path: nestedFile, byteCount: 13, modifiedAt: .now)], bundleURL: bundle)
        let backupFolder = temporaryDirectory.appendingPathComponent("Backups")

        let archive = try PluginBackupService().createArchive(for: plugin, in: backupFolder)

        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        let extracted = temporaryDirectory.appendingPathComponent("Extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", archive.path, "-d", extracted.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let extractedRoot = try XCTUnwrap(
            FileManager.default
                .contentsOfDirectory(at: extracted, includingPropertiesForKeys: [.isDirectoryKey])
                .first { $0.lastPathComponent != "__MACOSX" }
        )
        let manifest = extractedRoot.appendingPathComponent("LogicPluginSweeper-Backup.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        let manifestText = String(decoding: try Data(contentsOf: manifest), as: UTF8.self)
        XCTAssertTrue(manifestText.contains(bundle.path))
        XCTAssertTrue(manifestText.contains("Contents/MacOS/^MBassador.component"))
        XCTAssertTrue(manifestText.contains("Files/00/\(bundle.lastPathComponent) -> \(bundle.path)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedRoot.appendingPathComponent("Files/00/\(bundle.lastPathComponent)/Contents/MacOS/^MBassador.component").path))
        let archivedPlugin = FileManager.default
            .enumerator(at: extractedRoot, includingPropertiesForKeys: [.isDirectoryKey])?
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent == "^MBassador.component" }
        XCTAssertTrue(archivedPlugin != nil)
    }

    func testPluginFootprintReportsBundleLocationAndBytes() throws {
        let bundle = temporaryDirectory.appendingPathComponent("Footprint.vst3")
        let binary = bundle.appendingPathComponent("Contents/plugin")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 24).write(to: binary)
        let plugin = PluginRecord(name: "Footprint", format: .vst3, files: [], bundleURL: bundle)

        let footprint = PluginFootprintScanner().scan(plugin: plugin)

        XCTAssertTrue(footprint.isComplete)
        XCTAssertEqual(footprint.locations.first?.kind, .pluginBundle)
        XCTAssertEqual(footprint.totalBytes, 24)
        XCTAssertEqual(footprint.locations.first?.fileCount, 1)
    }

    func testQuarantineMovesAndRestoresMultiplePluginLocations() throws {
        let bundle = temporaryDirectory.appendingPathComponent("Multi.component")
        let binary = bundle.appendingPathComponent("Contents/plugin")
        let settings = temporaryDirectory.appendingPathComponent("Preferences/Multi.plist")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bundle".utf8).write(to: binary)
        try Data("settings".utf8).write(to: settings)
        let plugin = PluginRecord(name: "Multi", format: .audioUnit, files: [], bundleURL: bundle)
        let locations = [
            PluginLocation(path: bundle, kind: .pluginBundle, byteCount: 6, fileCount: 1),
            PluginLocation(path: settings, kind: .preferences, byteCount: 8, fileCount: 1)
        ]
        let service = QuarantineService(root: temporaryDirectory.appendingPathComponent("Quarantine"))

        let record = try service.quarantine(plugin, locations: locations)

        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.quarantineURL.appendingPathComponent("items/00-Multi.component/Contents/plugin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.quarantineURL.appendingPathComponent("items/01-Multi.plist").path))
        try service.restore(record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: binary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings.path))
    }

    func testLogicProjectAnalyzerReadsBinaryPropertyListAndLocatorFindsProjects() throws {
        let root = temporaryDirectory.appendingPathComponent("Logic")
        let project = root.appendingPathComponent("Nested/Demo.logicx")
        let sibling = root.appendingPathComponent("Other.logicx")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let metadata: [String: Any] = ["plugin": ["manufacturer": "Acme", "name": "Piano", "version": "4.0"]]
        let plist = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
        try plist.write(to: project.appendingPathComponent("projectData"))
        let plugin = PluginRecord(name: "Piano", manufacturer: "Acme", version: "4.0", format: .audioUnit, files: [])

        let projects = LogicProjectLocator().find(in: root)
        let summary = LogicProjectAnalyzer().analyze(projects: projects, plugins: [plugin])
        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(summary.analyzedProjectCount, 1)
        XCTAssertEqual(summary.unreadableProjectCount, 1)
        XCTAssertEqual(summary.pluginUsage.first?.pluginName, "Piano")
    }

    func testLogicProjectAnalyzerDoesNotInferUnusedFromMissingEvidence() throws {
        let project = temporaryDirectory.appendingPathComponent("Empty.logicx")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("unrelated metadata".utf8).write(to: project.appendingPathComponent("projectData"))
        let plugin = PluginRecord(name: "Piano", manufacturer: "Acme", version: "4.0", format: .audioUnit, files: [])
        let report = try XCTUnwrap(LogicProjectAnalyzer().analyze(projects: [project], plugin: plugin).first)
        XCTAssertEqual(report.status, .noEvidence)
        XCTAssertTrue(report.details.contains("ne prouve pas"))
    }

    func testLogicProjectAnalyzerReportsUnreadableMetadata() throws {
        let project = temporaryDirectory.appendingPathComponent("NoMetadata.logicx")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let plugin = PluginRecord(name: "Piano", format: .audioUnit, files: [])
        let report = try XCTUnwrap(LogicProjectAnalyzer().analyze(projects: [project], plugin: plugin).first)
        XCTAssertEqual(report.status, .unreadable)
    }

    func testLogicProjectAnalyzerIgnoresNonStringPropertyListValues() throws {
        let project = temporaryDirectory.appendingPathComponent("Values.logicx")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let metadata: [String: Any] = ["plugin": "Piano", "enabled": true, "latency": 128]
        let plist = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
        try plist.write(to: project.appendingPathComponent("projectData"))
        let plugin = PluginRecord(name: "Piano", format: .audioUnit, files: [])
        let report = try XCTUnwrap(LogicProjectAnalyzer().analyze(projects: [project], plugin: plugin).first)
        XCTAssertEqual(report.status, .referenced)
    }

    func testQuarantineMovesAndRestoresFiles() throws {
        let original = temporaryDirectory.appendingPathComponent("Example.vst3/Contents/plugin.bin")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plugin".utf8).write(to: original)
        let bundle = temporaryDirectory.appendingPathComponent("Example.vst3")
        let plugin = PluginRecord(name: "Example", format: .vst3, files: [PluginFile(path: original, byteCount: 6, modifiedAt: .now)], bundleURL: bundle)
        let quarantineRoot = temporaryDirectory.appendingPathComponent("Quarantine")
        let service = QuarantineService(root: quarantineRoot)
        let record = try service.quarantine(plugin)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.quarantineURL.appendingPathComponent("Example.vst3/Contents/plugin.bin").path))
        try service.restore(record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testQuarantineRejectsUnavailableBundle() {
        let plugin = PluginRecord(name: "Missing", format: .vst, files: [], bundleURL: temporaryDirectory.appendingPathComponent("Missing.vst"))
        XCTAssertThrowsError(try QuarantineService(root: temporaryDirectory.appendingPathComponent("Quarantine")).quarantine(plugin)) { error in
            XCTAssertTrue(error is QuarantineService.QuarantineError)
        }
    }

    func testQuarantineRefusesTamperedContentAndOccupiedOriginalPath() throws {
        let bundle = temporaryDirectory.appendingPathComponent("Example.vst3")
        let binary = bundle.appendingPathComponent("plugin.bin")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: binary)
        let plugin = PluginRecord(name: "Example", format: .vst3, files: [], bundleURL: bundle)
        let service = QuarantineService(root: temporaryDirectory.appendingPathComponent("Quarantine"))
        let record = try service.quarantine(plugin)
        let quarantinedBinary = record.quarantineURL.appendingPathComponent("Example.vst3/plugin.bin")
        try Data("tampered".utf8).write(to: quarantinedBinary)
        XCTAssertThrowsError(try service.restore(record))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))

        try Data("original".utf8).write(to: quarantinedBinary)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        XCTAssertThrowsError(try service.restore(record))
    }

    func testQuarantineRefusesMissingQuarantinedItem() throws {
        let bundle = temporaryDirectory.appendingPathComponent("Example.vst3")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let plugin = PluginRecord(name: "Example", format: .vst3, files: [], bundleURL: bundle)
        let service = QuarantineService(root: temporaryDirectory.appendingPathComponent("Quarantine"))
        let record = try service.quarantine(plugin)
        try FileManager.default.removeItem(at: record.quarantineURL)
        XCTAssertThrowsError(try service.restore(record))
    }

    func testReportExporterEscapesCSVAndIncludesUsageInJSON() throws {
        let plugin = PluginRecord(name: "Piano, \"Pro\"", manufacturer: "Acme", format: .audioUnit, files: [])
        let scan = ScanSummary(plugins: [plugin], crashLogCount: 0, scannedAt: .now)
        let usage = LogicProjectUsageSummary(analyzedProjectCount: 1, unreadableProjectCount: 0, pluginUsage: [PluginUsageStats(plugin: plugin, projectURLs: [temporaryDirectory.appendingPathComponent("Demo.logicx")])])
        let exporter = ReportExporter()
        let csv = String(decoding: exporter.csv(scan: scan), as: UTF8.self)
        XCTAssertTrue(csv.contains("\"Piano, \"\"Pro\"\"\""))
        let json = try exporter.json(scan: scan, usage: usage)
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("Piano"))
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("analyzedProjectCount"))
    }

    func testSQLiteStorePersistsRemovalAcrossReopen() async throws {
        let databaseURL = temporaryDirectory.appendingPathComponent("removals.sqlite")
        let record = RemovalRecord(pluginName: "Example", originalPaths: [temporaryDirectory.appendingPathComponent("Example.component")], quarantineURL: temporaryDirectory.appendingPathComponent("Quarantine"), byteCount: 42)
        let store = try SQLiteStore(url: databaseURL)
        try await store.saveRemoval(record)
        let reopened = try SQLiteStore(url: databaseURL)
        let loaded = try await reopened.loadRemovals()
        XCTAssertEqual(loaded.map(\.id), [record.id])
        try await reopened.deleteRemoval(id: record.id)
        let remaining = try await reopened.loadRemovals()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSQLiteStorePersistsScanHistory() async throws {
        let databaseURL = temporaryDirectory.appendingPathComponent("history.sqlite")
        let store = try SQLiteStore(url: databaseURL)
        let plugin = PluginRecord(name: "Persisted", format: .clap, files: [])
        try await store.save(scan: ScanSummary(plugins: [plugin], crashLogCount: 0, scannedAt: .now))
        let loaded = try await store.loadPlugins()
        XCTAssertEqual(loaded.map(\.name), ["Persisted"])
        XCTAssertEqual(loaded.first?.format, .clap)
    }

    func testSQLiteStorePersistsLastScanWhenInventoryIsEmpty() async throws {
        let databaseURL = temporaryDirectory.appendingPathComponent("empty-scan.sqlite")
        let scannedAt = Date(timeIntervalSince1970: 1_797_000_000)
        let store = try SQLiteStore(url: databaseURL)
        try await store.save(scan: ScanSummary(plugins: [], crashLogCount: 0, scannedAt: scannedAt))

        let reopened = try SQLiteStore(url: databaseURL)
        let restoredDate = try await reopened.loadLastScan()
        let restoredPlugins = try await reopened.loadPlugins()
        XCTAssertEqual(restoredDate, scannedAt)
        XCTAssertTrue(restoredPlugins.isEmpty)
    }

    func testSQLiteStoreReplacesPreviousScan() async throws {
        let databaseURL = temporaryDirectory.appendingPathComponent("history.sqlite")
        let store = try SQLiteStore(url: databaseURL)
        try await store.save(scan: ScanSummary(plugins: [PluginRecord(name: "Old", format: .vst, files: [])], crashLogCount: 0, scannedAt: .now))
        try await store.save(scan: ScanSummary(plugins: [PluginRecord(name: "New", format: .vst3, files: [])], crashLogCount: 0, scannedAt: .now))
        let loaded = try await store.loadPlugins()
        XCTAssertEqual(loaded.map(\.name), ["New"])
    }

    func testAUValidationResultPassesOnlyForSuccessfulNonTimeout() {
        XCTAssertTrue(AUValidationResult(exitCode: 0, output: "ok", timedOut: false).passed)
        XCTAssertFalse(AUValidationResult(exitCode: 1, output: "failed", timedOut: false).passed)
        XCTAssertFalse(AUValidationResult(exitCode: 0, output: "timeout", timedOut: true).passed)
    }

    func testAUValidatorCapturesSuccessfulAndFailedProcesses() async {
        let success = await AUValidator(executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: []).validateAll(timeout: 2)
        XCTAssertTrue(success.passed)
        XCTAssertEqual(success.exitCode, 0)

        let failure = await AUValidator(executableURL: URL(fileURLWithPath: "/usr/bin/false"), arguments: []).validateAll(timeout: 2)
        XCTAssertFalse(failure.passed)
        XCTAssertEqual(failure.exitCode, 1)
    }

    func testAUValidatorReportsLaunchFailure() async {
        let result = await AUValidator(executableURL: temporaryDirectory.appendingPathComponent("missing-auval"), arguments: []).validateAll(timeout: 2)
        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, -1)
    }

    func testAUValidatorTerminatesTimedOutProcess() async {
        let result = await AUValidator(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"]).validateAll(timeout: 0.01)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.passed)
    }
}
