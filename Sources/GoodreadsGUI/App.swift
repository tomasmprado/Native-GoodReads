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
