import SwiftUI

/// A small JSON file of the app's own under Application Support — for
/// things that aren't a cache and mustn't go when the cache is cleared.
enum SavedFile {
    static func url(_ name: String) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoodreadsGUI", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name + ".json")
    }

    static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }
}

/// One square of the year's bingo card.
enum BingoSquare: Codable, Sendable, Hashable {
    case newCountry
    case continent(String)
    case olderThan(Int)
    case recent
    case longerThan(Int)
    case shorterThan(Int)
    case obscure(Int)
    case blockbuster(Int)
    case genre(String)
    case passedGenre(String, Int)
    case waitedYears(Int)
    case fromDiscover
    case newAuthor
    case lowRated(Double)
    case influence
    case seriesNext

    /// Squares of one family — only one or two of each go on a card.
    var family: String {
        switch self {
        case .continent: "continent"
        case .olderThan: "old"
        case .genre, .passedGenre: "genre"
        case .longerThan, .shorterThan: "length"
        case .obscure, .blockbuster: "fame"
        default: "\(self)"
        }
    }

    var title: String {
        switch self {
        case .newCountry: String(localized: "An author from a country you’ve never read")
        case .continent(let code): String(localized: "An author from \(Bingo.continentName(code))")
        case .olderThan(1950): String(localized: "Older than your grandparents (before 1950)")
        case .olderThan(let year): String(localized: "Written before \(String(year))")
        case .recent: String(localized: "Came out this year or last")
        case .longerThan(let pages): String(localized: "Over \(pages) pages")
        case .shorterThan(let pages): String(localized: "Under \(pages) pages")
        case .obscure(let count): String(localized: "Fewer than \(count.formatted()) ratings on Goodreads")
        case .blockbuster: String(localized: "Read by everyone (500,000+ ratings)")
        case .genre(let genre): Bingo.genreName(genre)
        case .passedGenre(let genre, _): Bingo.genreName(genre)
        case .waitedYears(let years): String(localized: "On your shelves for \(years)+ years")
        case .fromDiscover: String(localized: "One you ♥’d in Discover")
        case .newAuthor: String(localized: "An author new to you")
        case .lowRated(let rating): String(localized: "Rated under \(String(format: "%.1f", rating)) — prove them wrong")
        case .influence: String(localized: "An author who shaped one of yours")
        case .seriesNext: String(localized: "The next book in one of your series")
        }
    }

    var subtitle: String? {
        switch self {
        case .genre: String(localized: "a genre you almost never read")
        case .passedGenre(_, let count): String(localized: "you passed \(count) in Discover")
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .newCountry: "globe.europe.africa"
        case .continent: "map"
        case .olderThan: "hourglass"
        case .recent: "sparkles"
        case .longerThan: "books.vertical"
        case .shorterThan: "book.closed"
        case .obscure: "eye.slash"
        case .blockbuster: "person.3"
        case .genre, .passedGenre: "theatermasks"
        case .waitedYears: "clock.arrow.circlepath"
        case .fromDiscover: "heart"
        case .newAuthor: "person.badge.plus"
        case .lowRated: "hand.thumbsdown"
        case .influence: "point.3.connected.trianglepath.dotted"
        case .seriesNext: "list.number"
        }
    }
}

/// What the bingo needs to know about one book.
struct BingoFacts: Sendable, Equatable {
    let bookID: String
    let title: String
    let author: String
    let cover: URL?
    let dateRead: Date?
    var countryCode: String? = nil
    var newCountry: Bool? = nil
    var published: Int? = nil
    var pages: Int? = nil
    var ratingsCount: Int? = nil
    var rating: Double? = nil
    var genres: [String] = []
    var waitedYears: Double? = nil
    var fromDiscover = false
    var newAuthor: Bool? = nil
    var influence = false
    var inSeries = false

    var readYear: Int? { dateRead.map { Calendar.current.component(.year, from: $0) } }
}

