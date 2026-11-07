import SwiftUI

/// Someone on Wikidata — an author, or whoever influenced one.
struct InfluencePerson: Codable, Sendable, Hashable, Identifiable {
    /// The Wikidata id, e.g. "Q34670".
    let id: String
    let name: String
    let about: String?
}

/// Who influenced whom, from Wikidata's "influenced by" (P737). No key
/// needed; answers are saved for months.
enum AuthorInfluences {
    private static let ttl: TimeInterval = 180 * 24 * 3600

    /// An author of yours on Wikidata, with who influenced them.
    struct Resolved: Codable, Sendable, Equatable {
        let id: String
        let influencedBy: [String]
    }

    /// Already known, without asking. Outer nil: never asked.
    static func saved(_ author: String) async -> Resolved?? {
        guard let hit = await DataCache.shared.read(Resolved?.self, "author-influences", author.lowercased(), ttl: ttl),
              !hit.isStale else { return nil }
        return .some(hit.value)
    }

    /// The author's Wikidata entry and influences. Nil when Wikidata has no
    /// such writer; throws when it couldn't be asked (then nothing is saved).
    static func resolve(_ author: String) async throws -> Resolved? {
        if let saved = await saved(author) { return saved }
        var found: Resolved?
        if let (id, claims) = try await AuthorCountries.person(named: author) {
            found = Resolved(id: id, influencedBy: AuthorCountries.entityIDs(claims["P737"]))
        }
        await DataCache.shared.write(found, "author-influences", author.lowercased())
        return found
    }

    /// Who influenced anyone on Wikidata, by id.
    static func influencedBy(id: String) async throws -> [String] {
        if let hit = await DataCache.shared.read([String].self, "wikidata-influenced-by", id, ttl: ttl), !hit.isStale {
            return hit.value
        }
        let ids = AuthorCountries.entityIDs(try await AuthorCountries.entity(id)?.claims["P737"])
        await DataCache.shared.write(ids, "wikidata-influenced-by", id)
        return ids
    }

    /// Everyone who names `id` among their influences — the other way round,
    /// found with Wikidata's search.
    static func influenced(id: String) async throws -> [String] {
        if let hit = await DataCache.shared.read([String].self, "wikidata-influenced", id, ttl: ttl), !hit.isStale {
            return hit.value
        }
        guard let url = AuthorCountries.api(["action": "query", "list": "search",
                                             "srsearch": "haswbstatement:P737=\(id)", "srlimit": "60"]) else { return [] }
        let data = try await AuthorCountries.get(url)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hits = ((json?["query"] as? [String: Any])?["search"] as? [[String: Any]]) ?? []
        let ids = hits.compactMap { $0["title"] as? String }.filter { $0.hasPrefix("Q") }
        await DataCache.shared.write(ids, "wikidata-influenced", id)
        return ids
    }

