import AppKit
import Foundation
import UserNotifications

/// Local notifications ("Saved", "Link copied"). Only works from the real bundle; every failure is silent.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    enum Action: String {
        case openUpdates
    }

    /// Set by the app; runs on the main thread when the user taps a notification carrying `.openUpdates`.
    nonisolated(unsafe) static var openUpdatesHandler: (() -> Void)?

    private var available: Bool { AppInfo.isRunningFromBundle }

    func notify(title: String, body: String, url: URL? = nil, action: Action? = nil) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { Log.note("notification authorization failed: \(error.localizedDescription)") }
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let url { content.userInfo["url"] = url.absoluteString }
            if let action { content.userInfo["action"] = action.rawValue }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                if let error { Log.note("notification failed: \(error.localizedDescription)") }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let string = userInfo["url"] as? String, let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
        if let raw = userInfo["action"] as? String, let action = Action(rawValue: raw) {
            DispatchQueue.main.async {
                switch action {
                case .openUpdates: Notifier.openUpdatesHandler?()
                }
            }
        }
        completionHandler()
    }
}
