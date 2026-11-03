import AppKit
import CoreSpotlight
import UserNotifications
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {


    func applicationDidFinishLaunching(_ notification: Notification) {
        AutoBackup.start()
        ReadingAppsSync.shared.start()
        PriceWatch.start()

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
        if let link = content.userInfo["url"] as? String, let url = URL(string: link) {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            return
        }
        if content.categoryIdentifier == KoboSync.category {
            let wantsSync = response.actionIdentifier == KoboSync.syncAction
                || response.actionIdentifier == UNNotificationDefaultActionIdentifier
            await MainActor.run {
                guard wantsSync else { return }
                self.showLibrary()
                LibraryModel.shared.activeSheet = .koboSync
            }
            return
        }
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
