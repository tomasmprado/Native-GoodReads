import SwiftUI

@main
struct GoodreadsGUIApp: App {
    var body: some Scene {
        WindowGroup("Goodreads") {
            ContentView()
        }
        .defaultSize(width: 760, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
