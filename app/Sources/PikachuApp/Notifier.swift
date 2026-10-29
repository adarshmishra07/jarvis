import UserNotifications
import PikachuCore

/// Reminders as macOS notifications, with Done and Snooze 10 min. Shown even while the app is in front.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: "reminder", actions: [
            UNNotificationAction(identifier: "done", title: "Done"),
            UNNotificationAction(identifier: "snooze", title: "Snooze 10 min"),
        ], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(id: Int, text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Reminder"
        content.body = text
        content.sound = .default
        content.categoryIdentifier = "reminder"
        content.userInfo = ["reminderId": id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "reminder-\(id)-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["reminderId"] as? Int
        if response.actionIdentifier == "snooze", let id { Task { @MainActor in await self.model.snoozeReminder(id) } }
        done()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler show: @escaping (UNNotificationPresentationOptions) -> Void) {
        show([.banner, .sound])
    }
}