/// A card: sixteen squares in a 4×4 grid, and the ones you ticked yourself.
struct BingoCard: Codable, Sendable, Equatable {
    let year: Int
    var squares: [BingoSquare]
    var marked: [Int] = []
}

enum Bingo {
    static let size = 4

    // MARK: Matching

    /// Whether a book fills a square; nil when the book's data doesn't say.
    static func matches(_ square: BingoSquare, _ book: BingoFacts) -> Bool? {
        switch square {
        case .newCountry: return book.newCountry
        case .continent(let code): return book.countryCode.map { continent(of: $0) == code }
        case .olderThan(let year): return book.published.map { $0 < year }
        case .recent:
            guard let published = book.published, let read = book.readYear ?? Optional(Calendar.current.component(.year, from: Date()))
            else { return nil }
            return published >= read - 1
        case .longerThan(let pages): return book.pages.map { $0 > pages }
        case .shorterThan(let pages): return book.pages.map { $0 < pages }
        case .obscure(let count): return book.ratingsCount.map { $0 < count }
        case .blockbuster(let count): return book.ratingsCount.map { $0 > count }
        case .genre(let genre), .passedGenre(let genre, _):
            return book.genres.isEmpty ? nil : has(genre, in: book.genres)
        case .waitedYears(let years): return book.waitedYears.map { $0 >= Double(years) }
        case .fromDiscover: return book.fromDiscover
        case .newAuthor: return book.newAuthor
        case .lowRated(let rating): return book.rating.map { $0 < rating }
        case .influence: return book.influence
        case .seriesNext: return book.inSeries
        }
    }

    /// Goodreads' genre names, with the ones that mean the same thing.
    static let genreAliases: [String: [String]] = [
        "Poetry": ["Poetry"],
        "Plays": ["Plays", "Drama", "Theatre"],
        "Graphic Novels": ["Graphic Novels", "Comics", "Manga", "Graphic Novels Comics"],
        "Science Fiction": ["Science Fiction", "Dystopia", "Space Opera", "Cyberpunk"],
        "Horror": ["Horror"],
        "Biography": ["Biography", "Biography Memoir"],
        "Philosophy": ["Philosophy"],
        "Fantasy": ["Fantasy", "High Fantasy", "Epic Fantasy"],
        "Mystery": ["Mystery", "Crime", "Thriller", "Mystery Thriller", "Detective"],
        "Romance": ["Romance"],
        "History": ["History"],
        "Science": ["Science", "Popular Science", "Physics", "Biology"],
        "Essays": ["Essays"],
        "Short Stories": ["Short Stories"],
        "Travel": ["Travel"],
        "Memoir": ["Memoir", "Autobiography"],
        "Classics": ["Classics"],
        "Nonfiction": ["Nonfiction"],
        "Humor": ["Humor", "Comedy"],
        "Mythology": ["Mythology"],
        "Young Adult": ["Young Adult"],
        "Magical Realism": ["Magical Realism"],
    ]

    static func has(_ genre: String, in genres: [String]) -> Bool {
        let names = Set((genreAliases[genre] ?? [genre]).map { $0.lowercased() })
        return genres.contains { names.contains($0.lowercased()) }
    }

    static func genreName(_ genre: String) -> String {
        GenreNames.display(genre)
    }

    // MARK: Continents

