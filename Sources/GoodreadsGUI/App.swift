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
                // goodreads-gui:// links go to the open window rather than a new one.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in
                    guard url.scheme == ShareIntake.scheme else { return }
                    if url.host == "session" {
                        SessionTimer.shared.handle(url)
                        return
                    }
                    Task { await ShareIntake.handle(url) }
                }
        }
        .defaultSize(width: 820, height: 680)
        .commands {
            TextSizeCommands()
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .importExport) {
                Button("Reading Apps…") {
                    WindowManager.shared.openMain?()
                    LibraryModel.shared.activeSheet = .readingApps
                }
                Button("Sync Kobo…") {
                    WindowManager.shared.openMain?()
                    LibraryModel.shared.activeSheet = .koboSync
                }
                Button("Import Highlights…") {
                    WindowManager.shared.openMain?()
                    LibraryModel.shared.activeSheet = .importHighlights
                }
                Button("Scan a Barcode…") {
                    WindowManager.shared.openMain?()
                    LibraryModel.shared.activeSheet = .scanBarcode
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Button("Back Up Notes & Progress…") {
                    Task {
                        if let status = await Backup.export() { LibraryModel.shared.status = status }
                    }
                }
                Button("Restore from Backup…") {
                    Task {
                        if let status = await Backup.restore() {
                            LibraryModel.shared.status = status
                            await LibraryModel.shared.reloadLocalData()
                        }
                    }
                }
            }
        }

        Settings {
            PreferencesView()
        }
    }
}
