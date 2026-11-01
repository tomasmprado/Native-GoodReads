// iOS only: the iPhone and iPad app's entry point. The Mac app's is App.swift.
#if os(iOS)
import CoreSpotlight
import SwiftUI
import UserNotifications

@main
struct GoodreadsiOSApp: App {
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var appDelegate

    init() {
        // Same reasoning as the Mac app: the default URLCache is far too
        // small for a library's worth of covers.
        URLCache.shared = URLCache(
            memoryCapacity: 48 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024,
            directory: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                          let bookID = SpotlightIndex.bookID(fromIdentifier: identifier),
                          let entry = ShelfCache.entry(bookID: bookID) else { return }
                    LibraryModel.shared.showBookDetail(entry.asBook)
                }
        }
    }
}

/// Notifications: shown while the app is open, and the reading reminder's
/// typed percentage handled — the iOS side of what AppDelegate does on the Mac.
@MainActor
final class IOSAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        ReadingReminder.registerCategory()
        ReadingReminder.reschedule()
        return true
    }

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
        await MainActor.run {
            ReadingReminder.handle(entryID: entryID, typed: typed)
        }
    }
}
#endif
