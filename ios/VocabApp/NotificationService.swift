import Foundation
import UserNotifications

/// 本地每日复习提醒（纯本地通知，不走任何服务器）
enum NotificationService {
    private static let identifier = "dailyReviewReminder"

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// 每天整点重复提醒；开启/改时间时重排即可（同 identifier 覆盖）
    static func scheduleDaily(hour: Int) {
        let content = UNMutableNotificationContent()
        content.title = "词航"
        content.body = "今天还没背单词吗？来 10 分钟，把今天的词记住。"
        content.sound = .default
        var dc = DateComponents()
        dc.hour = hour
        dc.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    static func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// 按设置应用（开启就重排，关闭就取消）
    static func apply(settings: Settings) async {
        guard settings.notifyEnabled else {
            cancel()
            return
        }
        if await requestPermission() {
            scheduleDaily(hour: settings.notifyHour)
        }
    }
}
