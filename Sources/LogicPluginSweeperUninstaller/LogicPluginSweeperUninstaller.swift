import SwiftUI
import AppKit
import LogicPluginSweeperCore

private enum Copy {
    static let french = Locale.current.language.languageCode?.identifier == "fr"
    static func text(_ frenchText: String, _ englishText: String) -> String { french ? frenchText : englishText }
}

@main
struct LogicPluginSweeperUninstallerApp: App {
    var body: some Scene {
        WindowGroup(Copy.text("Désinstaller LogicPluginSweeper", "Uninstall LogicPluginSweeper")) {
            UninstallView()
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

private struct UninstallView: View {
    @State private var appURL: URL?
    @State private var inventory: UninstallService.Inventory?
    @State private var deleteAllData = false
    @State private var showingConfirmation = false
    @State private var isWorking = false
    @State private var status: String?
    @State private var errorMessage: String?
    private let service = UninstallService()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "app.badge.checkmark")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Copy.text("Désinstaller LogicPluginSweeper", "Uninstall LogicPluginSweeper"))
                        .font(.title2.bold())
                    Text(Copy.text("Aucun plugin audio installé ne sera supprimé.", "Installed audio plugins will not be removed."))
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox(Copy.text("Application", "Application")) {
                HStack {
                    Text(appURL?.path ?? Copy.text("Choisissez l’application installée", "Choose the installed application"))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                    Button(Copy.text("Choisir…", "Choose…"), action: chooseApp)
                }
                .padding(.vertical, 6)
            }

            GroupBox(Copy.text("Données locales", "Local data")) {
                VStack(alignment: .leading, spacing: 10) {
                    if let inventory {
                        Label(Copy.text("Cache : \(inventory.cacheFileCount) fichier(s), \(size(inventory.cacheBytes))", "Cache: \(inventory.cacheFileCount) file(s), \(size(inventory.cacheBytes))"), systemImage: "externaldrive")
                        Text(inventory.cacheLastModified.map { Copy.text("Dernière mise à jour : \($0.formatted(date: .abbreviated, time: .shortened))", "Last updated: \($0.formatted(date: .abbreviated, time: .shortened))") } ?? Copy.text("Aucun cache", "No cache"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(service.cacheDirectory.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        Label(Copy.text("Historique et sauvegardes : \(inventory.removalCount) dossier(s), \(size(inventory.preservedBytes))", "History and saved plugins: \(inventory.removalCount) folder(s), \(size(inventory.preservedBytes))"), systemImage: "archivebox")
                    } else {
                        ProgressView()
                    }
                    Divider()
                    Toggle(Copy.text("Supprimer aussi l’historique et les sauvegardes de plugins", "Also delete history and saved plugins"), isOn: $deleteAllData)
                    Text(deleteAllData
                         ? Copy.text("Irréversible : les plugins conservés pour restauration seront perdus. Exportez-les d’abord si nécessaire.", "Irreversible: saved plugins will be lost. Export them first if needed.")
                         : Copy.text("Par défaut, seul le cache recréable est supprimé. L’historique et les sauvegardes restent à leur place.", "By default, only the rebuildable cache is cleared. History and saved plugins stay in place."))
                        .font(.caption)
                        .foregroundColor(deleteAllData ? .orange : .secondary)
                    Button(Copy.text("Exporter les données dans un dossier…", "Export data to a folder…"), action: exportData)
                        .disabled(isWorking || inventory?.hasExportableData != true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }

            if let status { Label(status, systemImage: "checkmark.circle.fill").foregroundStyle(.green).fixedSize(horizontal: false, vertical: true) }
            if let errorMessage { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }

            HStack {
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(Copy.text("Désinstaller…", "Uninstall…")) { showingConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || appURL == nil)
            }
        }
        .padding(26)
        .frame(width: 590)
        .onAppear {
            let installed = URL(fileURLWithPath: "/Applications/LogicPluginSweeper.app", isDirectory: true)
            if isValidApp(installed) { appURL = installed }
            refreshInventory()
        }
        .alert(Copy.text("Confirmer la désinstallation ?", "Confirm uninstall?"), isPresented: $showingConfirmation) {
            Button(Copy.text("Désinstaller", "Uninstall"), role: .destructive, action: uninstall)
            Button(Copy.text("Annuler", "Cancel"), role: .cancel) {}
        } message: {
            Text(deleteAllData
                 ? Copy.text("L’application sera mise à la corbeille. Le cache, l’historique et les plugins conservés pour restauration seront supprimés définitivement.", "The app will move to Trash. Cache, history and saved plugins will be permanently deleted.")
                 : Copy.text("L’application sera mise à la corbeille et le cache supprimé. L’historique et les sauvegardes de plugins seront conservés.", "The app will move to Trash and the cache will be cleared. History and saved plugins will be kept."))
        }
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private func isValidApp(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "app" && Bundle(url: url)?.bundleIdentifier == "com.syb-illin.LogicPluginSweeper"
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.message = Copy.text("Choisissez LogicPluginSweeper.app (pas un plugin audio).", "Choose LogicPluginSweeper.app (not an audio plugin).")
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let selected = panel.url {
            if isValidApp(selected) { appURL = selected; errorMessage = nil }
            else { errorMessage = Copy.text("Ce n’est pas LogicPluginSweeper.app.", "This is not LogicPluginSweeper.app.") }
        }
    }

    private func refreshInventory() {
        inventory = nil
        let service = self.service
        Task {
            do {
                inventory = try await Task.detached(priority: .utility) { try service.inventory() }.value
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func exportData() {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.syb-illin.LogicPluginSweeper").isEmpty {
            errorMessage = Copy.text("Quittez LogicPluginSweeper avant l’export.", "Quit LogicPluginSweeper before exporting.")
            return
        }
        let panel = NSOpenPanel()
        panel.message = Copy.text("Choisissez où conserver une copie complète des données.", "Choose where to keep a complete copy of your data.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let folder = panel.url {
            let destination = folder.appendingPathComponent("LogicPluginSweeper-Data-\(UUID().uuidString.prefix(8))", isDirectory: true)
            let service = self.service
            isWorking = true
            status = nil
            errorMessage = nil
            Task {
                do {
                    try await Task.detached { try service.exportData(to: destination) }.value
                    status = Copy.text("Données exportées dans \(destination.path)", "Data exported to \(destination.path)")
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } catch { errorMessage = error.localizedDescription }
                isWorking = false
            }
        }
    }

    private func uninstall() {
        guard let appURL, isValidApp(appURL) else { return }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.syb-illin.LogicPluginSweeper").isEmpty {
            errorMessage = Copy.text("Quittez LogicPluginSweeper avant de le désinstaller.", "Quit LogicPluginSweeper before uninstalling.")
            return
        }
        isWorking = true
        status = nil
        errorMessage = nil
        let choice: UninstallService.DataChoice = deleteAllData ? .delete : .keep
        let service = self.service
        Task {
            do {
                try await Task.detached {
                    guard Bundle(url: appURL)?.bundleIdentifier == "com.syb-illin.LogicPluginSweeper" else { throw UninstallFailure.invalidApp }
                    try FileManager.default.trashItem(at: appURL, resultingItemURL: nil)
                }.value
                self.appURL = nil
                do {
                    try await Task.detached { try service.removeData(choice: choice) }.value
                    status = Copy.text("Application désinstallée. Les plugins audio installés n’ont pas été touchés.", "Application uninstalled. Installed audio plugins were not changed.")
                    refreshInventory()
                } catch {
                    errorMessage = Copy.text("Application mise à la corbeille, mais nettoyage des données incomplet : \(error.localizedDescription)", "App moved to Trash, but data cleanup was incomplete: \(error.localizedDescription)")
                }
            } catch { errorMessage = error.localizedDescription }
            isWorking = false
        }
    }
}

private enum UninstallFailure: LocalizedError {
    case invalidApp
    var errorDescription: String? { "The selected application is no longer LogicPluginSweeper.app." }
}
