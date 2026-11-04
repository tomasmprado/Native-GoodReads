import MapKit
import SwiftUI

/// Where the authors you've read come from, from Wikidata: the author's
/// country of citizenship (else where they were born).
struct AuthorCountry: Codable, Sendable, Equatable, Hashable {
    /// ISO 3166-1 alpha-2, e.g. "PT".
    let code: String
    let name: String
    let latitude: Double
    let longitude: Double

    /// 🇵🇹 from "PT".
    var flag: String {
        code.uppercased().unicodeScalars.compactMap { Unicode.Scalar(127397 + $0.value) }
            .map { String($0) }.joined()
    }

    /// The country's name in the app's language, when the system knows it.
    var displayName: String {
        Locale.current.localizedString(forRegionCode: code) ?? name
    }
}

enum AuthorCountries {
    private static let cacheTTL: TimeInterval = 180 * 24 * 3600

    static func country(for author: String) async -> AuthorCountry? {
        let key = author.lowercased()
        if let hit = await DataCache.shared.read(AuthorCountry?.self, "author-country", key, ttl: cacheTTL), !hit.isStale {
            return hit.value
        }
        let found = await lookup(author)
        await DataCache.shared.write(found, "author-country", key)
        return found
    }

    /// Already known, without asking Wikidata — for drawing the map at once.
    static func saved(for author: String) async -> AuthorCountry?? {
        await DataCache.shared.read(AuthorCountry?.self, "author-country", author.lowercased(), ttl: .infinity)?.value
    }

    private static func lookup(_ author: String) async -> AuthorCountry? {
        guard let person = await person(named: author),
              let claims = await claims(of: person) else { return nil }
        var candidates = Array(entityIDs(claims["P27"]).reversed())     // most recent citizenship first
        if candidates.isEmpty, let birthplace = entityIDs(claims["P19"]).first,
           let place = await self.claims(of: birthplace) {
            candidates = entityIDs(place["P17"])
        }
        for id in candidates {
            if let country = await country(id: id) { return country }
        }
        return nil
    }

    /// A country with an ISO code. A former state ("Kingdom of Portugal")
    /// has none, so the states that replaced it are tried, nearest first.
    private static func country(id: String) async -> AuthorCountry? {
        if let hit = await DataCache.shared.read(AuthorCountry?.self, "wikidata-country", id, ttl: .infinity) {
            return hit.value
        }
        var queue = [id]
        var seen: Set<String> = [id]
        var found: AuthorCountry?
        while !queue.isEmpty, seen.count <= 12, found == nil {
            let current = queue.removeFirst()
            guard let entity = await entity(current) else { continue }
            if let code = strings(entity.claims["P297"]).first,
               let coordinate = (entity.claims["P625"] as? [[String: Any]])?.first.flatMap(value) as? [String: Any],
               let latitude = coordinate["latitude"] as? Double, let longitude = coordinate["longitude"] as? Double {
                found = AuthorCountry(code: code, name: entity.label ?? code, latitude: latitude, longitude: longitude)
            }
            for next in entityIDs(entity.claims["P1366"]) where seen.insert(next).inserted { queue.append(next) }
        }
        await DataCache.shared.write(found, "wikidata-country", id)
        return found
    }

    private static func entity(_ id: String) async -> (claims: [String: Any], label: String?)? {
        guard let url = api(["action": "wbgetentities", "ids": id, "props": "claims|labels", "languages": "en"]),
              let data = try? await get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entity = (json["entities"] as? [String: Any])?[id] as? [String: Any],
              let claims = entity["claims"] as? [String: Any] else { return nil }
        let label = ((entity["labels"] as? [String: Any])?["en"] as? [String: Any])?["value"] as? String
        return (claims, label)
    }

    /// The first search hit described as a writer of some kind.
    private static func person(named name: String) async -> String? {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        guard let url = api(["action": "wbsearchentities", "search": name, "language": language, "uselang": "en",
                             "type": "item", "limit": "5"]),
              let data = try? await get(url),
              let result = try? JSONDecoder().decode(Search.self, from: data) else { return nil }
        return result.search.first { AuthorWikipedia.isWriter($0.description) }?.id
    }

    private static func claims(of id: String) async -> [String: Any]? {
        guard let url = api(["action": "wbgetentities", "ids": id, "props": "claims"]),
              let data = try? await get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entity = (json["entities"] as? [String: Any])?[id] as? [String: Any] else { return nil }
        return entity["claims"] as? [String: Any]
    }

