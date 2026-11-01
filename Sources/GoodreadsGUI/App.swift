// macOS only: the iOS app has its own entry point and no menu bar, panel or self-updater.
#if os(macOS)
import SwiftUI

/// Lets `AppDelegate` (not a `View`, so it has no `@Environment`) reopen the
/// main window after it's been closed — `NSApp.windows` no longer contains it
/// at that point, so re-fronting an existing window isn't enough.
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    var openMain: (() -> Void)?
    private init() { }
}

@main
struct GoodreadsGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    init() {
        // `AsyncImage` (used everywhere here for covers and avatars) goes
        // through `URLSession.shared`, which respects `URLCache.shared` —
        // but that default cache is only 512KB memory / 10MB disk, tiny
        // next to a library's worth of cover art. A shelf pane recycling
        // rows while scrolling, or just switching panes and back, was
        // re-fetching covers that had already loaded once this session.
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024,
            directory: nil
        )
    }

    var body: some Scene {
        WindowGroup("Goodreads", id: "main") {
            ContentView()
                .onAppear { WindowManager.shared.openMain = { openWindow(id: "main") } }
        }
        .defaultSize(width: 820, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        Settings {
            PreferencesView()
        }
    }
}
#endif
