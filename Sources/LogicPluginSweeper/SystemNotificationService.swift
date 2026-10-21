import Foundation
import UserNotifications

@MainActor
final class SystemNotificationService {
    private let center = UNUserNotificationCenter.current()
    private var authorizationRequested = false

    func prepare() async {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func scanCompleted(pluginCount: Int, footprint: String) async {
        await post(title: L10n.text("notification.scan.title"), body: L10n.format("notification.scan.body", pluginCount, footprint))
    }

    func quarantineCompleted(pluginName: String) async {
        await post(title: L10n.text("notification.quarantine.title"), body: L10n.format("notification.quarantine.body", pluginName))
    }

    func projectAnalysisCompleted(projectCount: Int, usedPluginCount: Int) async {
        await post(title: L10n.text("notification.projects.title"), body: L10n.format("notification.projects.body", projectCount, usedPluginCount))
    }

    func operationFailed(_ message: String) async {
        await post(title: L10n.text("app.title"), body: message)
    }

    private func post(title: String, body: String) async {
        await prepare()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        _ = try? await center.add(request)
    }
}
