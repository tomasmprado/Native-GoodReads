import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var panel: QuickPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        HotKeyCenter.shared.onTrigger = { [weak self] in self?.togglePanel() }
        HotKeyCenter.shared.register()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregister()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "books.vertical",
            accessibilityDescription: "Goodreads"
        )

        let menu = NSMenu()

        // No key equivalent here — ⌥Space is already handled system-wide by
        // the Carbon hotkey in HotKeyCenter, and having both meant the menu
        // item's own equivalent raced it whenever the app was frontmost.
        let quick = NSMenuItem(title: "Quick Add", action: #selector(togglePanel), keyEquivalent: "")
        quick.target = self
        menu.addItem(quick)

        let library = NSMenuItem(title: "Library Window", action: #selector(showLibrary), keyEquivalent: "")
        library.target = self
        menu.addItem(library)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
    }

    @objc private func showLibrary() {
        NSApp.activate(ignoringOtherApps: true)
        // The SwiftUI scene owns the window; bring back whatever exists.
        for window in NSApp.windows where !(window is QuickPanel) && window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Nothing to re-front — the window was closed, not just backgrounded.
        WindowManager.shared.openMain?()
    }

    // MARK: - Quick panel

    @objc private func togglePanel() {
        if panel == nil {
            panel = QuickPanel(content: QuickSearchView(onEscape: { [weak self] in
                self?.panel?.orderOut(nil)
            }))
        }
        panel?.toggle()
    }
}