    private static let continents: [String: Set<String>] = [
        "AF": ["DZ", "AO", "BJ", "BW", "BF", "BI", "CV", "CM", "CF", "TD", "KM", "CG", "CD", "CI", "DJ", "EG", "GQ", "ER",
               "SZ", "ET", "GA", "GM", "GH", "GN", "GW", "KE", "LS", "LR", "LY", "MG", "MW", "ML", "MR", "MU", "MA",
               "MZ", "NA", "NE", "NG", "RW", "ST", "SN", "SC", "SL", "SO", "ZA", "SS", "SD", "TZ", "TG", "TN", "UG",
               "ZM", "ZW"],
        "AS": ["AF", "AM", "AZ", "BH", "BD", "BT", "BN", "KH", "CN", "GE", "IN", "ID", "IR", "IQ", "IL", "JP", "JO", "KZ",
               "KW", "KG", "LA", "LB", "MY", "MV", "MN", "MM", "NP", "KP", "OM", "PK", "PS", "PH", "QA", "SA", "SG",
               "KR", "LK", "SY", "TW", "TJ", "TH", "TL", "TR", "TM", "AE", "UZ", "VN", "YE", "HK", "MO"],
        "SA": ["AR", "BO", "BR", "CL", "CO", "EC", "GY", "PY", "PE", "SR", "UY", "VE"],
        "NA": ["US", "CA", "MX", "GT", "BZ", "HN", "SV", "NI", "CR", "PA", "CU", "DO", "HT", "JM", "TT", "BS", "BB", "PR"],
        "OC": ["AU", "NZ", "FJ", "PG", "WS", "TO"],
    ]

    /// "AF", "AS", "SA", "NA", "OC" or "EU" for a country code.
    static func continent(of code: String) -> String {
        continents.first { $0.value.contains(code.uppercased()) }?.key ?? "EU"
    }

    static func continentName(_ code: String) -> String {
        switch code {
        case "AF": String(localized: "Africa")
        case "AS": String(localized: "Asia")
        case "SA": String(localized: "South America")
        case "NA": String(localized: "North or Central America")
        case "OC": String(localized: "Oceania")
        default: String(localized: "Europe")
        }
    }

    // MARK: Making a card

    /// How often a square happened in the books you read before: nil when
    /// too few of them say.
    static func share(_ square: BingoSquare, in past: [BingoFacts]) -> Double? {
        let known = past.compactMap { matches(square, $0) }
        guard known.count >= 5 else { return nil }
        return Double(known.filter { $0 }.count) / Double(known.count)
    }

    /// A card from your gaps: the squares you've done least, a few of each
    /// family, in an order that's the same all year (it's saved anyway).
    static func makeCard(year: Int, past: [BingoFacts], passedGenres: [(String, Int)],
                         hasInfluences: Bool, hasSeries: Bool, seed: UInt64) -> BingoCard {
        var candidates: [BingoSquare] = [.newCountry, .olderThan(1900), .olderThan(1950), .recent,
                                         .longerThan(500), .shorterThan(150), .obscure(1000), .blockbuster(500_000),
                                         .waitedYears(3), .lowRated(3.6)]
        candidates += ["AF", "AS", "SA", "NA", "OC"].map { BingoSquare.continent($0) }
        candidates += genreAliases.keys.sorted().map { BingoSquare.genre($0) }

        var rng = SeededRandom(seed: seed)
        // Squares that are new to you anyway, so they always go on.
        var picked: [BingoSquare] = [.fromDiscover, .newAuthor]
        if hasInfluences { picked.append(.influence) }
        if hasSeries { picked.append(.seriesNext) }
        if let (genre, count) = passedGenres.first, count >= 3 {
            picked.append(.passedGenre(genre, count))
            candidates.removeAll { $0 == .genre(genre) }
        }

        let limits = ["genre": 4, "continent": 2, "old": 1, "length": 1, "fame": 1]
        let ranked = candidates
            .map { ($0, share($0, in: past) ?? 0.2, Double.random(in: 0..<0.04, using: &rng)) }
            .sorted { $0.1 + $0.2 < $1.1 + $1.2 }
            .map(\.0)
        for square in ranked where picked.count < size * size {
            let family = picked.filter { $0.family == square.family }.count
            if family < (limits[square.family] ?? 1) { picked.append(square) }
        }
        // Not enough families: fill with whatever's left, rarest first.
        for square in ranked where picked.count < size * size && !picked.contains(square) {
            picked.append(square)
        }
        picked.shuffle(using: &rng)
        return BingoCard(year: year, squares: picked)
    }