    /// Names and one-line descriptions, in Portuguese when there is one —
    /// fifty to a request, and saved.
    static func people(_ ids: [String]) async -> [String: InfluencePerson] {
        var found: [String: InfluencePerson] = [:]
        var missing: [String] = []
        for id in Set(ids) {
            if let hit = await DataCache.shared.read(InfluencePerson.self, "wikidata-person", id, ttl: ttl), !hit.isStale {
                found[id] = hit.value
            } else {
                missing.append(id)
            }
        }
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        for start in stride(from: 0, to: missing.count, by: 50) {
            let batch = Array(missing[start..<min(start + 50, missing.count)])
            guard let url = AuthorCountries.api(["action": "wbgetentities", "ids": batch.joined(separator: "|"),
                                                 "props": "labels|descriptions", "languages": "\(language)|en",
                                                 "languagefallback": "1"]),
                  let data = try? await AuthorCountries.get(url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entities = json["entities"] as? [String: Any] else { continue }
            for id in batch {
                guard let entity = entities[id] as? [String: Any] else { continue }
                func text(_ field: String) -> String? {
                    let values = entity[field] as? [String: Any]
                    return ((values?[language] ?? values?["en"]) as? [String: Any])?["value"] as? String
                }
                guard let name = text("labels") else { continue }
                let person = InfluencePerson(id: id, name: name, about: text("descriptions"))
                found[id] = person
                await DataCache.shared.write(person, "wikidata-person", id)
            }
        }
        return found
    }

    /// One person with who came before and after them.
    struct Links: Sendable, Equatable {
        let center: InfluencePerson
        let before: [InfluencePerson]
        let after: [InfluencePerson]
    }

    static func links(for person: InfluencePerson) async throws -> Links {
        async let before = influencedBy(id: person.id)
        async let after = influenced(id: person.id)
        let (b, a) = try await (before, after)
        let names = await people(b + a)
        let sort: ([String]) -> [InfluencePerson] = { ids in
            ids.compactMap { names[$0] }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        return Links(center: person, before: sort(b), after: sort(a))
    }

    /// "Kafka influenced 4 of your authors, and you've never read him."
    struct Discovery: Identifiable, Sendable, Equatable {
        let person: InfluencePerson
        /// Your authors they influenced.
        let influencedYours: [String]
        var id: String { person.id }
    }

    /// Two authors you've read, one an influence on the other.
    struct Bridge: Identifiable, Sendable, Equatable {
        let from: String
        let to: String
        var id: String { from + "→" + to }
    }

    /// From your authors' influences: the ones you haven't read, by how many
    /// of yours they shaped, and the links between authors you have read.
    static func map(yours: [String: Resolved], people: [String: InfluencePerson])
        -> (discoveries: [Discovery], bridges: [Bridge]) {
        let yourIDs = Dictionary(yours.map { ($0.value.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        var shaped: [String: [String]] = [:]
        var bridges: [Bridge] = []
        for (author, resolved) in yours.sorted(by: { $0.key < $1.key }) {
            for id in Set(resolved.influencedBy) {
                if let yourAuthor = yourIDs[id] ?? people[id].flatMap({ person in
                    yours.keys.first { AuthorWikipedia.sameName($0, person.name) }
                }) {
                    if yourAuthor != author { bridges.append(Bridge(from: yourAuthor, to: author)) }
                } else {
                    shaped[id, default: []].append(author)
                }
            }
        }
        var discoveries: [Discovery] = []
        for (id, authors) in shaped {
            guard let person = people[id] else { continue }
            discoveries.append(Discovery(person: person, influencedYours: authors.sorted()))
        }
        discoveries.sort { a, b in
            if a.influencedYours.count != b.influencedYours.count {
                return a.influencedYours.count > b.influencedYours.count
            }
            return a.person.name.localizedCompare(b.person.name) == .orderedAscending
        }
        return (discoveries, bridges)
    }
}

/// Your authors' influences, worked out in the background and kept while
/// the app runs.
@MainActor
final class InfluenceAtlas: ObservableObject {
    static let shared = InfluenceAtlas()

    struct YourAuthor: Identifiable, Equatable {
        let name: String
        let books: Int
        var person: InfluencePerson?
        var id: String { name }
    }

    @Published private(set) var authors: [YourAuthor] = []
    @Published private(set) var discoveries: [AuthorInfluences.Discovery] = []
    @Published private(set) var bridges: [AuthorInfluences.Bridge] = []
    @Published private(set) var isLoading = false
    @Published private(set) var left = 0
    /// Your authors' Wikidata ids, by name.
    private(set) var resolved: [String: AuthorInfluences.Resolved] = [:]

    /// Whether `name` is someone you've read.
    func isYours(_ person: InfluencePerson) -> Bool {
        resolved.values.contains { $0.id == person.id }
            || authors.contains { AuthorWikipedia.sameName($0.name, person.name) }
    }

    func books(by person: InfluencePerson) -> Int {
        authors.first { $0.person?.id == person.id || AuthorWikipedia.sameName($0.name, person.name) }?.books ?? 0
    }

    /// Whether an author of yours influenced another of your authors, or is
    /// one of the influences you haven't read — for the bingo.
    func isInfluence(_ author: String) -> Bool {
        let all = Set(resolved.values.flatMap(\.influencedBy))
        if let id = resolved[author]?.id, all.contains(id) { return true }
        return discoveries.contains { AuthorWikipedia.sameName($0.person.name, author) }
    }

    /// Works out the map. Authors not looked up yet are looked up on
    /// Wikidata, unless `lookUp` is false (then only saved answers count).
    func load(lookUp: Bool = true) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let read = ShelfCache.read(.read)?.entries ?? []
        let counts = Dictionary(grouping: read.filter { !$0.author.isEmpty }, by: \.author).mapValues(\.count)
        authors = counts.map { YourAuthor(name: $0.key, books: $0.value) }
            .sorted { $0.books != $1.books ? $0.books > $1.books : $0.name < $1.name }

        var missing: [String] = []
        for author in authors {
            switch await AuthorInfluences.saved(author.name) {
            case .some(.some(let found)): resolved[author.name] = found
            case .some(.none): break
            case .none: missing.append(author.name)
            }
        }
        await refresh()
        guard lookUp else { return }
        left = missing.count
        if !missing.isEmpty {
            Diagnostics.shared.log("influences", "looking up \(missing.count) of \(authors.count) authors on Wikidata")
        }
        for (index, author) in missing.enumerated() where !Task.isCancelled {
            if let found = try? await AuthorInfluences.resolve(author) { resolved[author] = found }
            left = missing.count - index - 1
            if index % 8 == 7 || left == 0 { await refresh() }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func refresh() async {
        let ids = resolved.values.flatMap { [$0.id] + $0.influencedBy }
        let people = await AuthorInfluences.people(ids)
        authors = authors.map { author in
            var author = author
            author.person = resolved[author.name].flatMap { people[$0.id] }
            return author
        }
        (discoveries, bridges) = AuthorInfluences.map(yours: resolved, people: people)
        if !discoveries.isEmpty {
            Diagnostics.shared.log("influences", "\(discoveries.count) influences you haven't read, \(bridges.count) links between yours")
        }
    }
}
