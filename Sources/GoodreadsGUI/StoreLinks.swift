import SwiftUI

/// "Where to get it": searches for the book at shops, second-hand sellers
/// and libraries, picked for the Mac's region.
enum StoreLinks {

    struct Link: Identifiable, Equatable {
        let name: String
        let symbol: String
        let url: URL
        var id: String { name }
    }

    static func links(title: String, author: String, region: String? = Locale.current.region?.identifier) -> [Link] {
        let query = [title, author].filter { !$0.isEmpty }.joined(separator: " ")
        guard !query.isEmpty else { return [] }
        func make(_ name: String, _ symbol: String, _ build: (String) -> String) -> Link? {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(["&", "+", "="])) ?? query
            return URL(string: build(encoded)).map { Link(name: name, symbol: symbol, url: $0) }
        }

        var links: [Link?] = []
        if region == "PT" {
            links.append(make("Wook", "cart", { "https://www.wook.pt/pesquisa?keyword=\($0)" }))
            links.append(make("Bertrand", "cart", { "https://www.bertrand.pt/pesquisa/\($0)" }))
        }
        links.append(make("Amazon", "shippingbox", { "https://\(amazonDomain(region))/s?k=\($0)&i=stripbooks" }))
        links.append(make("Kindle", "ipad", { "https://\(amazonDomain(region))/s?k=\($0)&i=digital-text" }))
        links.append(make("Kobo", "rectangle.portrait", { "https://www.kobo.com/\(koboStore(region))/search?query=\($0)" }))
        links.append(make(String(localized: "Second-hand (AbeBooks)"), "arrow.3.trianglepath",
                          { "https://www.abebooks.com/servlet/SearchResults?kn=\($0)" }))
        links.append(make(String(localized: "Library (Libby / OverDrive)"), "building.columns",
                          { "https://www.overdrive.com/search?q=\($0)" }))
        return links.compactMap { $0 }
    }

    /// Kobo's store path: country and language, e.g. "pt/pt" or "us/en".
    static func koboStore(_ region: String?) -> String {
        switch region {
        case "PT": return "pt/pt"
        case "BR": return "br/pt"
        case "ES": return "es/es"
        case "FR": return "fr/fr"
        case "DE": return "de/de"
        case "IT": return "it/it"
        case "NL": return "nl/nl"
        case "GB": return "gb/en"
        case "IE": return "ie/en"
        case "CA": return "ca/en"
        case "AU": return "au/en"
        default: return "us/en"
        }
    }

    /// The book in the Apple Books store, through Apple's free search: the
    /// best title match among ebooks. Cached for a week.
    static func appleBooks(title: String, author: String,
                           region: String? = Locale.current.region?.identifier) async -> URL? {
        let country = (region ?? "US").lowercased()
        let key = "\(country)|\(title)|\(author)".lowercased()
        if let hit = await DataCache.shared.read(URL?.self, "apple-books-store", key, ttl: 7 * 24 * 3600), !hit.isStale {
            return hit.value
        }
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: [title, author].filter { !$0.isEmpty }.joined(separator: " ")),
            URLQueryItem(name: "media", value: "ebook"), URLQueryItem(name: "entity", value: "ebook"),
            URLQueryItem(name: "limit", value: "10"), URLQueryItem(name: "country", value: country),
        ]
        var found: URL?
        if let url = components.url, let (data, _) = try? await URLSession.shared.data(from: url),
           let result = try? JSONDecoder().decode(ITunesResult.self, from: data) {
            let books = result.results.map { Book(id: $0.trackViewUrl?.absoluteString ?? "", title: $0.trackName ?? "",
                                                  author: $0.artistName ?? "", coverURL: nil, rating: nil) }
            found = GoogleBooksClient.bestMatch(books, title: title).flatMap { URL(string: $0.id) }
        }
        await DataCache.shared.write(found, "apple-books-store", key)
        return found
    }

    private struct ITunesResult: Decodable {
        struct Item: Decodable { let trackName: String?; let artistName: String?; let trackViewUrl: URL? }
        let results: [Item]
    }

    static func amazonDomain(_ region: String?) -> String {
        switch region {
        case "PT", "ES": return "www.amazon.es"
        case "GB", "IE": return "www.amazon.co.uk"
        case "DE", "AT": return "www.amazon.de"
        case "FR", "BE": return "www.amazon.fr"
        case "IT": return "www.amazon.it"
        case "NL": return "www.amazon.nl"
        case "BR": return "www.amazon.com.br"
        case "CA": return "www.amazon.ca"
        case "MX": return "www.amazon.com.mx"
        case "JP": return "www.amazon.co.jp"
        case "IN": return "www.amazon.in"
        case "AU": return "www.amazon.com.au"
        default: return "www.amazon.com"
        }
    }
}