    /// Rows, columns and diagonals all done.
    static func lines(done: Set<Int>) -> [[Int]] {
        var all: [[Int]] = []
        for row in 0..<size { all.append((0..<size).map { row * size + $0 }) }
        for column in 0..<size { all.append((0..<size).map { $0 * size + column }) }
        all.append((0..<size).map { $0 * size + $0 })
        all.append((0..<size).map { $0 * size + (size - 1 - $0) })
        return all.filter { $0.allSatisfy(done.contains) }
    }
}

/// The same "random" every time for the same seed.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Facts from the library

extension LibraryModel {
    /// Facts for every book on Read, oldest first, and for Want to Read.
    func bingoFacts(fetchMissingFor year: Int? = nil) async -> (read: [BingoFacts], wanted: [BingoFacts]) {
        let read = (ShelfCache.read(.read)?.entries ?? []).sorted {
            (Suggestions.parseDate($0.dateRead ?? "") ?? .distantPast) < (Suggestions.parseDate($1.dateRead ?? "") ?? .distantPast)
        }
        // This year's books need a publication year: a few book pages are
        // asked for, gently, when they aren't saved yet.
        if let year {
            var asked = 0
            for entry in read where asked < 6 {
                guard let date = Suggestions.parseDate(entry.dateRead ?? ""),
                      Calendar.current.component(.year, from: date) == year,
                      await DataCache.shared.read(GoodreadsBookPage.Detail.self, "book-page", entry.bookID, ttl: .infinity) == nil
                else { continue }
                if asked > 0 { try? await Task.sleep(for: .seconds(2)) }
                asked += 1
                _ = try? await GoodreadsBookPage.fetch(bookID: entry.bookID)
            }
            if asked > 0 { bookExtras = await BookExtras.all() }
        }

        let swipes = await SwipeHistory.all().filter { $0.verdict == .want }
        let liked = Set(swipes.map(\.key)).union(swipes.compactMap(\.bookID))
        let seriesTitles = Set(seriesProgress.flatMap { series in
            series.volumes.filter { ($0.seriesNumber ?? 1) > 1 }.map { Suggestions.normalizedTitle(SeriesTracker.bareTitle($0.title)) }
        })
        let atlas = InfluenceAtlas.shared

        func facts(_ entry: ShelfEntry) async -> BingoFacts {
            let page = await DataCache.shared.read(GoodreadsBookPage.Detail.self, "book-page", entry.bookID, ttl: .infinity)?.value
            let extras = bookExtras[entry.bookID]
            let dateRead = Suggestions.parseDate(entry.dateRead ?? "")
            var book = BingoFacts(bookID: entry.bookID, title: entry.title, author: entry.author,
                                  cover: entry.coverURL, dateRead: dateRead)
            book.countryCode = authorCountryMap[entry.author]?.code
            book.published = (page?.about?.firstPublished ?? page?.about?.published)
                .map { Calendar.current.component(.year, from: $0) }
            book.pages = extras?.pages ?? page?.pageCount
            book.ratingsCount = extras?.ratingsCount ?? page?.about?.ratingsCount
            book.rating = extras?.rating ?? page?.about?.averageRating
            book.genres = extras?.genres.isEmpty == false ? extras!.genres : (page?.genres ?? [])
            if let added = Suggestions.parseDate(entry.dateAdded ?? "") {
                book.waitedYears = (dateRead ?? Date()).timeIntervalSince(added) / (365.25 * 24 * 3600)
            }
            book.fromDiscover = liked.contains(entry.bookID) || liked.contains(Candidate.key(entry.title))
            book.influence = atlas.isInfluence(entry.author)
            book.inSeries = seriesTitles.contains(Suggestions.normalizedTitle(SeriesTracker.bareTitle(entry.title)))
            return book
        }

        var readFacts: [BingoFacts] = []
        var seenAuthors: Set<String> = []
        var seenCountries: Set<String> = []
        for entry in read {
            var book = await facts(entry)
            book.newAuthor = !seenAuthors.contains(entry.author.lowercased())
            seenAuthors.insert(entry.author.lowercased())
            if let code = book.countryCode {
                book.newCountry = !seenCountries.contains(code)
                seenCountries.insert(code)
            }
            readFacts.append(book)
        }
        var wanted: [BingoFacts] = []
        for entry in ShelfCache.read(.wantToRead)?.entries ?? [] {
            var book = await facts(entry)
            book.newAuthor = !seenAuthors.contains(entry.author.lowercased())
            book.newCountry = book.countryCode.map { !seenCountries.contains($0) }
            wanted.append(book)
        }
        return (readFacts, wanted)
    }
}

