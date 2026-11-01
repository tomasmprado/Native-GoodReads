import Foundation

/// User-editable extra CSS selectors, merged in *ahead of* this app's own
/// built-in guesses at Goodreads' fragile, undocumented markup.
///
/// README's "The fragile part" already tells people the fix for a broken
/// selector is a one-line change in `ShelfService.swift` or
/// `GoodreadsFriends.swift` — true for someone building from source, useless
/// for the far more common case of someone running the prebuilt `.dmg`, who
/// has no selector list to edit. This gives that person a file to edit
/// instead: drop replacement selectors into
/// `~/Library/Application Support/GoodreadsGUI/selectors.json` and relaunch,
/// no Xcode required. An empty or missing file (the default) changes
/// nothing — every list here is additive, tried before the built-ins.
enum SelectorOverrides {

    struct Overrides: Codable {
        var shelfOpener: [String] = []      // the Want to Read / Currently Reading / Read button
        var shelfDropdown: [String] = []    // the caret that opens the full shelf menu
        var activityRow: [String] = []      // one row of a friend's activity table
        var friendCard: [String] = []       // one friend's card on the /friend page
    }

    private static let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("GoodreadsGUI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("selectors.json")
    }()

    /// Loaded once per launch — this only changes when someone hand-edits
    /// the file, and that's a relaunch either way.
    static let current: Overrides = {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(Overrides.self, from: data) else {
            return Overrides()
        }
        return decoded
    }()

    /// Renders a selector list as a JSON array literal, for inlining
    /// straight into a script argument dictionary (see `WebSession.evaluate`,
    /// which bridges `[String]` to a real JS array on its own — this is only
    /// needed by the few scripts that build their selector list as a plain
    /// string template rather than taking it as an argument).
    static func jsonArray(_ selectors: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: selectors),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}
