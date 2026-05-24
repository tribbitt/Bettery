import Foundation
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private override init() {
        super.init()
        // The delegate MUST be set before any notification could possibly arrive —
        // otherwise willPresent isn't asked, and the system silently drops the
        // banner because LSUIElement apps still count as "active" enough to
        // trigger the default in-app suppression rule.
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                NSLog("Bettery: notification auth error: \(error)")
            }
            NSLog("Bettery: notification auth granted=\(granted)")
        }
    }

    func notifyToggle(saverOn: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Bettery Toggled Low-Power Mode"
        content.body = saverOn ? "Currently On" : "Currently Off"
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("Bettery: notification add failed: \(error)")
            }
        }
    }

    // Without this, banners are dropped when our process is "active." Returning
    // .banner forces them to surface; .list keeps them in Notification Center
    // so the user can scroll back through recent toggles.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
