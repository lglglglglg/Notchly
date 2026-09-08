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
