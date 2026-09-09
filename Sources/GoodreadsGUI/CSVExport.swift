import AppKit
import UniformTypeIdentifiers

/// The whole app rests on undocumented endpoints Goodreads could retire.
/// A local copy of your library is cheap insurance.
enum CSVExport {

    static let header = "Book Id,Title,Author,My Rating,Date Read,Shelf"

    static func csv(for entries: [ShelfEntry], shelf: Shelf) -> String {
        ([header] + dataLines(for: entries, shelf: shelf)).joined(separator: "\n") + "\n"
    }

    /// Just the data rows, no header — for combining several shelves into one
    /// file without re-splitting already-escaped CSV text (a quoted field
    /// can itself contain a newline, which a naive `split("\n")` would break).
    static func dataLines(for entries: [ShelfEntry], shelf: Shelf) -> [String] {
        entries.map { entry in
            let fields = [
                entry.bookID,
                entry.title,
                entry.author,
                entry.rating.map(String.init) ?? "",
                entry.dateRead ?? "",
                shelf.name
            ]
            return fields.map(escape).joined(separator: ",")
        }
    }

    /// RFC 4180: wrap in quotes, and double any quote inside.
    private static func escape(_ field: String) -> String {
        let cleaned = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(cleaned)\""
    }

    enum SaveResult {
        case saved(String)
        case cancelled
        case failed(String)
    }

    @MainActor
    static func save(_ text: String, suggestedName: String) -> SaveResult {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return .saved(url.lastPathComponent)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
