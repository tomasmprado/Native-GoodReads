import Foundation

struct Book: Identifiable, Hashable, Codable {
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
    /// Google Books' subjects, e.g. "Fiction / Science Fiction".
    var categories: [String]? = nil

    /// This book with whatever it's missing taken from `other`.
    func filled(from other: Book?) -> Book {
        guard let other else { return self }
        var book = self
        if book.description?.isEmpty ?? true { book.description = other.description }
        if book.publisher?.isEmpty ?? true { book.publisher = other.publisher }
        if book.pageCount == nil { book.pageCount = other.pageCount }
        if book.publishedDate?.isEmpty ?? true { book.publishedDate = other.publishedDate }
        if book.language?.isEmpty ?? true { book.language = other.language }
        if book.isbn?.isEmpty ?? true { book.isbn = other.isbn }
        if book.categories?.isEmpty ?? true { book.categories = other.categories }
        return book
    }

    /// `other`'s details where it has them — for when Google Books comes
    /// first. Keeps this book's identity, cover and author.
    func preferring(_ other: Book?) -> Book {
        guard let other else { return self }
        var book = self
        if !other.title.isEmpty { book = Book(id: id, title: other.title, author: author, coverURL: coverURL, rating: rating,
                                              publisher: publisher, isbn: isbn, goodreadsID: goodreadsID,
                                              language: language, description: description, pageCount: pageCount,
                                              publishedDate: publishedDate, categories: categories) }
        if let value = other.description, !value.isEmpty { book.description = value }
        if let value = other.publisher, !value.isEmpty { book.publisher = value }
        if let value = other.pageCount { book.pageCount = value }
        if let value = other.publishedDate, !value.isEmpty { book.publishedDate = value }
        if let value = other.language, !value.isEmpty { book.language = value }
        if let value = other.isbn, !value.isEmpty { book.isbn = value }
        if let value = other.categories, !value.isEmpty { book.categories = value }
        return book
    }

    /// Google's subjects as plain genres: "Fiction / Science Fiction" gives
    /// "Science Fiction", without repeats or the generic "General".
    var genresFromCategories: [String] {
        var seen: [String] = []
        for category in categories ?? [] {
            let parts = category.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let last = parts.last(where: { !$0.isEmpty && $0 != "General" }) ?? parts.first else { continue }
            if !seen.contains(last) { seen.append(last) }
        }
        return seen
    }
}

/// A shelf is just a name to Goodreads — the endpoints take arbitrary strings.
/// The three built-ins are special only in being mutually exclusive.
struct Shelf: Identifiable, Hashable, Codable {
    let name: String        // url slug, e.g. "currently-reading"
    let label: String       // Goodreads' own name — also what page automation looks for, so stays English

    /// The name shown in the app: built-in shelves translated, custom ones as named on Goodreads.
    var title: String {
        switch name {
        case "to-read":           return String(localized: "Want to Read")
        case "currently-reading": return String(localized: "Currently Reading")
        case "read":              return String(localized: "Read")
        default:                  return label
        }
    }
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
    var dateAdded: String?
    var isbn: String?
    var isbn13: String?
    var progress: Int?      // percent, currently-reading only

    var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }

    var asBook: Book {
        Book(id: bookID, title: title, author: author, coverURL: coverURL, rating: nil,
             isbn: isbn13 ?? isbn, goodreadsID: bookID)
    }

    /// Substring match across title and author, for the filter field.
    func matches(_ term: String) -> Bool {
        guard !term.isEmpty else { return true }
        let needle = term.lowercased()
        return title.lowercased().contains(needle) || author.lowercased().contains(needle)
    }
}

/// How a shelf pane orders its rows. `.asShelved` is whatever order
/// `/review/list` handed back (Goodreads' own default sort for the shelf).
enum ShelfSortOrder: String, CaseIterable, Identifiable {
    case asShelved  = "As Shelved"
    case title      = "Title"
    case author     = "Author"
    case rating     = "Rating"
    case dateRead   = "Date Read"
    case dateAdded  = "Date Added"
    /// Want to Read only: your own order, see `QueueOrder`.
    case myOrder    = "My Order"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .asShelved: return String(localized: "As Shelved")
        case .title:     return String(localized: "Title")
        case .author:    return String(localized: "Author")
        case .rating:    return String(localized: "Rating")
        case .dateRead:  return String(localized: "Date Read")
        case .dateAdded: return String(localized: "Date Added")
        case .myOrder:   return String(localized: "My Order")
        }
    }

    func sorted(_ entries: [ShelfEntry]) -> [ShelfEntry] {
        switch self {
        case .asShelved:
            return entries
        case .myOrder:
            return QueueOrder.apply(entries)
        case .title:
            return entries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .author:
            return entries.sorted { $0.author.localizedCaseInsensitiveCompare($1.author) == .orderedAscending }
        case .rating:
            // Unrated books sink to the bottom rather than being treated as 0★.
            return entries.sorted { ($0.rating ?? -1) > ($1.rating ?? -1) }
        case .dateRead:
            return entries.sorted {
                (Suggestions.parseDate($0.dateRead ?? "") ?? .distantPast)
                    > (Suggestions.parseDate($1.dateRead ?? "") ?? .distantPast)
            }
        case .dateAdded:
            return entries.sorted {
                (Suggestions.parseDate($0.dateAdded ?? "") ?? .distantPast)
                    > (Suggestions.parseDate($1.dateAdded ?? "") ?? .distantPast)
            }
        }
    }
}

/// Genre names from Goodreads and Google Books are English; this shows them
/// in the app's language (Resources/*.lproj/Genres.strings).
enum GenreNames {
    static func display(_ genre: String) -> String {
        Bundle.main.localizedString(forKey: genre, value: genre, table: "Genres")
    }
}
