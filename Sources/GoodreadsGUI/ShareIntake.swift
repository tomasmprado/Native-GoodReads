import AppKit
import Foundation

/// "Add to Goodreads" from Safari's Share menu: the share extension hands
/// the page over as goodreads-gui://add?url=…&title=…, and this finds the
/// book — by an ISBN on the page, else by its title — and adds it to Want
/// to Read (or, when it can't tell which book, shows it in Search).
enum ShareIntake {
    static let scheme = "goodreads-gui"

    struct Request: Equatable {
        let page: URL?
        let title: String
        let text: String?
    }

    static func request(from url: URL) -> Request? {
        guard url.scheme == scheme, url.host == "add",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        return Request(page: value("url").flatMap(URL.init(string:)), title: value("title") ?? "", text: value("text"))
    }

    /// The first valid ISBN-13 (or ISBN-10) in some text or HTML.
    static func isbn(in text: String) -> String? {
        let pattern = #"(?<![\d])(97[89][\d\- ]{10,16}\d|\d[\d\- ]{8,11}[\dXx])(?![\d])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let isbn = ISBN.normalized(String(text[range])),
                  isValid(isbn) else { continue }
            return isbn
        }
        return nil
    }

    /// ISBN check digits, so a random 13-digit number isn't taken for one.
    static func isValid(_ isbn: String) -> Bool {
        let digits = isbn.map { $0 == "X" ? 10 : Int(String($0)) ?? -1 }
        if digits.count == 13 {
            let sum = digits.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
            return sum % 10 == 0
        }
        if digits.count == 10 {
            let sum = digits.enumerated().reduce(0) { $0 + $1.element * (10 - $1.offset) }
            return sum % 11 == 0
        }
        return false
    }

    /// "Os Maias | Wook" → "Os Maias".
    static func cleanTitle(_ title: String) -> String {
        let cut = title.components(separatedBy: CharacterSet(charactersIn: "|–—")).first ?? title
        return cut.replacingOccurrences(of: #"\s+-\s+[^-]*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    @MainActor
    static func handle(_ url: URL) async {
        guard let request = request(from: url) else { return }
        let model = LibraryModel.shared
        WindowManager.shared.openMain?()
        NSApp.activate(ignoringOtherApps: true)
        model.status = .init(text: String(localized: "Looking for the book…"), isError: false)

        var found = request.text.flatMap(isbn(in:)) ?? request.page.flatMap { isbn(in: $0.absoluteString) }
        if found == nil, let page = request.page,
           let (data, _) = try? await URLSession.shared.data(from: page),
           let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            found = isbn(in: html)
        }

        if let isbn = found, let bookID = await GoodreadsLookup.bookID(isbn: isbn) {
            let books = (try? await GoogleBooksClient.search(isbn)) ?? []
            var book = books.first ?? Book(id: isbn, title: cleanTitle(request.title), author: "", coverURL: nil,
                                           rating: nil, isbn: isbn)
            book.goodreadsID = bookID
            await model.shelve(book, to: .wantToRead)
            model.showBookDetail(book)
            return
        }
        // No ISBN to go on: show the search, for you to pick the right one.
        model.selection = .search
        model.query = found ?? cleanTitle(request.title)
        model.searchNow()
    }
}
