import EventKit
import Foundation

/// Drops a "resume work" reminder into Reminders.app for when the 5-hour window refills.
@MainActor
enum ResumeReminder {
    private static let store = EKEventStore()
    private static let lastKey = "resumeReminderAt"

    enum Outcome {
        case created(Date)
        case alreadySet(Date)
        case denied
        case failed(String)
    }

    static func create(at date: Date) async -> Outcome {
        // One reminder per reset: a second tap on the same window shouldn't stack duplicates.
        if let last = UserDefaults.standard.object(forKey: lastKey) as? Date, abs(last.timeIntervalSince(date)) < 60 {
            return .alreadySet(date)
        }
        do {
            guard try await store.requestFullAccessToReminders() else { return .denied }
        } catch {
            return .failed(error.localizedDescription)
        }
        guard let calendar = store.defaultCalendarForNewReminders() else { return .failed("No default Reminders list") }

        let reminder = EKReminder(eventStore: store)
        reminder.title = "Resume Claude work"
        reminder.notes = "Your Claude 5-hour usage window has reset."
        reminder.calendar = calendar
        reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        reminder.addAlarm(EKAlarm(absoluteDate: date))
        do {
            try store.save(reminder, commit: true)
        } catch {
            return .failed(error.localizedDescription)
        }
        UserDefaults.standard.set(date, forKey: lastKey)
        return .created(date)
    }
}
