import Foundation
import UserNotifications

public class NotificationHelper: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationHelper()

    private override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public static func showNotification(title: String, subtitle: String? = nil, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let sub = subtitle {
            content.subtitle = sub
        }
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // nil 表示立刻触发
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("通知发送失败: \(error.localizedDescription)")
            }
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // 应用在前台时依然展示横幅与声音
        if #available(macOS 14.0, *) {
            completionHandler([.banner, .sound, .list])
        } else {
            completionHandler([.alert, .sound])
        }
    }
}
