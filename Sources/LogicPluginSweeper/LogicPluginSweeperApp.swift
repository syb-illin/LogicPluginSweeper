import SwiftUI
import AppKit
import Charts
import CoreText
import Observation
import UniformTypeIdentifiers
import LogicPluginSweeperCore

private enum ThemeChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }
    var label: String {
        switch self { case .system: L10n.text("theme.system"); case .light: L10n.text("theme.light"); case .dark: L10n.text("theme.dark") }
    }
    var icon: String {
        switch self { case .system: "circle.lefthalf.filled"; case .light: "sun.max.fill"; case .dark: "moon.fill" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

private enum PluginSortOption: String, CaseIterable, Identifiable {
    case name
    case manufacturer
    case version
    case format
    case size
    case health
    case license
    case usage
    case reference
    case location

    var id: Self { self }
    var label: String {
        switch self {
        case .name: L10n.text("app.sort.name")
        case .manufacturer: L10n.text("app.sort.manufacturer")
        case .version: L10n.text("app.sort.version")
        case .format: L10n.text("app.sort.format")
        case .size: L10n.text("app.sort.size")
        case .health: L10n.text("app.sort.health")
        case .license: L10n.text("app.sort.license")
        case .usage: L10n.text("app.sort.usage")
        case .reference: L10n.text("app.sort.reference")
        case .location: L10n.text("app.sort.location")
        }
    }
}

private enum PluginReferenceFilter: String, CaseIterable, Identifiable {
    case all
    case referenced
    case notReferenced

    var id: Self { self }
    var label: String {
        switch self {
        case .all: L10n.text("app.filter.reference.all")
        case .referenced: L10n.text("app.filter.reference.referenced")
        case .notReferenced: L10n.text("app.filter.reference.notReferenced")
        }
    }
}

private func readableSize(_ bytes: Int64) -> String {
    bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : L10n.text("app.plugin.sizeUnavailable")
}

fileprivate struct RemovalProgress: Sendable {
    let pluginName: String
    let phase: String
    let fraction: Double
}

@main
struct LogicPluginSweeperApp: App {
    @State private var model = AppModel()
    @AppStorage("logicPluginSweeper.appearance") private var appearance = ThemeChoice.system.rawValue
    @AppStorage("logicPluginSweeper.updateChannel") private var updateChannel = UpdateChannel.stable.rawValue
    @AppStorage("logicPluginSweeper.checkUpdatesOnLaunch") private var checkUpdatesOnLaunch = true
    @AppStorage("logicPluginSweeper.telemetryEnabled") private var telemetryEnabled = true

    var body: some Scene {
        WindowGroup(L10n.text("app.title")) {
            ContentView(model: model, appearance: $appearance)
                .preferredColorScheme(ThemeChoice(rawValue: appearance)?.colorScheme)
        }
            .windowResizability(.contentSize)
            .commands { CommandGroup(replacing: .newItem) {} }
        Settings {
            SettingsView(model: model, appearance: $appearance, updateChannel: $updateChannel, checkUpdatesOnLaunch: $checkUpdatesOnLaunch, telemetryEnabled: $telemetryEnabled) {
                model.checkForUpdates(channel: UpdateChannel(rawValue: updateChannel) ?? .stable)
            }
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var plugins: [PluginRecord] = []
    var isScanning = false
    var validatingPluginIDs: Set<UUID> = []
    var isRemovingPlugin = false
    fileprivate var removalProgress: RemovalProgress?
    var lastScan: Date?
    var message = L10n.text("app.ready")
    var messageIsError = false
    var messageActionURL: URL?
    var usageSummary: LogicProjectUsageSummary?
    var isAnalyzingProjects = false
    var isDiscoveringProjects = false
    var isClearingProjectCache = false
    var selectedProjectSourceLabel: String?
    var discoveredProjects: [URL] = []
    var processedProjects: [URL: LogicProjectAnalysis] = [:]
    var activeProject: URL?
    var removalHistory: [RemovalRecord] = []
    var updateOffer: UpdateOffer?
    var isCheckingForUpdates = false
    var updateMessage: String?

    private let scanner = PluginScanner()
    private let quarantine = QuarantineService()
    private let backupService = PluginBackupService()
    private let notifications = SystemNotificationService()
    private let releaseService = ReleaseService()
    private var store: SQLiteStore?
    private var scanTask: Task<Void, Never>?
    private var projectDiscoveryTask: Task<Void, Never>?
    private var projectAnalysisTask: Task<Void, Never>?
    private var projectAnalysisGeneration = UUID()
    private var updateTask: Task<Void, Never>?

    init() {
        let bundledVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        Task { await TelemetryClient.shared.capture("app_opened", properties: ["app_version": TelemetryValue.string(bundledVersion)]) }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LogicPluginSweeper/history.sqlite")
        store = try? SQLiteStore(url: url)
        Task { [weak self] in
            guard let self else { return }
            await self.notifications.prepare()
            self.lastScan = try? await self.store?.loadLastScan()
            if let storedPlugins = try? await self.store?.loadPlugins() {
                let refreshedPlugins = storedPlugins.map { plugin in
                    guard plugin.manufacturer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                          let manufacturer = self.scanner.manufacturer(for: plugin),
                          !manufacturer.isEmpty else { return plugin }
                    return plugin.withManufacturer(manufacturer)
                }
                self.plugins = refreshedPlugins.filter { plugin in
                    guard let bundleURL = plugin.bundleURL else { return false }
                    return FileManager.default.fileExists(atPath: bundleURL.path)
                }
                if refreshedPlugins != storedPlugins {
                    let snapshot = ScanSummary(plugins: refreshedPlugins, crashLogCount: 0, scannedAt: self.lastScan ?? .now)
                    Task { try? await self.store?.save(scan: snapshot) }
                }
            }
            if let storedRemovals = try? await self.store?.loadRemovals() {
                self.removalHistory = storedRemovals
            }
            let channel = UpdateChannel(rawValue: UserDefaults.standard.string(forKey: "logicPluginSweeper.updateChannel") ?? "stable") ?? .stable
            let shouldCheck = UserDefaults.standard.object(forKey: "logicPluginSweeper.checkUpdatesOnLaunch") as? Bool ?? true
            if shouldCheck { self.checkForUpdates(channel: channel) }
        }
    }

    func checkForUpdates(channel: UpdateChannel? = nil) {
        updateTask?.cancel()
        isCheckingForUpdates = true
        updateMessage = nil
        let service = releaseService
        guard let bundledVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let currentVersion = SemanticVersion(tag: bundledVersion) else {
            isCheckingForUpdates = false
            updateMessage = L10n.text("app.updates.unavailable")
            return
        }
        let selectedChannel = channel ?? UpdateChannel(rawValue: UserDefaults.standard.string(forKey: "logicPluginSweeper.updateChannel") ?? "stable") ?? .stable
        updateTask = Task { [weak self] in
            do {
                let offer = try await service.updateOffer(currentVersion: currentVersion, channel: selectedChannel)
                guard !Task.isCancelled else { return }
                self?.updateOffer = offer
                self?.isCheckingForUpdates = false
                self?.updateMessage = offer == nil ? L10n.text("app.updates.current") : nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.isCheckingForUpdates = false
                self?.updateMessage = L10n.text("app.updates.unavailable")
            }
        }
    }

    func openUpdateDownload() {
        guard let downloadURL = updateOffer?.downloadURL else { return }
        NSWorkspace.shared.open(downloadURL)
    }

    func scan() {
        scanTask?.cancel()
        isScanning = true; message = L10n.text("app.scan.inProgress"); messageIsError = false; messageActionURL = nil
        scanTask = Task.detached { [scanner] in
            let result = scanner.scan(isCancelled: { Task.isCancelled })
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.plugins = result.plugins; self.lastScan = result.scannedAt; self.isScanning = false
                self.message = L10n.format("app.scan.completed", result.plugins.count, ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file)); self.messageIsError = false; self.messageActionURL = nil
                Task { await TelemetryClient.shared.capture("scan_completed", properties: ["plugin_count": TelemetryValue.integer(result.plugins.count), "size_bucket": TelemetryValue.string(TelemetrySizeBucket.label(for: result.totalBytes))]) }
                Task { [weak self] in try? await self?.store?.save(scan: result) }
                Task { [weak self] in
                    await self?.notifications.scanCompleted(pluginCount: result.plugins.count, footprint: ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file))
                }
            }
        }
    }

    func validateAU(_ plugin: PluginRecord) {
        guard plugin.format == .audioUnit, validatingPluginIDs.insert(plugin.id).inserted else { return }
        Task { [weak self] in
            let result = await AUValidator.validate(plugin: plugin)
            guard let self else { return }
            self.validatingPluginIDs.remove(plugin.id)
            guard let index = self.plugins.firstIndex(where: { $0.id == plugin.id }) else { return }
            let health: PluginHealth
            if let result {
                health = result.passed ? .healthy : .failed
            } else {
                health = .notChecked
            }
            self.plugins[index] = self.plugins[index].withHealth(health, message: result?.output)
            self.persistPluginInventory()
        }
    }

    func quarantine(_ plugin: PluginRecord) {
        do {
            let record = try quarantine.quarantine(plugin)
            removalHistory.append(record)
            persistRemoval(record)
            plugins.removeAll { $0.id == plugin.id }
            persistPluginInventory()
            message = L10n.format("app.quarantine.success", plugin.name)
            messageIsError = false
            messageActionURL = nil
            Task { await TelemetryClient.shared.capture("quarantine_completed", properties: ["format": TelemetryValue.string(plugin.format.rawValue), "size_bucket": TelemetryValue.string(TelemetrySizeBucket.label(for: plugin.totalBytes))]) }
            Task { [weak self] in await self?.notifications.quarantineCompleted(pluginName: plugin.name) }
        } catch {
            message = L10n.format("app.quarantine.failure", error.localizedDescription)
            messageIsError = true
            messageActionURL = nil
            Task { await TelemetryClient.shared.capture("quarantine_failed") }
            Task { [weak self] in await self?.notifications.operationFailed(L10n.format("app.quarantine.failure", error.localizedDescription)) }
        }
    }

    func removeWithoutBackup(_ plugin: PluginRecord) {
        removeWithoutBackup([plugin])
    }

    func removeWithoutBackup(_ selectedPlugins: [PluginRecord]) {
        guard !selectedPlugins.isEmpty else { return }
        isRemovingPlugin = true
        removalProgress = RemovalProgress(pluginName: selectedPlugins[0].name, phase: L10n.text("app.remove.phase.preparing"), fraction: 0.05)
        let quarantine = self.quarantine
        Task.detached(priority: .userInitiated) { [weak self] in
            let total = Double(selectedPlugins.count)
            var completed = 0
            var failureMessage: String?
            for plugin in selectedPlugins {
                do {
                    let base = Double(completed) / total
                    await MainActor.run { [weak self] in
                        self?.removalProgress = RemovalProgress(pluginName: plugin.name, phase: L10n.text("app.remove.phase.scanning"), fraction: base + 0.35 / total)
                    }
                    let footprint = PluginFootprintScanner().scan(plugin: plugin)
                    await MainActor.run { [weak self] in
                        self?.removalProgress = RemovalProgress(pluginName: plugin.name, phase: L10n.text("app.remove.phase.quarantine"), fraction: base + 0.8 / total)
                    }
                    let record = try quarantine.quarantine(plugin, locations: footprint.locations)
                    completed += 1
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.removalHistory.append(record)
                        self.persistRemoval(record)
                        self.plugins.removeAll { $0.id == plugin.id }
                        self.persistPluginInventory()
                        Task { [weak self] in await self?.notifications.quarantineCompleted(pluginName: plugin.name) }
                    }
                } catch {
                    failureMessage = error.localizedDescription
                    await MainActor.run { [weak self] in
                        self?.message = L10n.format("app.quarantine.failure", error.localizedDescription); self?.messageIsError = true; self?.messageActionURL = nil
                    }
                    break
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRemovingPlugin = false
                self.removalProgress = nil
                if let failureMessage {
                    self.message = L10n.format("app.remove.batch.failure", completed, selectedPlugins.count, failureMessage)
                    self.messageIsError = true
                    self.messageActionURL = nil
                } else {
                    self.message = L10n.format("app.remove.batch.completed", completed)
                    self.messageIsError = false
                    self.messageActionURL = nil
                }
            }
        }
    }

    func removeWithBackup(_ plugin: PluginRecord) {
        let panel = NSOpenPanel()
        panel.title = L10n.text("app.backup.choose.title")
        panel.message = L10n.text("app.backup.choose.message")
        panel.prompt = L10n.text("app.backup.choose.button")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isRemovingPlugin = true
        removalProgress = RemovalProgress(pluginName: plugin.name, phase: L10n.text("app.remove.phase.preparing"), fraction: 0.05)
        message = L10n.format("app.backup.inProgress", plugin.name); messageIsError = false; messageActionURL = nil
        let backupService = self.backupService
        let quarantine = self.quarantine
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                await MainActor.run { [weak self] in
                    self?.removalProgress = RemovalProgress(pluginName: plugin.name, phase: L10n.text("app.remove.phase.scanning"), fraction: 0.2)
                }
                let footprint = PluginFootprintScanner().scan(plugin: plugin)
                await MainActor.run { [weak self] in
                    self?.removalProgress = RemovalProgress(pluginName: plugin.name, phase: L10n.text("app.remove.phase.backup"), fraction: 0.55)
                }
                let archiveURL = try backupService.createArchive(for: plugin, footprint: footprint, in: destination)
                await MainActor.run { [weak self] in
                    self?.removalProgress = RemovalProgress(pluginName: plugin.name, phase: L10n.text("app.remove.phase.quarantine"), fraction: 0.85)
                }
                let record = try quarantine.quarantine(plugin, locations: footprint.locations)
                await MainActor.run {
                    guard let self else { return }
                    self.isRemovingPlugin = false
                    self.removalProgress = nil
                    self.removalHistory.append(record)
                    self.persistRemoval(record)
                    self.plugins.removeAll { $0.id == plugin.id }
                    self.persistPluginInventory()
                    self.message = L10n.format("app.backup.completed", archiveURL.lastPathComponent)
                    self.messageIsError = false
                    self.messageActionURL = archiveURL
                    Task { [weak self] in await self?.notifications.quarantineCompleted(pluginName: plugin.name) }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isRemovingPlugin = false
                    self?.removalProgress = nil
                    self?.message = L10n.format("app.backup.failure", error.localizedDescription)
                    self?.messageIsError = true
                    self?.messageActionURL = nil
                }
            }
        }
    }

    func quarantineSelected(_ ids: Set<UUID>) {
        for plugin in plugins where ids.contains(plugin.id) { quarantine(plugin) }
    }

    private func persistPluginInventory() {
        guard let store else { return }
        let snapshot = ScanSummary(plugins: plugins, crashLogCount: 0, scannedAt: lastScan ?? .now)
        Task { try? await store.save(scan: snapshot) }
    }

    private func persistRemoval(_ record: RemovalRecord) {
        Task { try? await store?.saveRemoval(record) }
    }

    func undoLastRemoval() {
        guard let record = removalHistory.last else { return }
        restore(record)
    }

    func restore(_ record: RemovalRecord) {
        do {
            try quarantine.restore(record)
            removalHistory.removeAll { $0.id == record.id }
            Task { try? await store?.deleteRemoval(id: record.id) }
            message = L10n.format("app.restore.success", record.pluginName)
            messageIsError = false
            messageActionURL = nil
            scan()
        } catch {
            message = L10n.format("app.restore.failure", error.localizedDescription)
            messageIsError = true
            messageActionURL = nil
        }
    }

    func exportCSV() {
        export { ReportExporter().csv(scan: ScanSummary(plugins: plugins, crashLogCount: 0, scannedAt: lastScan ?? .now)) }
    }

    func exportJSON() {
        guard let data = try? ReportExporter().json(scan: ScanSummary(plugins: plugins, crashLogCount: 0, scannedAt: lastScan ?? .now), usage: usageSummary) else { return }
        save(data: data, suggestedName: "LogicPluginSweeper-report.json")
    }

    func exportPDF() {
        let scan = ScanSummary(plugins: plugins, crashLogCount: 0, scannedAt: lastScan ?? .now)
        guard let data = ReportPDFExporter().make(scan: scan, usage: usageSummary) else { return }
        save(data: data, suggestedName: "LogicPluginSweeper-report.pdf")
    }

    private func export(_ data: () -> Data) {
        save(data: data(), suggestedName: "LogicPluginSweeper-report.csv")
    }

    private func save(data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    func analyzeLogicProjects() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("app.projects.open.title")
        panel.message = L10n.text("app.projects.open.message")
        panel.prompt = L10n.text("app.projects.open.button")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, UTType(filenameExtension: "logicx") ?? .package]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        analyzeLogicProjects(urls: panel.urls)
    }

    func analyzeLogicProjects(urls: [URL]) {
        guard !isClearingProjectCache else { return }
        projectDiscoveryTask?.cancel()
        projectAnalysisTask?.cancel()
        projectAnalysisGeneration = UUID()
        isDiscoveringProjects = true
        isAnalyzingProjects = false
        discoveredProjects = []
        processedProjects = [:]
        activeProject = nil
        usageSummary = nil
        selectedProjectSourceLabel = urls.count == 1 ? urls[0].path : L10n.format("app.projects.selected.count", urls.count)
        message = L10n.text("app.projects.discovering"); messageIsError = false; messageActionURL = nil
        let installedPlugins = self.plugins
        let generation = projectAnalysisGeneration
        projectDiscoveryTask = Task.detached(priority: .userInitiated) { [weak self] in
            let projects = urls.flatMap { url in
                if Task.isCancelled { return [URL]() }
                return url.pathExtension.lowercased() == "logicx" ? [url] : LogicProjectLocator().find(in: url)
            }
            await MainActor.run {
                guard !Task.isCancelled, let self, self.projectAnalysisGeneration == generation else { return }
                self.discoveredProjects = projects
                self.isDiscoveringProjects = false
                guard !projects.isEmpty else {
                    self.message = L10n.format("app.projects.none.in", self.selectedProjectSourceLabel ?? L10n.text("app.projects.selectedItems")); self.messageIsError = true; self.messageActionURL = nil
                    return
                }
                self.startProjectAnalysis(projects: projects, installedPlugins: installedPlugins)
            }
        }
    }

    private func startProjectAnalysis(projects: [URL], installedPlugins: [PluginRecord]) {
        isAnalyzingProjects = true
        let generation = projectAnalysisGeneration
        message = L10n.format("app.projects.inProgress.count", projects.count); messageIsError = false; messageActionURL = nil
        projectAnalysisTask = Task.detached(priority: .userInitiated) { [weak self] in
            let summary = LogicProjectAnalyzer(cache: LogicProjectCache(directory: LogicProjectCache.defaultDirectory)).analyze(projects: projects, plugins: installedPlugins, onProjectStarted: { project in
                Task { @MainActor [weak self] in
                    guard let self, self.isAnalyzingProjects, self.projectAnalysisGeneration == generation else { return }
                    self.activeProject = project
                }
            }) { _, analysis in
                Task { @MainActor [weak self] in
                    guard let self, self.isAnalyzingProjects, self.projectAnalysisGeneration == generation else { return }
                    self.processedProjects[analysis.projectURL] = analysis
                    if self.activeProject == analysis.projectURL { self.activeProject = nil }
                }
            }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled, self.projectAnalysisGeneration == generation else { return }
                self.usageSummary = summary
                self.processedProjects = Dictionary(uniqueKeysWithValues: summary.projectAnalyses.map { ($0.projectURL, $0) })
                self.isAnalyzingProjects = false
                self.activeProject = nil
                self.message = L10n.format("app.projects.completed", summary.analyzedProjectCount, summary.pluginUsage.count); self.messageIsError = false; self.messageActionURL = nil
                Task { await TelemetryClient.shared.capture("logic_project_analysis_completed", properties: ["project_count": TelemetryValue.integer(summary.analyzedProjectCount), "reference_count": TelemetryValue.integer(summary.pluginUsage.count), "unreadable_count": TelemetryValue.integer(summary.unreadableProjectCount)]) }
                Task { [weak self] in
                    await self?.notifications.projectAnalysisCompleted(projectCount: summary.analyzedProjectCount, usedPluginCount: summary.pluginUsage.count)
                }
            }
        }
    }

    func clearLogicProjectCache() async throws {
        guard !isClearingProjectCache else { return }
        isClearingProjectCache = true
        defer { isClearingProjectCache = false }
        projectDiscoveryTask?.cancel()
        projectAnalysisTask?.cancel()
        projectAnalysisGeneration = UUID()
        isDiscoveringProjects = false
        isAnalyzingProjects = false
        activeProject = nil
        await projectDiscoveryTask?.value
        await projectAnalysisTask?.value
        let cache = LogicProjectCache(directory: LogicProjectCache.defaultDirectory)
        try await Task.detached(priority: .utility) { try cache.clear() }.value
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @Binding var appearance: String
    @State private var selectedPluginIDs: Set<UUID> = []
    @State private var showingAbout = false
    @State private var showingStats = false
    @State private var searchText = ""
    @State private var selectedFormat: PluginFormat?
    @State private var selectedHealth: PluginHealth?
    @State private var selectedLicense: LicenseStatus?
    @State private var referenceFilter = PluginReferenceFilter.all
    @State private var detailSelection: DetailSelection?
    @State private var sortOption = PluginSortOption.name
    @State private var selectedPage = LibraryPage.all

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedPage) {
                Section(L10n.text("app.library")) {
                    Label(L10n.text("app.plugins.all"), systemImage: "pianokeys").tag(LibraryPage.all)
                    Label(L10n.text("app.plugins.review"), systemImage: "exclamationmark.triangle").tag(LibraryPage.review)
                    Label(L10n.text("app.history"), systemImage: "clock.arrow.circlepath").tag(LibraryPage.history)
                }
            }
            .navigationTitle(L10n.text("app.navigation.title"))
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button(action: model.scan) {
                        Label(L10n.text(model.isScanning ? "app.scan.inProgress.button" : "app.scan.button"), systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                        .buttonStyle(.borderedProminent)
                        .help(L10n.text("app.scan.help"))
                        .disabled(model.isScanning || model.isRemovingPlugin)
                    if model.isScanning {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.text("app.scan.inProgress"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let lastScan = model.lastScan {
                        Label(L10n.format("app.scan.last", lastScan.formatted(date: .abbreviated, time: .shortened)), systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(lastScan.formatted(date: .complete, time: .complete))
                    } else {
                        Text(L10n.text("app.scan.never"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button(action: model.analyzeLogicProjects) { Label(L10n.text("app.projects.button"), systemImage: "folder.badge.gearshape").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .disabled(model.isAnalyzingProjects || model.isClearingProjectCache)
                }
                .padding()
            }
        } detail: {
            if selectedPage == .history {
                RemovalHistoryView(records: model.removalHistory, onRestore: model.restore)
            } else {
            VStack(alignment: .leading, spacing: 20) {
                LibraryDashboardHeader(model: model)
                if let removalProgress = model.removalProgress {
                    RemovalProgressView(progress: removalProgress)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                    MetricCard(title: L10n.text("app.metrics.plugins"), value: "\(model.plugins.count)", icon: "pianokeys")
                    MetricCard(title: L10n.text("app.metrics.disk"), value: readableSize(model.plugins.reduce(0) { $0 + $1.totalBytes }), icon: "internaldrive")
                    MetricCard(title: L10n.text("app.metrics.logicUsage"), value: logicUsageValue, icon: "waveform")
                        .help(L10n.text("app.metrics.logicUsage.help"))
                }
                if let sourceLabel = model.selectedProjectSourceLabel {
                    ProjectAnalysisCard(sourceLabel: sourceLabel, projects: model.discoveredProjects, processedProjects: model.processedProjects, activeProject: model.activeProject, summary: model.usageSummary, plugins: model.plugins, isDiscovering: model.isDiscoveringProjects, isAnalyzing: model.isAnalyzingProjects, message: model.message, filter: searchText) { project in
                        detailSelection = .project(project)
                    }
                }
                let candidates = FormatRedundancyAnalyzer().candidates(in: model.plugins)
                let visiblePlugins = filteredPlugins()
                if model.plugins.isEmpty && !model.isScanning && model.selectedProjectSourceLabel == nil {
                    ContentUnavailableView {
                        Label(L10n.text("app.empty.title"), systemImage: "pianokeys")
                    } description: {
                        Text(L10n.text("app.empty.description"))
                    } actions: {
                        Button(action: model.scan) {
                            Label(L10n.text("app.scan.button"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        Button(action: model.analyzeLogicProjects) {
                            Label(L10n.text("app.projects.button"), systemImage: "folder.badge.gearshape")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PluginInventoryList(model: model, candidates: candidates, plugins: visiblePlugins, selectedPluginIDs: $selectedPluginIDs, detailSelection: $detailSelection, sortOption: $sortOption)
                }
            }
            .padding(28)
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        Task { @MainActor in model.analyzeLogicProjects(urls: [url]) }
                    }
                }
                return true
            }
            .toolbar {
                LibraryToolbar(model: model, appearance: $appearance, searchText: $searchText, selectedFormat: $selectedFormat, selectedHealth: $selectedHealth, selectedLicense: $selectedLicense, referenceFilter: $referenceFilter, sortOption: $sortOption, selectedPluginIDs: $selectedPluginIDs, showingStats: $showingStats, showingAbout: $showingAbout)
            }
            .sheet(isPresented: $showingAbout) { AboutView() }
            .sheet(isPresented: $showingStats) {
                UsageStatsView(summary: model.usageSummary)
            }
            .sheet(item: $detailSelection) { selection in
                switch selection {
                case .project(let project):
                    ProjectDetailView(projectURL: project, summary: model.usageSummary ?? LogicProjectUsageSummary(analyzedProjectCount: model.processedProjects.values.filter { $0.isReadable }.count, unreadableProjectCount: model.processedProjects.values.filter { !$0.isReadable }.count, pluginUsage: [], projectAnalyses: Array(model.processedProjects.values)), plugins: model.plugins) { pluginID in
                        detailSelection = .plugin(pluginID)
                    }
                case .plugin(let pluginID):
                    if let plugin = model.plugins.first(where: { $0.id == pluginID }) {
                        PluginDetailView(plugin: plugin, summary: model.usageSummary, reputation: nil, isValidating: model.validatingPluginIDs.contains(plugin.id), onValidate: { model.validateAU(plugin) }) {
                            model.removeWithBackup(plugin)
                            detailSelection = nil
                        } onRemoveWithoutBackup: {
                            model.removeWithoutBackup(plugin)
                            detailSelection = nil
                        }
                    }
                }
            }
            }
        }.frame(minWidth: 1080, minHeight: 680)
        .onChange(of: selectedPage) { _, page in
            referenceFilter = page == .review ? .notReferenced : .all
        }
    }

    private func usage(for plugin: PluginRecord) -> PluginUsageStats? {
        model.usageSummary?.pluginUsage.first { $0.id == plugin.id }
    }

    private var logicUsageValue: String {
        if model.isDiscoveringProjects || model.isAnalyzingProjects { return L10n.text("app.metrics.analyzing") }
        if let summary = model.usageSummary { return String(summary.pluginUsage.count) }
        return L10n.text("app.metrics.notAnalyzed")
    }

    private func filteredPlugins() -> [PluginRecord] {
        model.plugins.filter { plugin in
            let searchableFields: [String] = [plugin.name, plugin.format.rawValue]
                + [plugin.manufacturer, plugin.version, plugin.bundleURL?.path].compactMap { $0 }
            let matchesSearch = searchText.isEmpty || searchableFields.contains { $0.localizedCaseInsensitiveContains(searchText) }
            let matchesFormat = selectedFormat == nil || plugin.format == selectedFormat
            let matchesHealth = selectedHealth == nil || plugin.health == selectedHealth
            let matchesLicense = selectedLicense == nil || plugin.license == selectedLicense
            let isReferenced = (usage(for: plugin)?.projectCount ?? 0) > 0
            let matchesReference = referenceFilter == .all || (referenceFilter == .referenced && isReferenced) || (referenceFilter == .notReferenced && !isReferenced)
            return matchesSearch && matchesFormat && matchesHealth && matchesLicense && matchesReference
        }.sorted { left, right in
            switch sortOption {
            case .name: return left.name.localizedStandardCompare(right.name) == .orderedAscending
            case .manufacturer: return (left.manufacturer ?? "").localizedStandardCompare(right.manufacturer ?? "") == .orderedAscending
            case .version: return (left.version ?? "").localizedStandardCompare(right.version ?? "") == .orderedAscending
            case .format: return left.format.rawValue.localizedStandardCompare(right.format.rawValue) == .orderedAscending
            case .size: return left.totalBytes > right.totalBytes
            case .health: return left.health.rawValue.localizedStandardCompare(right.health.rawValue) == .orderedAscending
            case .license: return left.license.rawValue.localizedStandardCompare(right.license.rawValue) == .orderedAscending
            case .usage:
                let leftUsage = usage(for: left)?.projectCount ?? 0
                let rightUsage = usage(for: right)?.projectCount ?? 0
                return leftUsage == rightUsage ? left.name.localizedStandardCompare(right.name) == .orderedAscending : leftUsage > rightUsage
            case .reference:
                let leftReferenced = (usage(for: left)?.projectCount ?? 0) > 0
                let rightReferenced = (usage(for: right)?.projectCount ?? 0) > 0
                return leftReferenced == rightReferenced ? left.name.localizedStandardCompare(right.name) == .orderedAscending : leftReferenced
            case .location: return (left.bundleURL?.path ?? "").localizedStandardCompare(right.bundleURL?.path ?? "") == .orderedAscending
            }
        }
    }
}

private enum LibraryPage: Hashable {
    case all, review, history
}

private struct LibraryDashboardHeader: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("app.dashboard.title")).font(.largeTitle.bold())
                Text(L10n.text("app.dashboard.subtitle")).font(.subheadline).foregroundStyle(.secondary)
                if let lastScan = model.lastScan {
                    Text(L10n.format("app.scan.last", lastScan.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(lastScan.formatted(date: .complete, time: .complete))
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if model.isScanning || model.isRemovingPlugin {
                    ProgressView().controlSize(.small)
                } else if model.messageIsError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if let messageActionURL = model.messageActionURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([messageActionURL])
                    } label: {
                        HStack(spacing: 6) {
                            Text(model.message)
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("app.openInFinder"))
                } else {
                    Text(model.message)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(model.messageIsError ? .red : .secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.35), in: Capsule())
        }
    }
}

private struct RemovalProgressView: View {
    let progress: RemovalProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(L10n.text("app.remove.progress.title"), systemImage: "archivebox.fill")
                    .font(.headline)
                Spacer()
                Text("\(Int(progress.fraction * 100))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(progress.pluginName)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: progress.fraction)
            Text(progress.phase)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.blue.opacity(0.25), lineWidth: 1)
        }
    }
}

private struct PluginInventoryList: View {
    @Bindable var model: AppModel
    let candidates: [FormatRedundancyCandidate]
    let plugins: [PluginRecord]
    @Binding var selectedPluginIDs: Set<UUID>
    @Binding var detailSelection: DetailSelection?
    @Binding var sortOption: PluginSortOption

    var body: some View {
        List(selection: $selectedPluginIDs) {
            if !candidates.isEmpty {
                Section(L10n.text("app.section.spaceToReview")) {
                    ForEach(candidates) { candidate in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.tint)
                                VStack(alignment: .leading) {
                                    Text(candidate.alternative.name).font(.headline).lineLimit(1)
                                    Text(L10n.format("app.redundancy.details", candidate.alternative.format.rawValue, candidate.alternative.version ?? L10n.text("format.versionUnknown")))
                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(ByteCountFormatter.string(fromByteCount: candidate.alternative.totalBytes, countStyle: .file)).monospacedDigit()
                                Button(L10n.text("app.plugin.remove.button"), role: .destructive) { model.removeWithBackup(candidate.alternative) }
                                    .buttonStyle(.borderless)
                            }
                            Text(L10n.text("app.redundancy.warning"))
                                .font(.caption).foregroundStyle(.orange)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section {
                ForEach(plugins) { plugin in
                    Button { detailSelection = .plugin(plugin.id) } label: {
                        PluginRow(plugin: plugin, usage: model.usageSummary?.pluginUsage.first { $0.id == plugin.id })
                    }
                    .buttonStyle(.plain)
                    .tag(plugin.id)
                    .contextMenu {
                        Button(L10n.text("app.plugin.remove.button"), role: .destructive) { model.removeWithBackup(plugin) }
                        if let url = plugin.officialURL { Link(L10n.text("app.officialSite"), destination: url) }
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(L10n.text("app.section.installed"))
                        Spacer()
                        Text(L10n.format("app.section.installed.count", plugins.count))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    PluginTableHeader(sortOption: $sortOption)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

private struct RemovalHistoryView: View {
    let records: [RemovalRecord]
    let onRestore: (RemovalRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("app.history")).font(.largeTitle.bold())
            if records.isEmpty {
                ContentUnavailableView(L10n.text("app.history.empty"), systemImage: "clock.arrow.circlepath")
            } else {
                List(records.reversed()) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.pluginName).font(.headline)
                            Text(record.removedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.text("app.history.finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([record.quarantineURL])
                        }
                        Button(L10n.text("app.history.restore")) { onRestore(record) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(28)
    }
}

private enum DetailSelection: Identifiable {
    case project(URL)
    case plugin(UUID)

    var id: String {
        switch self {
        case .project(let url): "project:\(url.path)"
        case .plugin(let id): "plugin:\(id.uuidString)"
        }
    }
}

private struct UsageStatsView: View {
    let summary: LogicProjectUsageSummary?

    private struct FormatTotal: Identifiable {
        let format: String
        let count: Int
        var id: String { format }
    }

    private var formatTotals: [FormatTotal] {
        guard let summary else { return [] }
        return Dictionary(grouping: summary.pluginUsage, by: { $0.format.rawValue })
            .map { FormatTotal(format: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    private var totalReferences: Int {
        summary?.pluginUsage.reduce(0) { $0 + $1.projectCount } ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("app.stats.title")).font(.title.bold())
            if let summary {
                Text(L10n.format("app.stats.summary", summary.analyzedProjectCount, summary.unreadableProjectCount))
                    .foregroundStyle(.secondary)
                if summary.pluginUsage.isEmpty {
                    ContentUnavailableView(L10n.text("app.stats.empty.title"), systemImage: "chart.bar.xaxis", description: Text(L10n.text("app.stats.empty.description")))
                } else {
                    HStack(spacing: 12) {
                        MetricCard(title: L10n.text("app.stats.analyzed"), value: "\(summary.analyzedProjectCount)", icon: "checkmark.circle.fill")
                        MetricCard(title: L10n.text("app.stats.usedPlugins"), value: "\(summary.pluginUsage.count)", icon: "pianokeys")
                        MetricCard(title: L10n.text("app.stats.references"), value: "\(totalReferences)", icon: "link")
                    }
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.text("app.stats.topPlugins")).font(.headline)
                            Chart(summary.pluginUsage.prefix(12)) { usage in
                                BarMark(x: .value(L10n.text("app.chart.projects"), usage.projectCount), y: .value(L10n.text("app.chart.plugin"), usage.pluginName))
                                    .foregroundStyle(by: .value(L10n.text("app.chart.format"), usage.format.rawValue))
                                    .annotation(position: .trailing, alignment: .center) {
                                        Text("\(usage.projectCount)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                            }
                            .chartLegend(position: .bottom, alignment: .leading)
                            .frame(minHeight: 330)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 16))

                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.text("app.stats.formats")).font(.headline)
                            Chart(formatTotals) { item in
                                SectorMark(angle: .value(L10n.text("app.chart.plugins"), item.count), innerRadius: .ratio(0.62), angularInset: 2)
                                    .foregroundStyle(by: .value(L10n.text("app.chart.format"), item.format))
                                    .annotation(position: .overlay) {
                                        Text("\(item.count)").font(.caption.weight(.semibold)).foregroundStyle(.white)
                                    }
                            }
                            .chartLegend(position: .bottom, alignment: .leading)
                            .frame(minHeight: 330)
                        }
                        .padding(18)
                        .frame(width: 250, alignment: .leading)
                        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 16))
                    }
                    Text(L10n.text("app.stats.description")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView(L10n.text("app.stats.none.title"), systemImage: "chart.bar.xaxis", description: Text(L10n.text("app.stats.none.description")))
            }
        }
        .padding(28)
        .frame(minWidth: 720, minHeight: 500)
    }
}

private enum ProjectAnalysisColumnWidth {
    static let plugins: CGFloat = 360
    static let manufacturers: CGFloat = 220
    static let status: CGFloat = 95
}

private struct ProjectAnalysisCard: View {
    let sourceLabel: String
    let projects: [URL]
    let processedProjects: [URL: LogicProjectAnalysis]
    let activeProject: URL?
    let summary: LogicProjectUsageSummary?
    let plugins: [PluginRecord]
    let isDiscovering: Bool
    let isAnalyzing: Bool
    let message: String
    let filter: String
    let onSelectProject: (URL) -> Void
    @State private var isShowingProjects = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("app.projects.card.title"))
                        .font(.headline)
                    Text(sourceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(sourceLabel)
                }
                Spacer()
                if isDiscovering || isAnalyzing {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(L10n.text(isDiscovering ? "app.projects.card.discovering" : "app.projects.card.analyzing"))
                            .font(.caption.weight(.medium))
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            if isAnalyzing, !projects.isEmpty {
                ProgressView(value: Double(processedProjects.count), total: Double(projects.count))
                    .tint(.blue)
                Text(L10n.format("app.projects.card.progress", processedProjects.count, projects.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                ProjectMetric(value: "\(projects.count)", label: L10n.text("app.projects.card.found"), icon: "doc.on.doc")
                ProjectMetric(value: "\(processedProjects.values.filter { $0.isReadable }.count)", label: L10n.text("app.projects.card.analyzed"), icon: "checkmark.circle")
                ProjectMetric(value: "\(max(0, projects.count - processedProjects.count))", label: L10n.text("app.projects.card.pending"), icon: "clock")
                ProjectMetric(value: "\(referencedPluginCount)", label: L10n.text("app.projects.card.references"), icon: "pianokeys")
                let unreadableCount = processedProjects.values.filter { !$0.isReadable }.count
                if unreadableCount > 0 {
                    ProjectMetric(value: "\(unreadableCount)", label: L10n.text("app.projects.card.unreadable"), icon: "exclamationmark.triangle")
                }
            }
            if !isDiscovering && projects.isEmpty {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !projects.isEmpty {
                DisclosureGroup(isExpanded: $isShowingProjects) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                Text(L10n.text("app.projects.card.column.project"))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(L10n.text("app.projects.card.column.plugins"))
                                    .frame(width: ProjectAnalysisColumnWidth.plugins, alignment: .leading)
                                Text(L10n.text("app.projects.card.column.manufacturers"))
                                    .frame(width: ProjectAnalysisColumnWidth.manufacturers, alignment: .leading)
                                Text(L10n.text("app.projects.card.column.status"))
                                    .frame(width: ProjectAnalysisColumnWidth.status, alignment: .trailing)
                            }
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            ForEach(filteredProjects, id: \.self) { project in
                                let status = projectStatus(project)
                                Button { onSelectProject(project) } label: {
                                    ProjectAnalysisRow(project: project, analysis: processedProjects[project], plugins: plugins, status: status)
                                }
                                .buttonStyle(.plain)
                                .disabled(status != .analyzed)
                                .opacity(status == .pending ? 0.5 : 1)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                } label: {
                    Text(L10n.format("app.projects.card.files", projects.count))
                        .font(.subheadline.weight(.medium))
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    private var filteredProjects: [URL] {
        projects
            .filter { filter.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(filter) || $0.path.localizedCaseInsensitiveContains(filter) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private var referencedPluginCount: Int {
        if let summary { return summary.pluginUsage.count }
        return Set(processedProjects.values.flatMap { $0.pluginUsages.map(\.pluginID) }).count
    }

    private func projectStatus(_ project: URL) -> ProjectStatus {
        if let analysis = processedProjects[project] { return analysis.isReadable ? .analyzed : .unreadable }
        return activeProject == project ? .analyzing : .pending
    }
}

private struct ProjectAnalysisRow: View {
    let project: URL
    let analysis: LogicProjectAnalysis?
    let plugins: [PluginRecord]
    let status: ProjectStatus

    private struct PluginPill: Identifiable {
        let id: UUID
        let name: String
        let manufacturer: String?
        let format: PluginFormat
        let version: String?
        let bytes: Int64
        let trackNames: [String]

        var detail: String {
            var lines = [name]
            if let manufacturer, !manufacturer.isEmpty { lines.append("Fabricant : \(manufacturer)") }
            lines.append("Format : \(format.rawValue)")
            if let version, !version.isEmpty { lines.append("Version : \(version)") }
            lines.append("Taille : \(readableSize(bytes))")
            if !trackNames.isEmpty { lines.append("Pistes : \(trackNames.joined(separator: ", "))") }
            return lines.joined(separator: "\n")
        }
    }

    private struct ManufacturerPill: Identifiable {
        let id: String
        let name: String
        let pluginNames: [String]

        var detail: String {
            let plugins = pluginNames.joined(separator: ", ")
            return plugins.isEmpty ? name : "\(name)\nPlugins : \(plugins)"
        }
    }

    private var pluginRecords: [UUID: PluginRecord] { Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, $0) }) }

    private var pluginPills: [PluginPill] {
        let grouped = Dictionary(grouping: analysis?.pluginUsages ?? [], by: \.pluginID)
        return grouped.compactMap { pluginID, usages in
            guard let usage = usages.first else { return nil }
            let record = pluginRecords[pluginID]
            let tracks = Array(Set(usages.compactMap(\.trackName))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return PluginPill(id: pluginID, name: usage.pluginName, manufacturer: usage.manufacturer,
                              format: usage.format, version: record?.version, bytes: record?.totalBytes ?? 0, trackNames: tracks)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var pluginNames: [String] {
        pluginPills.map(\.name)
    }

    private var manufacturerPills: [ManufacturerPill] {
        let entries = pluginPills.compactMap { pill -> (String, String)? in
            guard let manufacturer = pill.manufacturer?.trimmingCharacters(in: .whitespacesAndNewlines), !manufacturer.isEmpty else { return nil }
            return (manufacturer, pill.name)
        }
        return entries.reduce(into: [String: [String]]()) { result, entry in
            result[entry.0, default: []].append(entry.1)
        }.map { manufacturer, names in
            ManufacturerPill(id: manufacturer, name: manufacturer, pluginNames: names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: status.icon)
                    .foregroundStyle(status.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.lastPathComponent)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(project.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                if status == .analyzed && !pluginNames.isEmpty {
                    ForEach(pluginPills.prefix(3)) { pill in
                        Text(pill.name)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.purple.opacity(0.13), in: Capsule())
                            .help(pill.detail)
                    }
                    if pluginNames.count > 3 {
                        Text("+\(pluginNames.count - 3)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .frame(width: ProjectAnalysisColumnWidth.plugins, alignment: .leading)
            .help(pluginNames.joined(separator: ", "))

            HStack(spacing: 4) {
                if status == .analyzed && !manufacturerPills.isEmpty {
                    ForEach(manufacturerPills.prefix(2)) { pill in
                        Text(pill.name)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.blue.opacity(0.12), in: Capsule())
                            .help(pill.detail)
                    }
                    if manufacturerPills.count > 2 {
                        Text("+\(manufacturerPills.count - 2)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .frame(width: ProjectAnalysisColumnWidth.manufacturers, alignment: .leading)
            .help(manufacturerPills.map(\.detail).joined(separator: "\n\n"))
            Text(L10n.text(status == .analyzing ? "app.projects.card.analyzingRow" : status.key))
                .font(.caption2.weight(.medium))
                .foregroundStyle(status.color)
                .frame(width: ProjectAnalysisColumnWidth.status, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }
}

private enum ProjectStatus: Equatable {
    case pending, analyzing, analyzed, unreadable

    var key: String {
        switch self {
        case .pending: "app.projects.card.pending"
        case .analyzing: "app.projects.card.analyzing"
        case .analyzed: "app.projects.card.analyzed"
        case .unreadable: "app.projects.card.unreadable"
        }
    }

    var icon: String {
        switch self {
        case .pending: "clock"
        case .analyzing: "arrow.triangle.2.circlepath"
        case .analyzed: "checkmark.circle.fill"
        case .unreadable: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pending: .secondary
        case .analyzing: .blue
        case .analyzed: .green
        case .unreadable: .orange
        }
    }
}

private struct ProjectMetric: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.headline.monospacedDigit())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            BrandLogoView()
                .frame(width: 320, height: 178)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            Text(L10n.text("app.title")).font(.title.bold())
            Text(L10n.text("app.about.subtitle")).foregroundStyle(.secondary)
            Divider()
            Text(L10n.format("app.about.version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"))
            Text(L10n.text("app.about.author")).font(.headline)
            Text(L10n.text("app.about.details"))
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(width: 360)
    }
}

private struct BrandLogoView: View {
    var body: some View {
        if let url = AppResources.url(forResource: "LogicPluginSweeper-logo", withExtension: "jpeg", subdirectory: "branding"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "pianokeys.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
        }
    }
}

private struct SettingsView: View {
    @Bindable var model: AppModel
    @Binding var appearance: String
    @Binding var updateChannel: String
    @Binding var checkUpdatesOnLaunch: Bool
    @Binding var telemetryEnabled: Bool
    let onUpdateChannelChanged: () -> Void
    @State private var cacheStatistics: LogicProjectCache.Statistics?
    @State private var cacheError: String?
    @State private var isClearingCache = false
    @State private var showingClearCacheConfirmation = false

    var body: some View {
        Form {
            Picker(L10n.text("app.appearance"), selection: $appearance) {
                ForEach(ThemeChoice.allCases) { theme in
                    Label(theme.label, systemImage: theme.icon).tag(theme.rawValue)
                }
            }
            Picker(L10n.text("settings.update.channel"), selection: $updateChannel) {
                ForEach(UpdateChannel.allCases, id: \.rawValue) { channel in
                    Text(L10n.text(channel == .stable ? "settings.update.stable" : "settings.update.nightly")).tag(channel.rawValue)
                }
            }
            .onChange(of: updateChannel) { _, _ in onUpdateChannelChanged() }
            Toggle(L10n.text("settings.update.launch"), isOn: $checkUpdatesOnLaunch)
            Text(L10n.text("settings.update.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(L10n.text("settings.telemetry.enabled"), isOn: $telemetryEnabled)
            Text(L10n.text("settings.telemetry.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Section(L10n.text("settings.cache.title")) {
                if let cacheStatistics {
                    Text(L10n.format("settings.cache.files", cacheStatistics.fileCount))
                    Text(cacheStatistics.latestModificationDate.map {
                        L10n.format("settings.cache.date", $0.formatted(date: .abbreviated, time: .shortened))
                    } ?? L10n.text("settings.cache.never"))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
                Button(L10n.text("settings.cache.clear"), role: .destructive) {
                    showingClearCacheConfirmation = true
                }
                .disabled(isClearingCache || model.isClearingProjectCache || model.isAnalyzingProjects || model.isDiscoveringProjects || cacheStatistics == nil || cacheStatistics?.fileCount == 0)
                if let cacheError {
                    Text(cacheError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear(perform: refreshCacheStatistics)
        .alert(L10n.text("settings.cache.confirm.title"), isPresented: $showingClearCacheConfirmation) {
            Button(L10n.text("settings.cache.clear"), role: .destructive) { clearCache() }
            Button(L10n.text("settings.cache.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("settings.cache.confirm.message"))
        }
    }

    private func refreshCacheStatistics() {
        let cache = LogicProjectCache(directory: LogicProjectCache.defaultDirectory)
        Task {
            do {
                cacheStatistics = try await Task.detached(priority: .utility) { try cache.statistics() }.value
                cacheError = nil
            } catch {
                cacheError = error.localizedDescription
                cacheStatistics = .init(fileCount: 0, latestModificationDate: nil)
            }
        }
    }

    private func clearCache() {
        isClearingCache = true
        Task {
            do {
                try await model.clearLogicProjectCache()
                cacheStatistics = nil
                refreshCacheStatistics()
            } catch {
                cacheError = error.localizedDescription
            }
            isClearingCache = false
        }
    }
}

private struct MetricCard: View { let title: String; let value: String; let icon: String; var body: some View { VStack(alignment: .leading, spacing: 8) { Image(systemName: icon).foregroundStyle(.tint); Text(value).font(.title.bold()).lineLimit(1).minimumScaleFactor(0.75); Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14)) } }
private enum PluginTableLayout {
    static let name: CGFloat = 145
    static let manufacturer: CGFloat = 105
    static let version: CGFloat = 70
    static let format: CGFloat = 52
    static let size: CGFloat = 68
    static let health: CGFloat = 85
    static let license: CGFloat = 85
    static let usage: CGFloat = 82
    static let location: CGFloat = 150
    static let spacing: CGFloat = 10
}

private struct PluginSortMenu: View {
    @Binding var sortOption: PluginSortOption

    var body: some View {
        Menu(L10n.text("app.sort")) {
            ForEach(PluginSortOption.allCases) { option in
                Button(option.label) { sortOption = option }
            }
        }
    }
}

private struct PluginFilterMenu: View {
    @Binding var selectedFormat: PluginFormat?
    @Binding var selectedHealth: PluginHealth?
    @Binding var selectedLicense: LicenseStatus?
    @Binding var referenceFilter: PluginReferenceFilter

    var body: some View {
        Menu(L10n.text("app.filter")) {
            Button(L10n.text("app.filter.reset")) {
                selectedFormat = nil
                selectedHealth = nil
                selectedLicense = nil
                referenceFilter = .all
            }
            Menu(L10n.text("app.filter.format")) {
                Button(L10n.text("app.filter.all")) { selectedFormat = nil }
                ForEach(PluginFormat.allCases, id: \.self) { format in
                    Button(format.rawValue) { selectedFormat = format }
                }
            }
            Menu(L10n.text("app.filter.reference")) {
                ForEach(PluginReferenceFilter.allCases) { option in
                    Button(option.label) { referenceFilter = option }
                }
            }
            Menu(L10n.text("app.filter.health")) {
                Button(L10n.text("app.filter.all")) { selectedHealth = nil }
                ForEach(PluginHealth.allCases, id: \.self) { health in
                    Button(L10n.text("format.health.\(health.rawValue)")) { selectedHealth = health }
                }
            }
            Menu(L10n.text("app.filter.license")) {
                Button(L10n.text("app.filter.all")) { selectedLicense = nil }
                ForEach([LicenseStatus.active, .expired, .unknown], id: \.self) { license in
                    Button(L10n.text("license.\(license.rawValue)")) { selectedLicense = license }
                }
            }
        }
    }
}

private struct AppearanceMenu: View {
    @Binding var appearance: String

    var body: some View {
        Menu {
            Picker(L10n.text("app.appearance"), selection: $appearance) {
                ForEach(ThemeChoice.allCases) { theme in
                    Label(theme.label, systemImage: theme.icon).tag(theme.rawValue)
                }
            }
        } label: {
            Image(systemName: "circle.lefthalf.filled")
        }
        .help(L10n.text("app.appearance"))
    }
}

private struct LibraryActionsMenu: View {
    @Bindable var model: AppModel
    @Binding var selectedFormat: PluginFormat?
    @Binding var selectedHealth: PluginHealth?
    @Binding var selectedLicense: LicenseStatus?
    @Binding var referenceFilter: PluginReferenceFilter
    @Binding var sortOption: PluginSortOption
    @Binding var selectedPluginIDs: Set<UUID>
    @Binding var showingStats: Bool
    @Binding var showingAbout: Bool

    var body: some View {
        Menu {
            Button(L10n.text("app.stats")) { showingStats = true }
            PluginFilterMenu(selectedFormat: $selectedFormat, selectedHealth: $selectedHealth, selectedLicense: $selectedLicense, referenceFilter: $referenceFilter)
            PluginSortMenu(sortOption: $sortOption)
            Menu(L10n.text("app.export")) {
                Button(L10n.text("app.export.csv")) { model.exportCSV() }
                Button(L10n.text("app.export.json")) { model.exportJSON() }
                Button(L10n.text("app.export.pdf")) { model.exportPDF() }
            }
            if !selectedPluginIDs.isEmpty {
                Button(L10n.text("app.selection.removeWithoutBackup"), role: .destructive) {
                    model.removeWithoutBackup(model.plugins.filter { selectedPluginIDs.contains($0.id) })
                    selectedPluginIDs.removeAll()
                }
            }
            Button(L10n.text("app.undo")) { model.undoLastRemoval() }
                .disabled(model.removalHistory.isEmpty)
            Divider()
            Button(L10n.text("app.about")) { showingAbout = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .help(L10n.text("app.actions"))
    }
}

private struct LibraryToolbar: ToolbarContent {
    @Bindable var model: AppModel
    @Binding var appearance: String
    @Binding var searchText: String
    @Binding var selectedFormat: PluginFormat?
    @Binding var selectedHealth: PluginHealth?
    @Binding var selectedLicense: LicenseStatus?
    @Binding var referenceFilter: PluginReferenceFilter
    @Binding var sortOption: PluginSortOption
    @Binding var selectedPluginIDs: Set<UUID>
    @Binding var showingStats: Bool
    @Binding var showingAbout: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            TextField(L10n.text("app.search"), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 170, idealWidth: 220, maxWidth: 260)
            AppearanceMenu(appearance: $appearance)
            Button(action: { model.checkForUpdates() }) { Image(systemName: "arrow.down.circle") }
                .help(L10n.text(model.isCheckingForUpdates ? "app.update.checking" : "app.update.check"))
                .disabled(model.isCheckingForUpdates)
            if let offer = model.updateOffer {
                Button(action: model.openUpdateDownload) { Image(systemName: "arrow.down.circle.fill") }
                    .help(L10n.format("app.update.download", offer.version.description))
                    .foregroundStyle(.green)
            }
            Button { showingStats = true } label: { Image(systemName: "chart.bar.xaxis") }
                .help(L10n.text("app.stats"))
            LibraryActionsMenu(model: model, selectedFormat: $selectedFormat, selectedHealth: $selectedHealth, selectedLicense: $selectedLicense, referenceFilter: $referenceFilter, sortOption: $sortOption, selectedPluginIDs: $selectedPluginIDs, showingStats: $showingStats, showingAbout: $showingAbout)
        }
    }
}

private struct PluginTableHeader: View {
    @Binding var sortOption: PluginSortOption

    var body: some View {
        HStack(spacing: PluginTableLayout.spacing) {
            tableLabel("app.column.name", option: .name, width: PluginTableLayout.name)
            tableLabel("app.column.manufacturer", option: .manufacturer, width: PluginTableLayout.manufacturer)
            tableLabel("app.column.version", option: .version, width: PluginTableLayout.version)
            tableLabel("app.column.format", option: .format, width: PluginTableLayout.format)
            tableLabel("app.column.size", option: .size, width: PluginTableLayout.size)
            tableLabel("app.column.health", option: .health, width: PluginTableLayout.health)
            tableLabel("app.column.license", option: .license, width: PluginTableLayout.license)
            tableLabel("app.column.reference", option: .reference, width: PluginTableLayout.usage)
            tableLabel("app.column.location", option: .location, width: PluginTableLayout.location)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tableLabel(_ key: String, option: PluginSortOption, width: CGFloat) -> some View {
        Button {
            sortOption = option
        } label: {
            HStack(spacing: 4) {
                Text(L10n.text(key)).lineLimit(1)
                if sortOption == option {
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help(L10n.format("app.sort.by", L10n.text(key)))
    }
}

private struct PluginRow: View {
    let plugin: PluginRecord
    let usage: PluginUsageStats?

    var body: some View {
        HStack(spacing: PluginTableLayout.spacing) {
            HStack(spacing: 8) {
                Image(systemName: "pianokeys").font(.title3).foregroundStyle(.tint)
                Text(plugin.name).font(.headline).lineLimit(1).truncationMode(.middle)
            }
            .frame(width: PluginTableLayout.name, alignment: .leading)

            tableValue(plugin.manufacturer ?? L10n.text("app.plugin.unknown"), width: PluginTableLayout.manufacturer)
            tableValue(plugin.version ?? L10n.text("format.versionUnknown"), width: PluginTableLayout.version)

            Text(plugin.format.rawValue)
                .font(.caption.weight(.semibold).monospaced())
                .foregroundStyle(.blue)
                .frame(width: PluginTableLayout.format, alignment: .leading)

            Text(readableSize(plugin.totalBytes))
                .font(.caption.monospacedDigit())
                .frame(width: PluginTableLayout.size, alignment: .leading)

            Text(L10n.text("format.health.\(plugin.health.rawValue)"))
                .font(.caption)
                .foregroundStyle(plugin.health == .healthy ? .green : .orange)
                .lineLimit(1)
                .frame(width: PluginTableLayout.health, alignment: .leading)

            Text(L10n.text("license.\(plugin.license.rawValue)"))
                .font(.caption)
                .foregroundStyle(plugin.license == .active ? .green : .secondary)
                .lineLimit(1)
                .frame(width: PluginTableLayout.license, alignment: .leading)

            Text(usage.map { L10n.format("app.plugin.projects", $0.projectCount) } ?? L10n.text("app.plugin.unreferenced"))
                .font(.caption)
                .foregroundStyle(usage == nil ? Color.secondary : Color.accentColor)
                .lineLimit(1)
                .frame(width: PluginTableLayout.usage, alignment: .leading)

            Text(plugin.bundleURL?.path ?? L10n.text("app.plugin.unknown"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: PluginTableLayout.location, alignment: .leading)
                .help(plugin.bundleURL?.path ?? "")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    private func tableValue(_ value: String, width: CGFloat) -> some View {
        Text(value)
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width, alignment: .leading)
    }
}

private struct ProjectDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let projectURL: URL
    let summary: LogicProjectUsageSummary?
    let plugins: [PluginRecord]
    let onSelectPlugin: (UUID) -> Void

    private var analysis: LogicProjectAnalysis? { summary?.projectAnalyses.first { $0.projectURL == projectURL } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(projectURL.deletingPathExtension().lastPathComponent).font(.title.bold()).lineLimit(1)
                Spacer()
                Button(L10n.text("app.close"), systemImage: "xmark") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(L10n.text("app.close"))
            }
            Text(projectURL.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            Divider()
            if let analysis, !analysis.pluginUsages.isEmpty {
                Text(L10n.format("app.project.plugins", analysis.distinctPluginCount)).font(.headline)
                List(analysis.pluginUsages) { usage in
                    Button { onSelectPlugin(usage.pluginID) } label: {
                        HStack {
                            Image(systemName: "pianokeys").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(usage.pluginName).font(.headline)
                                Text(usage.trackName ?? L10n.text("app.project.referenceScope"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(usage.format.rawValue).font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }.buttonStyle(.plain)
                }
            } else {
                ContentUnavailableView(L10n.text("app.project.noPlugins"), systemImage: "pianokeys.slash", description: Text(L10n.text("app.project.noPlugins.description")))
            }
        }
        .padding(28)
        .frame(minWidth: 620, minHeight: 420)
        .onExitCommand { dismiss() }
    }
}

private struct PluginDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let plugin: PluginRecord
    let summary: LogicProjectUsageSummary?
    let reputation: PluginReputation?
    let isValidating: Bool
    let onValidate: () -> Void
    let onQuarantine: () -> Void
    let onRemoveWithoutBackup: () -> Void
    @State private var footprint: PluginFootprint?
    @State private var bundleContents: PluginBundleContents?
    @State private var isBundleContentsExpanded = true

    private var projects: [URL] { summary?.pluginUsage.first { $0.id == plugin.id }?.projectURLs ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(.white.opacity(0.18))
                    Image(systemName: "pianokeys").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(plugin.name).font(.title.bold()).foregroundStyle(.white).lineLimit(1)
                    Text([plugin.manufacturer, plugin.version].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.white.opacity(0.78))
                }
                Spacer()
                if plugin.format == .audioUnit {
                    Button {
                        onValidate()
                    } label: {
                        if isValidating {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(L10n.text("app.plugin.validate"))
                        }
                    }
                    .disabled(isValidating)
                }
                if let url = plugin.officialURL { Link(L10n.text("app.officialSite"), destination: url).buttonStyle(.borderedProminent) }
                Button(L10n.text("app.close"), systemImage: "xmark") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(L10n.text("app.close"))
            }
            .padding(22)
            .background(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {

                Text(L10n.text("app.plugin.overview")).font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145))], spacing: 10) {
                    DetailValue(title: L10n.text("app.plugin.format"), value: plugin.format.rawValue, icon: "waveform", tint: .blue)
                    DetailValue(title: L10n.text("app.plugin.health"), value: L10n.text("format.health.\(plugin.health.rawValue)"), icon: "heart.text.square", tint: plugin.health == .healthy ? .green : .orange)
                    DetailValue(title: L10n.text("app.plugin.license"), value: L10n.text("license.\(plugin.license.rawValue)"), icon: "checkmark.seal", tint: plugin.license == .active ? .green : .orange)
                    DetailValue(title: L10n.text("app.plugin.size"), value: displayedSize, icon: "internaldrive", tint: .indigo)
                }
                Text(L10n.text("app.plugin.overview.help")).font(.caption).foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.text("app.plugin.locations")).font(.headline)
                        if let footprint {
                            Text(L10n.text("app.plugin.primaryLocation")).font(.caption.weight(.semibold))
                            ForEach(footprint.locations.filter { $0.kind == .pluginBundle }) { location in
                                locationRow(location)
                            }
                            if let bundleContents {
                                DisclosureGroup(L10n.format("app.plugin.contents.title", bundleContents.files.count), isExpanded: $isBundleContentsExpanded) {
                                    if bundleContents.files.isEmpty {
                                        Text(L10n.text("app.plugin.contents.empty"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        ForEach(bundleContents.files, id: \.path) { file in
                                            HStack(alignment: .top, spacing: 8) {
                                                Image(systemName: "doc.text")
                                                    .foregroundStyle(.secondary)
                                                Text(relativePath(for: file.path))
                                                    .font(.caption2)
                                                    .textSelection(.enabled)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                Spacer()
                                                Text(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))
                                                    .font(.caption2.monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    if !bundleContents.isComplete {
                                        Text(L10n.text("app.plugin.contents.partial"))
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                .font(.caption.weight(.semibold))
                            }
                            let relatedLocations = footprint.locations.filter { $0.kind != .pluginBundle }
                            if !relatedLocations.isEmpty {
                                Text(L10n.text("app.plugin.relatedLocations")).font(.caption.weight(.semibold)).padding(.top, 5)
                                ForEach(relatedLocations) { location in
                                    locationRow(location)
                                }
                            } else if footprint.isComplete {
                                Text(L10n.text("app.plugin.related.none"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if footprint.locations.count == 1 && footprint.isComplete {
                                Text(L10n.text("app.plugin.locations.none"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if !footprint.evidence.isEmpty {
                                Text(L10n.text("app.plugin.evidence.title")).font(.caption.weight(.medium)).padding(.top, 4)
                                ForEach(footprint.evidence.prefix(6)) { evidence in
                                    Label(evidence.value, systemImage: "checkmark.seal").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        } else if plugin.bundleURL != nil {
                            HStack { ProgressView().controlSize(.small); Text(L10n.text("app.plugin.locations.loading")).font(.caption).foregroundStyle(.secondary) }
                        } else {
                            Text(L10n.text("app.plugin.locationUnavailable")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(16)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "gauge").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("app.plugin.performance")).font(.headline)
                        Text(L10n.text("app.plugin.performance.help")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.format("app.plugin.usedIn", projects.count), systemImage: "music.note.list").font(.headline)
                    if projects.isEmpty {
                        Text(L10n.text("app.plugin.noProjects")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(projects, id: \.self) { project in
                            Label(project.deletingPathExtension().lastPathComponent, systemImage: "doc.text")
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(16)
                .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("app.plugin.reputation.title")).font(.headline)
                    if let reputation {
                        HStack {
                            Text(String(format: "%.1f / %.1f", reputation.score, reputation.maximumScore)).font(.title3.bold())
                            Text(L10n.format("app.plugin.reputation.reviews", reputation.reviewCount)).foregroundStyle(.secondary)
                            Spacer()
                            Link(reputation.sourceName, destination: reputation.sourceURL)
                        }
                        Text(L10n.format("app.plugin.reputation.updated", reputation.capturedAt.formatted(date: .abbreviated, time: .omitted))).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(L10n.text("app.plugin.reputation.unavailable")).font(.caption).foregroundStyle(.secondary)
                        if let url = PluginReputationSearch.url(for: plugin) {
                            Button { NSWorkspace.shared.open(url) } label: { Label(L10n.text("app.plugin.reputation.search"), systemImage: "safari") }.buttonStyle(.bordered)
                        }
                    }
                }
                .padding(16)
                .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("app.plugin.remove.title")).font(.headline)
                    Text(L10n.text("app.plugin.remove.help")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(L10n.text("app.plugin.remove.button"), role: .destructive, action: onQuarantine)
                            .buttonStyle(.borderedProminent)
                        Button(L10n.text("app.plugin.remove.withoutBackup.button"), role: .destructive, action: onRemoveWithoutBackup)
                            .buttonStyle(.bordered)
                    }
                }
                .padding(16)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(28)
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .onExitCommand { dismiss() }
        .task(id: plugin.id) {
            let scanned = await Task.detached(priority: .utility) {
                PluginFootprintScanner().scan(plugin: plugin, isCancelled: { Task.isCancelled })
            }.value
            guard !Task.isCancelled else { return }
            footprint = scanned
            if let bundleURL = plugin.bundleURL {
                bundleContents = await Task.detached(priority: .utility) {
                    PluginBundleContentScanner().scan(bundleURL: bundleURL, isCancelled: { Task.isCancelled })
                }.value
            }
        }
    }

    private var displayedSize: String {
        let bytes = footprint?.totalBytes ?? plugin.totalBytes
        return bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : L10n.text("app.plugin.sizeUnavailable")
    }

    private func locationLabel(_ kind: PluginLocation.Kind) -> String {
        switch kind {
        case .pluginBundle: L10n.text("app.plugin.location.bundle")
        case .presets: L10n.text("app.plugin.location.presets")
        case .applicationSupport: L10n.text("app.plugin.location.support")
        case .preferences: L10n.text("app.plugin.location.preferences")
        case .cache: L10n.text("app.plugin.location.cache")
        case .other: L10n.text("app.plugin.location.other")
        }
    }

    private func locationRow(_ location: PluginLocation) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: location.kind == .pluginBundle ? "pianokeys" : "doc.text")
                .foregroundStyle(location.kind == .pluginBundle ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(locationLabel(location.kind)).font(.caption.weight(.medium))
                Text(location.path.path).font(.caption2).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                Text(L10n.format("app.plugin.location.fileCount", location.fileCount))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: location.byteCount, countStyle: .file)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func relativePath(for url: URL) -> String {
        guard let bundleURL = plugin.bundleURL else { return url.path }
        let prefix = bundleURL.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(prefix) ? String(url.standardizedFileURL.path.dropFirst(prefix.count)) : url.path
    }
}

private struct DetailValue: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
