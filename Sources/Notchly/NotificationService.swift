import UserNotifications

enum WellnessNotificationAuthorization: Sendable, Equatable {
    case authorized
    case denied
    case notDetermined
    case unavailable

    var statusText: String {
        switch self {
        case .authorized: "通知已授权"
        case .denied: "通知权限已关闭"
        case .notDetermined: "等待通知授权"
        case .unavailable: "通知当前不可用"
        }
    }
}

struct WellnessReminderSchedule: Sendable {
    let authorization: WellnessNotificationAuthorization
    let hydrationNext: Date?
    let standNext: Date?
    let statusMessage: String

    static let idle = WellnessReminderSchedule(
        authorization: .notDetermined,
        hydrationNext: nil,
        standNext: nil,
        statusMessage: "正在检查提醒状态…"
    )
}

actor NotificationService {
    private let focusCompleteIdentifier = "pomodoro.complete"
    private let hydrationIdentifier = "wellness.hydration"
    private let standIdentifier = "wellness.stand"
    private let wellnessTestIdentifier = "wellness.test"

    func scheduleFocusComplete(after seconds: Int) async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { return }

            center.removePendingNotificationRequests(withIdentifiers: [focusCompleteIdentifier])
            let content = UNMutableNotificationContent()
            content.title = "专注时间结束"
            content.body = "做得好，休息一下再继续吧。"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(max(seconds, 1)), repeats: false)
            let request = UNNotificationRequest(identifier: focusCompleteIdentifier, content: content, trigger: trigger)
            try await center.add(request)
        } catch {
            // Notifications are an enhancement; the timer remains fully functional without them.
        }
    }

    nonisolated func cancelFocusComplete() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [focusCompleteIdentifier])
    }

    func updateWellnessReminders(
        hydrationEnabled: Bool,
        hydrationMinutes: Int,
        standEnabled: Bool,
        standMinutes: Int
    ) async -> WellnessReminderSchedule {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [hydrationIdentifier, standIdentifier])
        guard hydrationEnabled || standEnabled else {
            let authorization = await authorizationState(for: center)
            return WellnessReminderSchedule(
                authorization: authorization,
                hydrationNext: nil,
                standNext: nil,
                statusMessage: "健康提醒未开启"
            )
        }

        do {
            let authorization = try await requestWellnessAuthorization(using: center)
            guard authorization == .authorized else {
                return WellnessReminderSchedule(
                    authorization: authorization,
                    hydrationNext: nil,
                    standNext: nil,
                    statusMessage: "请在系统设置中允许 Notchly 发送通知。"
                )
            }
            let now = Date()
            if hydrationEnabled {
                try await addRepeatingReminder(
                    identifier: hydrationIdentifier,
                    title: "喝口水吧",
                    body: "给自己一分钟，补充水分再继续。",
                    minutes: hydrationMinutes,
                    center: center
                )
            }
            if standEnabled {
                try await addRepeatingReminder(
                    identifier: standIdentifier,
                    title: "起身活动一下",
                    body: "伸展肩颈、走几步，别让久坐偷走状态。",
                    minutes: standMinutes,
                    center: center
                )
            }
            return WellnessReminderSchedule(
                authorization: authorization,
                hydrationNext: hydrationEnabled ? now.addingTimeInterval(TimeInterval(max(hydrationMinutes, 1) * 60)) : nil,
                standNext: standEnabled ? now.addingTimeInterval(TimeInterval(max(standMinutes, 1) * 60)) : nil,
                statusMessage: "提醒已排定，会以 macOS 横幅和声音通知。"
            )
        } catch {
            return WellnessReminderSchedule(
                authorization: await authorizationState(for: center),
                hydrationNext: nil,
                standNext: nil,
                statusMessage: "无法排定提醒，请检查 macOS 通知设置。"
            )
        }
    }

    func scheduleWellnessTestNotification() async -> WellnessReminderSchedule {
        let center = UNUserNotificationCenter.current()
        do {
            let authorization = try await requestWellnessAuthorization(using: center)
            guard authorization == .authorized else {
                return WellnessReminderSchedule(
                    authorization: authorization,
                    hydrationNext: nil,
                    standNext: nil,
                    statusMessage: "无法发送测试：请先允许 Notchly 发送通知。"
                )
            }
            center.removePendingNotificationRequests(withIdentifiers: [wellnessTestIdentifier])
            let content = UNMutableNotificationContent()
            content.title = "Notchly 提醒测试"
            content.body = "如果看到了这条横幅，喝水和久坐提醒都会在设定时间正常出现。"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            try await center.add(UNNotificationRequest(identifier: wellnessTestIdentifier, content: content, trigger: trigger))
            return WellnessReminderSchedule(
                authorization: authorization,
                hydrationNext: nil,
                standNext: nil,
                statusMessage: "测试通知将在 1 秒后发送。"
            )
        } catch {
            return WellnessReminderSchedule(
                authorization: await authorizationState(for: center),
                hydrationNext: nil,
                standNext: nil,
                statusMessage: "无法发送测试通知，请检查 macOS 通知设置。"
            )
        }
    }

    private func addRepeatingReminder(
        identifier: String,
        title: String,
        body: String,
        minutes: Int,
        center: UNUserNotificationCenter
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(max(minutes, 1) * 60),
            repeats: true
        )
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    private func requestWellnessAuthorization(using center: UNUserNotificationCenter) async throws -> WellnessNotificationAuthorization {
        let existing = await authorizationState(for: center)
        guard existing == .notDetermined else { return existing }
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        return await authorizationState(for: center)
    }

    private func authorizationState(for center: UNUserNotificationCenter) async -> WellnessNotificationAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unavailable
        }
    }
}