struct StoreLinksView: View {
    let title: String
    let author: String
    var isbn: String? = nil

    @State private var appleBooks: URL?

    var body: some View {
        let custom = CustomStores.all.compactMap { store in
            store.url(title: title, author: author, isbn: isbn).map { StoreLinks.Link(name: store.name, symbol: "storefront", url: $0) }
        }
        let links = custom + StoreLinks.links(title: title, author: author).filter { link in !custom.contains { $0.name == link.name } }
        Group {
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Where to Get It")
                    .appFont(size: 12, weight: .semibold)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let appleBooks {
                            Button {
                                NSWorkspace.shared.open(appleBooks)
                            } label: {
                                Label("Apple Books", systemImage: "book").appFont(size: 11)
                            }
                            .glassButton()
                            .controlSize(.small)
                            .help("Open this book in Apple Books")
                        }
                        ForEach(links) { link in
                            Button {
                                NSWorkspace.shared.open(link.url)
                            } label: {
                                Label(link.name, systemImage: link.symbol)
                                    .appFont(size: 11)
                            }
                            .glassButton()
                            .controlSize(.small)
                            .help(String(localized: "Search \(link.name) for this book"))
                        }
                    }
                }
            }
        }
        }
        .task(id: title) { appleBooks = await StoreLinks.appleBooks(title: title, author: author) }
    }
}

/// Your own shops and libraries, as search addresses with placeholders:
/// {title} (or {bookname}), {author} and {isbn}.
struct CustomStore: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var template: String

    static let placeholders = ["{title}", "{bookname}", "{author}", "{isbn}"]

    /// The search address for one book, or nil when the template isn't a web address.
    func url(title: String, author: String, isbn: String?) -> URL? {
        func encode(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(["&", "+", "=", "#", "?"])) ?? text
        }
        let filled = template
            .replacingOccurrences(of: "{title}", with: encode(title))
            .replacingOccurrences(of: "{bookname}", with: encode(title))
            .replacingOccurrences(of: "{author}", with: encode(author))
            .replacingOccurrences(of: "{isbn}", with: encode(isbn ?? title))
        guard let url = URL(string: filled), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && Self.placeholders.contains(where: template.contains)
            && url(title: "x", author: "y", isbn: "9780000000000") != nil
    }
}

enum CustomStores {
    private static let key = "customStores"

    static var all: [CustomStore] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([CustomStore].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
}

/// Settings → Reading Apps → Stores.
struct StoresSection: View {
    @State private var stores = CustomStores.all
    @State private var name = ""
    @State private var template = ""

    var body: some View {
        Section {
            ForEach(stores) { store in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.name)
                        Text(store.template).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        stores.removeAll { $0.id == store.id }
                        CustomStores.all = stores
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove \(store.name)")
                }
            }
            TextField("Name", text: $name, prompt: Text("e.g. Wook"))
            TextField("Search address", text: $template,
                      prompt: Text(verbatim: "https://www.wook.pt/pesquisa?keyword={bookname}"))
            Button("Add Store") {
                let store = CustomStore(name: name.trimmingCharacters(in: .whitespaces),
                                        template: template.trimmingCharacters(in: .whitespaces))
                stores.append(store)
                CustomStores.all = stores
                name = ""
                template = ""
            }
            .disabled(!CustomStore(name: name, template: template).isValid)
        } header: {
            Text("Stores")
        } footer: {
            Text("Your own shops and libraries show in Book Details under Where to Get It. In the address, {bookname} (or {title}), {author} and {isbn} are replaced by the book's.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
