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
        links.append(make(String(localized: "Second-hand (AbeBooks)"), "arrow.3.trianglepath",
                          { "https://www.abebooks.com/servlet/SearchResults?kn=\($0)" }))
        links.append(make(String(localized: "Library (Libby / OverDrive)"), "building.columns",
                          { "https://www.overdrive.com/search?q=\($0)" }))
        return links.compactMap { $0 }
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

    var body: some View {
        let links = StoreLinks.links(title: title, author: author)
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Where to Get It")
                    .appFont(size: 12, weight: .semibold)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
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
}
