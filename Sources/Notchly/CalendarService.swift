import EventKit

@MainActor
final class CalendarService {
    private let store = EKEventStore()

    var hasAuthorizedAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func nextEvent(requestingAccessIfNeeded: Bool) async throws -> EKEvent? {
        let granted: Bool
        if hasAuthorizedAccess {
            granted = true
        } else if requestingAccessIfNeeded {
            granted = try await store.requestFullAccessToEvents()
        } else {
            granted = false
        }
        guard granted else { throw CalendarAccessError.denied }

        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .first
    }
}

enum CalendarAccessError: Error { case denied }

enum CalendarUrgencyPolicy {
    static func isImminent(
        startDate: Date?,
        now: Date = .now,
        threshold: TimeInterval = 2 * 60 * 60
    ) -> Bool {
        guard let startDate else { return false }
        let interval = startDate.timeIntervalSince(now)
        return interval >= 0 && interval <= threshold
    }
}

struct ReminderSnapshot: Equatable, Sendable {
    let title: String
    let dueDate: Date?
    let priority: Int
}

enum ReminderSelectionPolicy {
    static func next(from reminders: [ReminderSnapshot]) -> ReminderSnapshot? {
        reminders.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                let leftPriority = normalizedPriority(lhs.priority)
                let rightPriority = normalizedPriority(rhs.priority)
                if leftPriority != rightPriority { return leftPriority < rightPriority }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }.first
    }

    static func subtitle(dueDate: Date?, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let dueDate else { return "没有设置截止时间" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = calendar.isDateInToday(dueDate) ? "今天 HH:mm" : "M月d日 HH:mm"
        let formatted = formatter.string(from: dueDate)
        return dueDate < now ? "已逾期 · \(formatted)" : formatted
    }

    private static func normalizedPriority(_ priority: Int) -> Int {
        priority == 0 ? Int.max : priority
    }
}

@MainActor
final class ReminderService {
    private let store = EKEventStore()

    var hasAuthorizedAccess: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    func nextReminder(requestingAccessIfNeeded: Bool) async throws -> ReminderSnapshot? {
        let granted: Bool
        if hasAuthorizedAccess {
            granted = true
        } else if requestingAccessIfNeeded {
            granted = try await store.requestFullAccessToReminders()
        } else {
            granted = false
        }
        guard granted else { throw ReminderAccessError.denied }

        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        let reminders: [ReminderSnapshot] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let snapshots = (reminders ?? []).compactMap { reminder -> ReminderSnapshot? in
                    guard !reminder.isCompleted else { return nil }
                    let trimmedTitle = reminder.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let dueDate = reminder.dueDateComponents.flatMap { components in
                        components.calendar?.date(from: components) ?? Calendar.current.date(from: components)
                    }
                    return ReminderSnapshot(
                        title: trimmedTitle.isEmpty ? "未命名提醒" : trimmedTitle,
                        dueDate: dueDate,
                        priority: reminder.priority
                    )
                }
                continuation.resume(returning: snapshots)
            }
        }
        return ReminderSelectionPolicy.next(from: reminders)
    }
}

enum ReminderAccessError: Error { case denied }