// MARK: - Pane

struct BingoPane: View {
    @ObservedObject var model: LibraryModel
    @State private var card: BingoCard?
    @State private var read: [BingoFacts] = []
    @State private var wanted: [BingoFacts] = []
    @State private var selected: Int?
    @State private var isLoading = true
    @State private var confirmNew = false

    private let year = Calendar.current.component(.year, from: Date())

    private var thisYear: [BingoFacts] { read.filter { $0.readYear == year } }

    /// The book that filled each square, if one did.
    private var filledBy: [Int: BingoFacts] {
        guard let card else { return [:] }
        var result: [Int: BingoFacts] = [:]
        for (index, square) in card.squares.enumerated() {
            if let book = thisYear.first(where: { Bingo.matches(square, $0) == true }) { result[index] = book }
        }
        return result
    }

    private var done: Set<Int> {
        Set(filledBy.keys).union(card?.marked ?? [])
    }

    var body: some View {
        Group {
            if let card {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(card)
                        grid(card)
                        Text("Built from what you rarely read. Squares fill themselves as you finish books this year; click one for ideas, or to tick it yourself.")
                            .appFont(size: 11).foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Shuffling your card…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Bingo")
        .task { await load() }
        .confirmationDialog("Deal a new card?", isPresented: $confirmNew) {
            Button("New Card") { Task { await load(fresh: true) } }
        } message: {
            Text("Squares you ticked yourself are cleared.")
        }
    }

    private func header(_ card: BingoCard) -> some View {
        let lines = Bingo.lines(done: done)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Bingo \(String(card.year))").appFont(size: 22, weight: .bold, design: .rounded)
                Text("\(done.count) of \(card.squares.count) · \(thisYear.count) books read this year")
                    .appFont(size: 12).foregroundStyle(.secondary)
            }
            if !lines.isEmpty {
                Text(lines.count == 1 ? "BINGO!" : "BINGO ×\(lines.count)!")
                    .appFont(size: 18, weight: .heavy, design: .rounded)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .overlay(Capsule().stroke(Color.orange, lineWidth: 2))
                    .rotationEffect(.degrees(-4))
            }
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
            Button { confirmNew = true } label: { Label("New Card", systemImage: "shuffle") }
                .help("Deal a new card from your gaps")
        }
    }

