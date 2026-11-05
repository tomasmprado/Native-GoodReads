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

    func load() async {
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

// MARK: - Pane

struct InfluencesPane: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var atlas = InfluenceAtlas.shared
    @State private var trail: [InfluencePerson] = []
    @State private var links: AuthorInfluences.Links?
    @State private var isLoadingLinks = false
    @State private var failed = false

    var body: some View {
        HStack(spacing: 0) {
            authorList
                .frame(width: 220)
            Divider()
            Group {
                if let person = trail.last {
                    graph(for: person)
                } else {
                    overview
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Influences")
        .task { await atlas.load() }
        .task(id: trail.last?.id) { await loadLinks() }
    }

    // MARK: Your authors

    private var authorList: some View {
        List {
            Button { trail = [] } label: {
                Label("Influences you’re missing", systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(.plain)
            .foregroundStyle(trail.isEmpty ? Color.accentColor : .primary)
            Section("Your authors") {
                ForEach(atlas.authors) { author in
                    Button {
                        if let person = author.person { trail = [person] }
                    } label: {
                        HStack {
                            Text(author.name).lineLimit(1)
                                .foregroundStyle(author.person == nil ? .secondary : .primary)
                            Spacer()
                            Text("\(author.books)").appFont(size: 10).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(author.person == nil)
                    .help(author.person?.about ?? String(localized: "Not found on Wikidata"))
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Overview

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Influences you’re missing").appFont(size: 20, weight: .semibold)
                    Text("Writers who shaped the authors you read — and whom you’ve never read.")
                        .appFont(size: 12).foregroundStyle(.secondary)
                    if atlas.left > 0 {
                        Label("Asking Wikidata about \(atlas.left) more authors…", systemImage: "hourglass")
                            .appFont(size: 11).foregroundStyle(.secondary)
                    }
                }
                if atlas.discoveries.isEmpty {
                    Text(atlas.isLoading ? String(localized: "Looking…") : String(localized: "Wikidata doesn’t list influences for your authors yet."))
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                        ForEach(atlas.discoveries.prefix(30)) { discovery in
                            discoveryCard(discovery)
                        }
                    }
                }
                if !atlas.bridges.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Links between your authors").appFont(size: 15, weight: .semibold)
                        ForEach(atlas.bridges.prefix(20)) { bridge in
                            HStack(spacing: 6) {
                                Text(bridge.from).fontWeight(.medium)
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                Text(bridge.to).fontWeight(.medium)
                            }
                            .appFont(size: 12)
                        }
                        Text("The first shaped the second — and you’ve read both.")
                            .appFont(size: 11).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
        }
    }

    private func discoveryCard(_ discovery: AuthorInfluences.Discovery) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(discovery.person.name).appFont(size: 14, weight: .semibold).lineLimit(1)
            if let about = discovery.person.about {
                Text(about).appFont(size: 11).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("Shaped \(ListFormatter.localizedString(byJoining: Array(discovery.influencedYours.prefix(3))))")
                .appFont(size: 11, weight: .medium)
                .foregroundStyle(Color.accentColor)
                .lineLimit(2)
            Spacer(minLength: 0)
            HStack {
                Button("Explore") { trail = [discovery.person] }
                Button("Find Books") { search(discovery.person.name) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .glassCard(cornerRadius: 14)
    }

    // MARK: Graph

    private func graph(for person: InfluencePerson) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if trail.count > 1 {
                    Button { trail.removeLast() } label: { Label("Back", systemImage: "chevron.left") }
                }
                Text(person.name).appFont(size: 20, weight: .semibold)
                Spacer()
                if !atlas.isYours(person) {
                    Button("Find Books") { search(person.name) }
                }
            }
            if let line = headline {
                Label(line, systemImage: "lightbulb").appFont(size: 12).foregroundStyle(.secondary)
            }
            if let links, links.center.id == person.id {
                ScrollView {
                    InfluenceGraph(links: links, isYours: atlas.isYours, books: atlas.books(by:)) { next in
                        if next.id != person.id { trail.append(next) }
                    }
                    .padding(.vertical, 8)
                }
                HStack(spacing: 14) {
                    legendDot(Color.accentColor, String(localized: "You’ve read them"))
                    legendDot(Color.secondary.opacity(0.4), String(localized: "Not yet"))
                    Text("Left: influenced by · Right: influenced").foregroundStyle(.tertiary)
                }
                .appFont(size: 10)
            } else if failed {
                Text("Couldn’t reach Wikidata.").foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }

    /// "You've read Saramago. He was influenced by Kafka — and you've never read Kafka."
    private var headline: String? {
        guard let links else { return nil }
        let center = links.center
        let read = atlas.isYours(center)
        if read, let unread = links.before.first(where: { !atlas.isYours($0) }) {
            return String(localized: "You’ve read \(center.name). \(unread.name) shaped them — and you’ve never read \(unread.name).")
        }
        if read, let unread = links.after.first(where: { !atlas.isYours($0) }) {
            return String(localized: "\(center.name) shaped \(unread.name), whom you haven’t read yet.")
        }
        if !read, let yours = links.after.filter(atlas.isYours).first {
            return String(localized: "You’ve never read \(center.name), but they shaped \(yours.name), whom you have.")
        }
        return nil
    }

    private func loadLinks() async {
        guard let person = trail.last else { return }
        failed = false
        if links?.center.id != person.id { links = nil }
        do {
            links = try await AuthorInfluences.links(for: person)
        } catch {
            failed = true
        }
    }

    private func search(_ name: String) {
        model.query = name
        model.selection = .search
        model.searchNow()
    }
}

/// The author in the middle, who shaped them on the left, whom they shaped
/// on the right. Authors you've read light up.
struct InfluenceGraph: View {
    let links: AuthorInfluences.Links
    let isYours: (InfluencePerson) -> Bool
    let books: (InfluencePerson) -> Int
    let select: (InfluencePerson) -> Void

    private static let limit = 16

    var body: some View {
        let before = Array(links.before.prefix(Self.limit))
        let after = Array(links.after.prefix(Self.limit))
        let rows = max(before.count, after.count, 1)
        let height = max(300, CGFloat(rows) * 38 + 40)
        GeometryReader { proxy in
            let width = proxy.size.width
            let center = CGPoint(x: width / 2, y: height / 2)
            let leftX = width * 0.17
            let rightX = width * 0.83
            ZStack {
                lines(before, x: leftX, center: center, height: height, width: width)
                lines(after, x: rightX, center: center, height: height, width: width)
                ForEach(Array(before.enumerated()), id: \.element.id) { index, person in
                    node(person).position(x: leftX, y: Self.y(index, before.count, height))
                }
                ForEach(Array(after.enumerated()), id: \.element.id) { index, person in
                    node(person).position(x: rightX, y: Self.y(index, after.count, height))
                }
                centerNode.position(center)
                if before.isEmpty {
                    Text("No influences listed").appFont(size: 11).foregroundStyle(.tertiary)
                        .position(x: leftX, y: center.y)
                }
                if after.isEmpty {
                    Text("Influenced no one listed").appFont(size: 11).foregroundStyle(.tertiary)
                        .position(x: rightX, y: center.y)
                }
            }
        }
        .frame(height: height)
        .overlay(alignment: .bottom) {
            let hidden = max(0, links.before.count - Self.limit) + max(0, links.after.count - Self.limit)
            if hidden > 0 {
                Text("and \(hidden) more").appFont(size: 10).foregroundStyle(.tertiary)
            }
        }
    }

    private static func y(_ index: Int, _ count: Int, _ height: CGFloat) -> CGFloat {
        count <= 1 ? height / 2 : 24 + CGFloat(index) * (height - 48) / CGFloat(count - 1)
    }

    private func lines(_ people: [InfluencePerson], x: CGFloat, center: CGPoint, height: CGFloat, width: CGFloat) -> some View {
        ZStack {
            ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                Path { path in
                    let start = CGPoint(x: x, y: Self.y(index, people.count, height))
                    let bend = (center.x + x) / 2
                    path.move(to: start)
                    path.addCurve(to: center, control1: CGPoint(x: bend, y: start.y), control2: CGPoint(x: bend, y: center.y))
                }
                .stroke(isYours(person) ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25),
                        lineWidth: isYours(person) ? 2 : 1)
            }
        }
    }

    private func node(_ person: InfluencePerson) -> some View {
        let yours = isYours(person)
        return Button { select(person) } label: {
            HStack(spacing: 4) {
                Text(person.name).lineLimit(1)
                if yours, books(person) > 0 {
                    Text("\(books(person))").appFont(size: 9, weight: .bold).opacity(0.8)
                }
            }
            .appFont(size: 11, weight: yours ? .semibold : .regular)
            .foregroundStyle(yours ? Color.white : Color.primary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: 170)
            .background(Capsule().fill(yours ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
            .overlay(Capsule().stroke(Color.secondary.opacity(yours ? 0 : 0.35)))
        }
        .buttonStyle(.plain)
        .help(person.about ?? person.name)
    }

    private var centerNode: some View {
        let yours = isYours(links.center)
        return VStack(spacing: 2) {
            Text(links.center.name).appFont(size: 15, weight: .bold).lineLimit(1)
            if let about = links.center.about {
                Text(about).appFont(size: 10).lineLimit(1).opacity(0.8)
            }
        }
        .foregroundStyle(yours ? Color.white : Color.primary)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: 220)
        .background(RoundedRectangle(cornerRadius: 14).fill(yours ? Color.accentColor : Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor, lineWidth: 2))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}
