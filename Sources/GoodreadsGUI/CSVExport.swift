#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers

/// The whole app rests on undocumented endpoints Goodreads could retire.
/// A local copy of your library is cheap insurance.
enum CSVExport {

    static let header = "Book Id,Title,Author,ISBN,ISBN13,My Rating,Date Read,Date Added,Shelf,My Notes,My Quotes"

    static func csv(for entries: [ShelfEntry], shelf: Shelf, notes: [String: BookNote] = [:]) -> String {
        ([header] + dataLines(for: entries, shelf: shelf, notes: notes)).joined(separator: "\n") + "\n"
    }

    /// Just the data rows, no header — for combining several shelves into one
    /// file without re-splitting already-escaped CSV text (a quoted field
    /// can itself contain a newline, which a naive `split("\n")` would break).
    static func dataLines(for entries: [ShelfEntry], shelf: Shelf,
                          notes: [String: BookNote] = [:]) -> [String] {
        entries.map { entry in
            let note = notes[entry.bookID]
            let fields = [
                entry.bookID,
                entry.title,
                entry.author,
                isbnField(entry.isbn),
                isbnField(entry.isbn13),
                entry.rating.map(String.init) ?? "",
                entry.dateRead ?? "",
                entry.dateAdded ?? "",
                shelf.name,
                note?.text ?? "",
                // One cell; " | " rarely appears inside a quote.
                (note?.quotes ?? []).joined(separator: " | ")
            ]
            return fields.map(escape).joined(separator: ",")
        }
    }

    /// Goodreads' own export wraps ISBNs as `="0439023483"` so a spreadsheet
    /// treats the cell as text — otherwise Excel drops a leading zero or
    /// renders a 13-digit ISBN in scientific notation.
    private static func isbnField(_ isbn: String?) -> String {
        guard let isbn, !isbn.isEmpty else { return "" }
        return "=\"\(isbn)\""
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

    #if os(macOS)
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
    #else
    /// iOS: into the app's Documents folder, which the Files app shows under
    /// On My iPhone → Goodreads.
    @MainActor
    static func save(_ text: String, suggestedName: String) -> SaveResult {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = folder.appendingPathComponent(suggestedName)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return .saved(String(localized: "\(suggestedName) in Files"))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
    #endif
}
