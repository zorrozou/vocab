import Foundation
import Observation
import UserNotifications

enum ReminderStatus: Equatable {
    case disabled, checking, scheduled, denied, failed, invalidTime
}

/// Serializes notification changes across permission prompts and async writes.
/// A newer setting always wins, including when the account changes mid-request.
@MainActor
@Observable
final class ReminderCoordinator {
    private let requestPermission: () async -> Bool
    private let schedule: (Int) async throws -> Void
    private let cancel: () -> Void
    private(set) var status: ReminderStatus = .disabled
    private var enabled = false
    private var hour = 21
    private var revision: UInt64 = 0
    private var running = false

    init(requestPermission: @escaping () async -> Bool,
         schedule: @escaping (Int) async throws -> Void,
         cancel: @escaping () -> Void) {
        self.requestPermission = requestPermission
        self.schedule = schedule
        self.cancel = cancel
    }

    func apply(enabled: Bool, hour: Int) {
        revision &+= 1
        self.enabled = enabled && (0...23).contains(hour)
        self.hour = hour
        status = !enabled ? .disabled : self.enabled ? .checking : .invalidTime
        // Disable immediately even if an earlier permission request is open.
        if !self.enabled { cancel() }
        guard !running else { return }
        running = true
        Task { await drain() }
    }

    private func drain() async {
        defer { running = false }
        while true {
            let current = revision, wanted = enabled, requestedHour = hour
            if wanted {
                let granted = await requestPermission()
                if current != revision { continue }
                if granted {
                    do {
                        try await schedule(requestedHour)
                        if current == revision { status = .scheduled }
                    } catch {
                        if current == revision { cancel(); status = .failed }
                    }
                } else {
                    cancel(); status = .denied
                }
            } else {
                cancel()
            }
            if current == revision { return }
        }
    }
}

/// 本地每日复习提醒（纯本地通知，不走任何服务器）
@MainActor
enum NotificationService {
    private static let identifier = "dailyReviewReminder"
    private static let coordinator = ReminderCoordinator(
        requestPermission: {
            (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
        },
        schedule: { hour in
            let content = UNMutableNotificationContent()
            content.title = "词航"
            content.body = "今天的学习时间到了，打开词航查看学习计划。"
            content.sound = .default
            var dc = DateComponents()
            dc.hour = hour
            dc.minute = 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        },
        cancel: {
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: [identifier])
        }
    )

    static func apply(settings: Settings) {
        coordinator.apply(enabled: settings.notifyEnabled, hour: settings.notifyHour)
    }

    static var status: ReminderStatus { coordinator.status }
}
