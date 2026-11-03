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
    private static let requestID = "reading-reminder"

    /// Registers the notification's "Update…" text field. Once per launch.
    static func registerCategory() {
        let update = UNTextInputNotificationAction(
            identifier: updateAction,
            title: String(localized: "Update…"),
            options: [],
            textInputButtonTitle: String(localized: "Save"),
            textInputPlaceholder: String(localized: "Percent, e.g. 60")
        )
        let category = UNNotificationCategory(identifier: category, actions: [update],
                                              intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category, KoboSync.categoryObject])
    }

    static func reschedule() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestID])

        let prefs = Preferences.shared
        let model = LibraryModel.shared
        let reading = model.currentlyReading.isEmpty
            ? (ShelfCache.read(.currentlyReading)?.entries ?? [])
            : model.currentlyReading
        guard prefs.readingReminder, let book = reading.first else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Time to read?")
        content.body = book.progress.map { String(localized: "You're \($0)% into \(book.title). Update your progress?") }
            ?? String(localized: "How far are you into \(book.title)?")
        if let plan = FinishPlans.date(for: book.bookID), let total = LibraryModel.shared.bookExtras[book.bookID]?.pages,
           let needed = FinishPlans.pagesPerDay(left: total - total * (book.progress ?? 0) / 100, by: plan) {
            content.body += " " + String(localized: "\(needed) pages today keeps you on track to finish by \(LibraryModel.shortDate(plan)).")
        }
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["entryID": book.id]

        var when = DateComponents()
        when.hour = prefs.reminderMinutes / 60
        when.minute = prefs.reminderMinutes % 60
        let request = UNNotificationRequest(
            identifier: requestID, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
        )
        center.add(request) { _ in }
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
