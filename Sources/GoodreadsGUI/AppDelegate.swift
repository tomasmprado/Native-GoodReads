import AppKit
import CoreSpotlight
import UserNotifications
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        UNUserNotificationCenter.current().delegate = self
        ReadingReminder.registerCategory()
        ReadingReminder.reschedule()
    }

    // MARK: - Notifications

    /// Show notifications even while the app is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        guard content.categoryIdentifier == ReadingReminder.category,
              let entryID = content.userInfo["entryID"] as? String else { return }
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        let opened = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        await MainActor.run {
            if opened { self.showLibrary() }
            ReadingReminder.handle(entryID: entryID, typed: typed)
        }
    }

    /// A book picked from Spotlight.
    func application(_ application: NSApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let bookID = SpotlightIndex.bookID(fromIdentifier: identifier),
              let entry = ShelfCache.entry(bookID: bookID) else { return false }
        showLibrary()
        LibraryModel.shared.showBookDetail(entry.asBook)
        return true
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "books.vertical",
            accessibilityDescription: "Goodreads"
        )

        let menu = NSMenu()
        menu.delegate = self

        let library = NSMenuItem(title: String(localized: "Library Window"), action: #selector(showLibrary), keyEquivalent: "")
        library.target = self
        menu.addItem(library)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
    }

    /// Rebuilds the "Currently Reading" section each time the menu opens,
    /// so it always shows the latest progress.
    func menuNeedsUpdate(_ menu: NSMenu) {
        while let item = menu.items.first, item.tag == Self.readingTag {
            menu.removeItem(item)
        }

        let model = LibraryModel.shared
        let reading = model.currentlyReading.isEmpty
            ? (ShelfCache.read(.currentlyReading)?.entries ?? [])
            : model.currentlyReading
        guard model.loggedIn || !reading.isEmpty else { return }

        var items: [NSMenuItem] = []
        let header = NSMenuItem(title: String(localized: "Currently Reading"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        items.append(header)

        if reading.isEmpty {
            let none = NSMenuItem(title: String(localized: "Nothing yet"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            items.append(none)
        }
        for entry in reading.prefix(8) {
            var title = Self.menuTitle(for: entry)
            if let done = model.finishEstimate(for: entry) {
                title += "  · " + String(localized: "done ~\(LibraryModel.shortDate(done))")
            }
            let item = NSMenuItem(title: title,
                                  action: #selector(updateProgress(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            item.image = NSImage(systemSymbolName: "book", accessibilityDescription: nil)
            item.toolTip = String(localized: "Update progress…")
            items.append(item)
        }
        items.append(.separator())

        for (index, item) in items.enumerated() {
            item.tag = Self.readingTag
            menu.insertItem(item, at: index)
        }
    }

    private static let readingTag = 7001

    private static func menuTitle(for entry: ShelfEntry) -> String {
        let title = entry.title.count > 42 ? entry.title.prefix(40) + "…" : entry.title
        guard let progress = entry.progress else { return String(title) }
        let filled = max(0, min(10, Int((Double(progress) / 10).rounded())))
        let bar = String(repeating: "▰", count: filled) + String(repeating: "▱", count: 10 - filled)
        return "\(title)  \(bar) \(progress)%"
    }

    @objc private func updateProgress(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let model = LibraryModel.shared
        let reading = model.currentlyReading.isEmpty
            ? (ShelfCache.read(.currentlyReading)?.entries ?? [])
            : model.currentlyReading
        guard let entry = reading.first(where: { $0.id == id }) else { return }
        showLibrary()
        model.activeSheet = .progress(entry)
    }

    @objc private func showLibrary() {
        NSApp.activate(ignoringOtherApps: true)
        // The SwiftUI scene owns the window; bring back whatever exists.
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Nothing to re-front — the window was closed, not just backgrounded.
        WindowManager.shared.openMain?()
    }
}