    private static func value(_ claim: [String: Any]) -> Any? {
        ((claim["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"]
    }

    private static func entityIDs(_ claims: Any?) -> [String] {
        (claims as? [[String: Any]] ?? []).compactMap { claim in
            (value(claim) as? [String: Any])?["id"] as? String
        }
    }

    private static func strings(_ claims: Any?) -> [String] {
        (claims as? [[String: Any]] ?? []).compactMap { value($0) as? String }
    }

    private static func api(_ parameters: [String: String]) -> URL? {
        var components = URLComponents(string: "https://www.wikidata.org/w/api.php")!
        components.queryItems = (parameters.merging(["format": "json"]) { a, _ in a })
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("GoodreadsGUI/1.0 (macOS; https://github.com/tomasmprado/Native-GoodReads)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private struct Search: Decodable {
        struct Hit: Decodable { let id: String; let description: String? }
        let search: [Hit]
    }

    /// Countries with how many of `authors` (and their books) come from each, most first.
    struct Tally: Identifiable, Equatable {
        let country: AuthorCountry
        var authors: [String]
        var books: Int
        var id: String { country.code }
    }

    static func tally(_ books: [(author: String, country: AuthorCountry?)]) -> [Tally] {
        var byCode: [String: Tally] = [:]
        for book in books {
            guard let country = book.country else { continue }
            var tally = byCode[country.code] ?? Tally(country: country, authors: [], books: 0)
            tally.books += 1
            if !tally.authors.contains(book.author) { tally.authors.append(book.author) }
            byCode[country.code] = tally
        }
        return byCode.values.sorted { $0.books != $1.books ? $0.books > $1.books : $0.country.displayName < $1.country.displayName }
    }
}

extension LibraryModel {
    /// Countries for the Read shelf's authors: what's saved shows at once;
    /// `lookUp` asks Wikidata about the rest, one author at a time.
    func loadAuthorCountries(lookUp: Bool) async {
        let read = ShelfCache.read(.read)?.entries ?? []
        let authors = Array(Set(read.map(\.author).filter { !$0.isEmpty }))
        var countries: [String: AuthorCountry] = [:]
        var missing: [String] = []
        for author in authors {
            switch await AuthorCountries.saved(for: author) {
            case .some(.some(let country)): countries[author] = country
            case .some(.none): break
            case .none: missing.append(author)
            }
        }
        let pairs = { read.map { ($0.author, countries[$0.author]) } }
        countryTally = AuthorCountries.tally(pairs())
        authorCountryMap = countries
        authorsWithoutCountry = missing.count
        guard lookUp, !missing.isEmpty, !isLoadingCountries else { return }
        isLoadingCountries = true
        defer { isLoadingCountries = false }
        for (index, author) in missing.enumerated() where !Task.isCancelled {
            if let country = await AuthorCountries.country(for: author) { countries[author] = country }
            authorsWithoutCountry = missing.count - index - 1
            if index % 5 == 4 || index == missing.count - 1 {
                countryTally = AuthorCountries.tally(pairs())
                authorCountryMap = countries
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

/// Stats: a world map of where your authors are from.
struct AuthorsMapCard: View {
    @ObservedObject var model: LibraryModel
    @State private var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 25, longitude: 10),
                                                   span: MKCoordinateSpan(latitudeDelta: 140, longitudeDelta: 300))

    var body: some View {
        let tally = model.countryTally
        let most = max(1, tally.first?.books ?? 1)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Authors’ Countries").appFont(size: 13, weight: .semibold)
                if !tally.isEmpty {
                    Text("\(tally.count) countries").appFont(size: 11).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isLoadingCountries {
                    ProgressView().controlSize(.small)
                    Text("\(model.authorsWithoutCountry) to go").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                } else if model.authorsWithoutCountry > 0 {
                    Button("Find Countries") { Task { await model.loadAuthorCountries(lookUp: true) } }
                        .controlSize(.small)
                        .glassButton()
                        .help("Look up where each author is from on Wikidata")
                }
            }
            if tally.isEmpty {
                Text("Find Countries looks up where each author you’ve read is from.")
                    .appFont(size: 12).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    Map(coordinateRegion: $region, interactionModes: [.pan, .zoom], annotationItems: tally) { item in
                        MapAnnotation(coordinate: CLLocationCoordinate2D(latitude: item.country.latitude,
                                                                         longitude: item.country.longitude)) {
                            let size = 10 + 26 * sqrt(Double(item.books) / Double(most))
                            Circle().fill(Color.orange.opacity(0.75))
                                .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1))
                                .frame(width: size, height: size)
                                .help("\(item.country.displayName): \(item.books)")
                        }
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(tally) { item in
                                HStack {
                                    Text("\(item.country.flag) \(item.country.displayName)").appFont(size: 12).lineLimit(1)
                                    Spacer()
                                    Text("\(item.books)").appFont(size: 12).foregroundStyle(.secondary)
                                }
                                .help(item.authors.joined(separator: ", "))
                            }
                        }
                    }
                    .frame(width: 190, height: 220)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18)
        .task { await model.loadAuthorCountries(lookUp: false) }
    }
}
