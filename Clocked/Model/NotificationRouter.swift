import UserNotifications

/// The one delegate for Clocked's notifications: shows banners while Clocked is frontmost, and
/// sends Undo and Show on a Claude change to `ClaudeActivity`.
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    private let activity: ClaudeActivity

    init(activity: ClaudeActivity) {
        self.activity = activity
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([ClaudeActivity.notificationCategoryDefinition])
        center.delegate = self
    }

    /// Shows the banner even when Clocked is the frontmost app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let action = response.actionIdentifier
        guard content.categoryIdentifier == ClaudeActivity.notificationCategory,
              let id = (content.userInfo["change"] as? String).flatMap(UUID.init) else {
            return completionHandler()
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch action {
                case "undo": self.activity.undo(id)
                case UNNotificationDismissActionIdentifier: break
                default: self.activity.reveal(id)
                }
            }
            completionHandler()
        }
    }
}
