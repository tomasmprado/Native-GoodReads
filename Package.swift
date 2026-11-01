// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GoodreadsGUI",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GoodreadsGUI",
            path: "Sources/GoodreadsGUI",
            // Translations are copied into the .app by build-app.sh (SwiftUI
            // reads them from the main bundle), not built as SwiftPM resources.
            exclude: ["Resources"]
        ),
        // Tests `@testable import` the executable target directly — SwiftPM
        // has supported that since Swift 5.5 as long as the target uses the
        // `@main` attribute (this one does, in App.swift) rather than a
        // `main.swift`. No separate library target needed just to make the
        // pure logic reachable from a test.
        .testTarget(
            name: "GoodreadsGUITests",
            dependencies: ["GoodreadsGUI"],
            path: "Tests/GoodreadsGUITests"
        )
    ]
)