    private func grid(_ card: BingoCard) -> some View {
        let lines = Set(Bingo.lines(done: done).flatMap { $0 })
        let filled = filledBy
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: Bingo.size), spacing: 10) {
            ForEach(Array(card.squares.enumerated()), id: \.offset) { index, square in
                squareView(square, index: index, book: filled[index], isDone: done.contains(index), inLine: lines.contains(index))
            }
        }
    }

    private func squareView(_ square: BingoSquare, index: Int, book: BingoFacts?, isDone: Bool, inLine: Bool) -> some View {
        Button { selected = index } label: {
            VStack(spacing: 6) {
                Image(systemName: isDone ? "checkmark.circle.fill" : square.symbol)
                    .appFont(size: 18)
                    .foregroundStyle(isDone ? Color.green : Color.accentColor)
                Text(square.title)
                    .appFont(size: 11, weight: .semibold)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if let subtitle = square.subtitle {
                    Text(subtitle).appFont(size: 9).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let book {
                    HStack(spacing: 4) {
                        CachedAsyncImage(url: book.cover) { phase in
                            if case .success(let image) = phase { image.resizable().aspectRatio(contentMode: .fill) }
                            else { Color.secondary.opacity(0.2) }
                        }
                        .frame(width: 16, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        Text(book.title).appFont(size: 9).lineLimit(1).foregroundStyle(.secondary)
                    }
                } else if isDone {
                    Text("Ticked").appFont(size: 9).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(RoundedRectangle(cornerRadius: 14).fill(isDone ? Color.green.opacity(0.14) : Color.secondary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(inLine ? Color.orange : Color.secondary.opacity(0.15),
                                                               lineWidth: inLine ? 2.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { selected == index }, set: { if !$0 { selected = nil } })) {
            squareDetail(square, index: index, book: book)
        }
    }

    private func squareDetail(_ square: BingoSquare, index: Int, book: BingoFacts?) -> some View {
        let past = read.filter { $0.readYear != year }
        let share = Bingo.share(square, in: past)
        let ideas = wanted.filter { Bingo.matches(square, $0) == true }.prefix(4)
        let marked = card?.marked.contains(index) ?? false
        return VStack(alignment: .leading, spacing: 10) {
            Label(square.title, systemImage: square.symbol).appFont(size: 13, weight: .semibold)
            if let share {
                Text(share == 0 ? String(localized: "You’ve never done this.")
                     : String(localized: "Only \(Int((share * 100).rounded()))% of the books you’ve read so far."))
                    .appFont(size: 11).foregroundStyle(.secondary)
            }
            if let book {
                Text("Filled by \(book.title)").appFont(size: 12, weight: .medium).foregroundStyle(.green)
            } else if !ideas.isEmpty {
                Text("From your Want to Read:").appFont(size: 11, weight: .medium)
                ForEach(Array(ideas), id: \.bookID) { idea in
                    Button {
                        selected = nil
                        if let entry = ShelfCache.read(.wantToRead)?.entries.first(where: { $0.bookID == idea.bookID }) {
                            model.showBookDetail(entry.asBook)
                        }
                    } label: {
                        Text("· \(idea.title) — \(idea.author)").lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .appFont(size: 11)
                }
            } else {
                Text("Nothing on your Want to Read fits yet — a job for Discover.")
                    .appFont(size: 11).foregroundStyle(.secondary)
            }
            if book == nil {
                Button(marked ? String(localized: "Untick") : String(localized: "Tick It Myself")) {
                    guard var updated = card else { return }
                    if marked { updated.marked.removeAll { $0 == index } } else { updated.marked.append(index) }
                    card = updated
                    SavedFile.write(updated, "bingo-\(year)")
                }
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private func load(fresh: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        // "An author who shaped one of yours" fills in once this is done.
        Task { await InfluenceAtlas.shared.load() }
        if !fresh, card == nil, let saved = SavedFile.read(BingoCard.self, "bingo-\(year)") { card = saved }
        if model.authorCountryMap.isEmpty { await model.loadAuthorCountries(lookUp: false) }
        if model.seriesProgress.isEmpty { await model.loadSeries() }
        let facts = await model.bingoFacts(fetchMissingFor: year)
        read = facts.read
        wanted = facts.wanted
        guard fresh || card == nil else { return }

        let past = read.filter { ($0.readYear ?? 0) < year }
        let swipes = await SwipeHistory.all().filter { $0.verdict == .pass }
        var passed: [String: Int] = [:]
        for swipe in swipes {
            for genre in Bingo.genreAliases.keys where Bingo.has(genre, in: swipe.genres) { passed[genre, default: 0] += 1 }
        }
        let seed = fresh ? UInt64.random(in: 0...UInt64.max) : UInt64(year)
        let made = Bingo.makeCard(year: year, past: past,
                                  passedGenres: passed.sorted { $0.value > $1.value }.map { ($0.key, $0.value) },
                                  hasInfluences: true,
                                  hasSeries: !model.seriesProgress.isEmpty, seed: seed)
        card = made
        SavedFile.write(made, "bingo-\(year)")
    }
}
