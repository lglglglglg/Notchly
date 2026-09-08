import UserNotifications

actor NotificationService {
    private let focusCompleteIdentifier = "pomodoro.complete"
    private let hydrationIdentifier = "wellness.hydration"
    private let standIdentifier = "wellness.stand"

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
    ) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [hydrationIdentifier, standIdentifier])
        guard hydrationEnabled || standEnabled else { return }

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { return }
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
        } catch {
            // The settings remain saved even when notification permission is denied.
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
}
