import Foundation

// Shared between the app and its widget extension (build-app.sh compiles
// this file into both), so it uses nothing but Foundation.

/// What the widgets show, written by the app whenever it changes.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    struct Book: Codable, Equatable, Sendable, Identifiable {
        let bookID: String
        let title: String
        let author: String
        let percent: Int?
        let finishEstimate: Date?
        /// A file in `WidgetStore.folder`, when the cover was saved.
        let coverFile: String?

        var id: String { bookID }
    }

    struct Goal: Codable, Equatable, Sendable {
        let year: Int
        let read: Int
        let goal: Int
        /// Books ahead of (positive) or behind (negative) an even pace.
        let ahead: Int
    }

    var reading: [Book]
    var goal: Goal?
    var updated: Date

    static let empty = WidgetSnapshot(reading: [], goal: nil, updated: .distantPast)
}

enum WidgetStore {
    /// The widget is sandboxed, so this is spelled out from the real home
    /// folder (a sandboxed process's own home is its container), and the
    /// widget's entitlements allow reading exactly this folder.
    static var folder: URL {
        URL(fileURLWithPath: realHome, isDirectory: true)
            .appendingPathComponent("Library/Application Support/GoodreadsGUI/widget", isDirectory: true)
    }

    static var snapshotFile: URL { folder.appendingPathComponent("snapshot.json") }

    private static var realHome: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    static func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: snapshotFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    static func write(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: snapshotFile, options: .atomic)
    }

    static let kindReading = "local.goodreads.gui.reading"
    static let kindGoal = "local.goodreads.gui.goal"
}
