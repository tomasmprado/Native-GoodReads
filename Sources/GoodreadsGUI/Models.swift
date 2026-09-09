import Foundation

struct Book: Identifiable, Hashable {
    /// ISBN-13, falling back to ISBN-10, falling back to a "gb:" prefixed
    /// Google volume id for the rare item with neither. Not a Goodreads id.
    let id: String
    let title: String
    let author: String
    let coverURL: URL?
    let rating: String?
    var publisher: String? = nil
    var isbn: String? = nil
    /// Nil until resolved via `GoodreadsLookup` — already known for books that
    /// came from a Goodreads shelf entry.
    var goodreadsID: String? = nil

    // Google Books extras, carried along for the detail page so it doesn't
    // need a second fetch for data the search result already had.
    var language: String? = nil
    var description: String? = nil
    var pageCount: Int? = nil
    var publishedDate: String? = nil
}

/// A shelf is just a name to Goodreads — the endpoints take arbitrary strings.
/// The three built-ins are special only in being mutually exclusive.
struct Shelf: Identifiable, Hashable, Codable {
    let name: String        // url slug, e.g. "currently-reading"
    let label: String       // display name
    var count: Int?

    var id: String { name }

    // Goodreads' slug for this one is "to-read"; "want-to-read" is only ever
    // the display name. Getting that wrong lists the shelf twice.
    static let wantToRead      = Shelf(name: "to-read",           label: "Want to Read")
    static let currentlyReading = Shelf(name: "currently-reading", label: "Currently Reading")
    static let read            = Shelf(name: "read",              label: "Read")

    static let builtIn = [wantToRead, currentlyReading, read]

    var isBuiltIn: Bool { Shelf.builtIn.contains { $0.name == name } }
    var isExclusive: Bool { isBuiltIn }

    var symbol: String {
        switch name {
        case "to-read":            return "bookmark"
        case "currently-reading":  return "book"
        case "read":               return "checkmark.circle"
        default:                   return "tag"
        }
    }

    /// `want-to-read` and `to-read` are the same shelf under two names.
    static func canonical(_ slug: String) -> String {
        slug == "want-to-read" ? "to-read" : slug
    }

    /// Pseudo-shelves the sidebar links to but that aren't real shelves.
    static func isPseudo(_ slug: String) -> Bool {
        slug.isEmpty || slug.hasPrefix("#") || slug.uppercased() == "ALL"
    }

    /// Goodreads slugs are lowercase and hyphenated; labels are title-cased.
    static func fromSlug(_ rawSlug: String, count: Int? = nil) -> Shelf {
        let slug = canonical(rawSlug)
        if let known = builtIn.first(where: { $0.name == slug }) {
            return Shelf(name: known.name, label: known.label, count: count)
        }
        let label = slug
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return Shelf(name: slug, label: label, count: count)
    }
}

struct ShelfEntry: Identifiable, Hashable, Codable {
    let id: String          // review id when we have one, else book id
    let bookID: String
    let reviewID: String?
    let title: String
    let author: String
    let coverURLString: String?
    var rating: Int?        // 0-5
    var dateRead: String?
    var progress: Int?      // percent, currently-reading only

    var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }

    var asBook: Book {
        Book(id: bookID, title: title, author: author, coverURL: coverURL, rating: nil,
             goodreadsID: bookID)
    }

    /// Substring match across title and author, for the filter field.
    func matches(_ term: String) -> Bool {
        guard !term.isEmpty else { return true }
        let needle = term.lowercased()
        return title.lowercased().contains(needle) || author.lowercased().contains(needle)
    }
}
