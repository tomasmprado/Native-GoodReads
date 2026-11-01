import Foundation
import UserNotifications

/// A daily nudge at a time you choose — "You're 45% into Dune" — that takes
/// a new percentage right in the notification.
///
/// The notification's text is fixed when it's scheduled, so it's
/// rescheduled whenever Currently Reading or its progress changes.
@MainActor
enum ReadingReminder {

    nonisolated static let category = "reading-reminder"
    nonisolated static let updateAction = "update-progress"
    nonisolated private static let requestID = "reading-reminder"

    /// Registers the notification's "Update…" text field. Once per launch.
    ///
    /// Every call into the notification center here runs off the main
    /// thread: some of them wait synchronously for the system's
    /// notification service, and on a fresh install that wait was long
    /// enough to leave the app's window blank at launch.
    static func registerCategory() {
        let title = String(localized: "Update…")
        let button = String(localized: "Save")
        let placeholder = String(localized: "Percent, e.g. 60")
        Task.detached(priority: .utility) {
            let update = UNTextInputNotificationAction(identifier: updateAction, title: title, options: [],
                                                       textInputButtonTitle: button,
                                                       textInputPlaceholder: placeholder)
            let category = UNNotificationCategory(identifier: category, actions: [update],
                                                  intentIdentifiers: [], options: [])
            UNUserNotificationCenter.current().setNotificationCategories([category])
        }
    }

    private static let scheduledKey = "readingReminderScheduled"

    static func reschedule() {
        let prefs = Preferences.shared
        let model = LibraryModel.shared
        let reading = model.currentlyReading.isEmpty
            ? (ShelfCache.read(.currentlyReading)?.entries ?? [])
            : model.currentlyReading
        let book = prefs.readingReminder ? reading.first : nil

        // Nothing scheduled and nothing to schedule: leave the center alone.
        let defaults = UserDefaults.standard
        guard book != nil || defaults.bool(forKey: scheduledKey) else { return }
        defaults.set(book != nil, forKey: scheduledKey)

        let title = String(localized: "Time to read?")
        let body = book.map { book in
            book.progress.map { String(localized: "You're \($0)% into \(book.title). Update your progress?") }
                ?? String(localized: "How far are you into \(book.title)?")
        }
        let entryID = book?.id
        let hour = prefs.reminderMinutes / 60
        let minute = prefs.reminderMinutes % 60

        Task.detached(priority: .utility) {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [requestID])
            guard let body, let entryID else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = category
            content.userInfo = ["entryID": entryID]

            var when = DateComponents()
            when.hour = hour
            when.minute = minute
            let request = UNNotificationRequest(
                identifier: requestID, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
            )
            try? await center.add(request)
        }
    }

    /// The reminder was answered: a typed percentage is posted straight
    /// away; a plain click opens the progress sheet.
    static func handle(entryID: String, typed: String?) {
        let model = LibraryModel.shared
        let reading = model.currentlyReading.isEmpty
            ? (ShelfCache.read(.currentlyReading)?.entries ?? [])
            : model.currentlyReading
        guard let entry = reading.first(where: { $0.id == entryID }) else { return }

        if let typed, let percent = percent(from: typed) {
            Task { await model.updateProgress(entry, percent: percent, page: nil, note: "") }
        } else {
            model.activeSheet = .progress(entry)
        }
    }

    /// "60", "60%", " 60 % " → 60; anything outside 0…100 → nil.
    nonisolated static func percent(from text: String) -> Int? {
        let digits = text.trimmingCharacters(in: CharacterSet(charactersIn: " %\n"))
        guard let value = Int(digits), (0...100).contains(value) else { return nil }
        return value
    }
}
