// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GoodreadsGUI",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GoodreadsGUI",
            path: "Sources/GoodreadsGUI"
        )
    ]
)
