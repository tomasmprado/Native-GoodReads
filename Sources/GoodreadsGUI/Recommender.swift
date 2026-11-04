import Foundation
import NaturalLanguage

/// What you like, worked out from your Read shelf: authors and genres,
/// weighed by how you rated them against your own average and by how
/// recently you read them, minus what you gave up on or swiped away.
struct TasteProfile: Equatable, Sendable {
    var authors: [String: Double] = [:]
    var genres: [String: Double] = [:]
    /// Your favourites, best first, to find books like them.
    var seeds: [(entry: ShelfEntry, weight: Double)] = []

    static func == (a: TasteProfile, b: TasteProfile) -> Bool {
        a.authors == b.authors && a.genres == b.genres && a.seeds.map(\.entry.bookID) == b.seeds.map(\.entry.bookID)
    }

    static func authorKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }.joined(separator: " ")
    }

    static func build(read: [ShelfEntry], extras: [String: BookExtras], abandoned: [AbandonedBook] = [],
                      swipes: [SwipeDecision] = [], now: Date = Date()) -> TasteProfile {
        var profile = TasteProfile()
        let rated = read.compactMap { ($0.rating ?? 0) > 0 ? Double($0.rating!) : nil }
        let mean = rated.isEmpty ? 3.5 : rated.reduce(0, +) / Double(rated.count)

        var seeds: [(ShelfEntry, Double)] = []
        for entry in read {
            // Above your own average is liking it; an unrated read is a mild yes.
            var weight = (entry.rating ?? 0) > 0 ? (Double(entry.rating!) - mean + 0.5) : 0.3
            if let date = Suggestions.parseDate(entry.dateRead ?? "") {
                let years = max(0, now.timeIntervalSince(date) / (365 * 86400))
                weight *= pow(0.5, years / 3)            // halves every three years
            } else {
                weight *= 0.6
            }
            profile.add(author: entry.author, genres: extras[entry.bookID]?.genres ?? [], weight: weight)
            if (entry.rating ?? 0) >= 4 { seeds.append((entry, weight)) }
        }
        for book in abandoned {
            profile.add(author: book.author, genres: extras[book.bookID]?.genres ?? [], weight: -1)
        }
        for swipe in swipes {
            switch swipe.verdict {
            case .want: profile.add(author: swipe.author, genres: swipe.genres, weight: 0.5)
            case .pass: profile.add(author: swipe.author, genres: swipe.genres, weight: -0.35)
            case .read: profile.add(author: swipe.author, genres: swipe.genres, weight: 0.2)
            }
        }
        // Several favourites by one author shouldn't crowd out the rest.
        var perAuthor: [String: Int] = [:]
        profile.seeds = seeds.sorted { $0.1 > $1.1 }.filter { seed in
            let key = authorKey(seed.0.author)
            perAuthor[key, default: 0] += 1
            return perAuthor[key]! <= 2
        }.map { (entry: $0.0, weight: $0.1) }
        return profile
    }

    private mutating func add(author: String, genres: [String], weight: Double) {
        if !author.isEmpty { authors[Self.authorKey(author), default: 0] += weight }
        for genre in genres.filter({ !ReadingStats.ignoredGenres.contains($0) }).prefix(3) {
            self.genres[genre.lowercased(), default: 0] += weight
        }
    }

    func authorAffinity(_ name: String) -> Double { authors[Self.authorKey(name)] ?? 0 }

    /// −1…1: how much the genres sound like yours.
    func genreMatch(_ list: [String]) -> Double? {
        let known = list.prefix(4).map { $0.lowercased() }
        guard !known.isEmpty, let top = genres.values.map(abs).max(), top > 0 else { return nil }
        let total = known.reduce(0) { $0 + (genres[$1] ?? 0) / top }
        return max(-1, min(1, total / Double(known.count)))
    }

    /// Your favourite genres, most loved first.
    var topGenres: [String] {
        genres.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map(\.key)
    }
}

/// A swipe in Discover, remembered so the deck and suggestions learn from it.
struct SwipeDecision: Codable, Sendable, Equatable {
    enum Verdict: String, Codable, Sendable { case want, pass, read }
    let key: String
    let title: String
    let author: String
    var genres: [String] = []
    let verdict: Verdict
    let date: Date
}

enum SwipeHistory {
    private static let namespace = "swipes"
    private static let key = "all"

    static func all() async -> [SwipeDecision] {
        await DataCache.shared.read([SwipeDecision].self, namespace, key, ttl: .infinity)?.value ?? []
    }

    static func add(_ decision: SwipeDecision) async {
        await DataCache.shared.modify([SwipeDecision].self, namespace, key, default: []) { all in
            all.removeAll { $0.key == decision.key }
            all.append(decision)
        }
    }

    static func remove(_ key: String) async {
        await DataCache.shared.modify([SwipeDecision].self, namespace, key, default: []) { all in
            all.removeAll { $0.key == key }
        }
    }
}

/// One possible suggestion and everything that points to it.
struct Candidate: Sendable {
    enum Source: Sendable, Equatable {
        case similar(seed: String, weight: Double)
        case friend(reason: String, weight: Double)
        case author(String)
        case series(String)
        case newRelease(String)
        case genre(String)
    }

    var book: Book
    var sources: [Source] = []
    var genres: [String] = []
    var communityRating: Double?
    var ratingsCount: Int?
    var workID: String?

    static func key(_ title: String) -> String {
        Suggestions.normalizedTitle(SeriesTracker.bareTitle(title))
    }
}

/// A suggestion with its score and the reason shown for it.
struct Recommendation: Codable, Sendable, Identifiable, Equatable {
    let book: Book
    let score: Double
    let reason: String
    var genres: [String] = []
    var communityRating: Double?
    var ratingsCount: Int?
    var id: String { Candidate.key(book.title) }
}

/// Which languages you read in, and a guess at a book's from its description.
enum ReadingLanguages {
    /// Two-letter codes, from the edition languages on your saved book
    /// pages: any with two or more books, or a tenth of them.
    static func codes(of languages: [String]) -> Set<String> {
        var counts: [String: Int] = [:]
        for name in languages {
            let first = name.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if let code = code(for: first) { counts[code, default: 0] += 1 }
        }
        let total = counts.values.reduce(0, +)
        return Set(counts.filter { $0.value >= 2 || Double($0.value) >= Double(total) * 0.1 }.keys)
    }

    static func code(for name: String) -> String? {
        if name.count == 2 { return name }
        let names = ["english": "en", "portuguese": "pt", "spanish": "es", "french": "fr", "german": "de",
                     "italian": "it", "russian": "ru", "dutch": "nl", "catalan": "ca", "galician": "gl",
                     "polish": "pl", "turkish": "tr", "romanian": "ro", "greek": "el", "japanese": "ja",
                     "chinese": "zh", "arabic": "ar", "persian": "fa", "swedish": "sv", "czech": "cs"]
        return names[name]
    }

    /// The language a text is in, when it's clear enough to say.
    static func guess(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence > 0.55 else { return nil }
        return String(language.rawValue.prefix(2))
    }

    /// Whether a book written as `title` (and described by `blurb`) is in
    /// one of `allowed`. Unknown counts as yes; only a clear guess rules out.
    static func fits(title: String, blurb: String?, allowed: Set<String>) -> Bool {
        guard !allowed.isEmpty else { return true }
        if let blurb, blurb.count >= 60, let language = guess(blurb) { return allowed.contains(language) }
        // A title in another alphabet says enough on its own.
        let letters = title.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let latin = letters.filter { $0.value < 0x0250 }
        if !letters.isEmpty, latin.count * 2 < letters.count, let language = guess(title) {
            return allowed.contains(language)
        }
        return true
    }
}

enum Recommender {

    /// Scores every candidate against your taste: what points to it (and how
    /// many things do), how its genres and author sit with you, and how well
    /// readers rate it — then picks a varied list, two books per author at most.
    static func rank(_ candidates: [Candidate], profile: TasteProfile, excluded: Set<String>,
                     excludedWorks: Set<String> = [], limit: Int = 60) -> [Recommendation] {
        var merged: [String: Candidate] = [:]
        for candidate in candidates {
            let key = Candidate.key(candidate.book.title)
            guard !key.isEmpty, !excluded.contains(key) else { continue }
            if let work = candidate.workID, excludedWorks.contains(work) { continue }
            if var existing = merged[key] {
                existing.sources += candidate.sources
                if existing.genres.isEmpty { existing.genres = candidate.genres }
                existing.communityRating = existing.communityRating ?? candidate.communityRating
                existing.ratingsCount = existing.ratingsCount ?? candidate.ratingsCount
                existing.workID = existing.workID ?? candidate.workID
                if existing.book.coverURL == nil { existing.book = existing.book.filled(from: candidate.book) }
                if existing.book.goodreadsID == nil { existing.book.goodreadsID = candidate.book.goodreadsID }
                merged[key] = existing
            } else {
                merged[key] = candidate
            }
        }

        let scored = merged.values.map { candidate -> Recommendation in
            var score = 0.0
            var seeds: [String] = []
            for source in candidate.sources {
                switch source {
                case .similar(let seed, let weight):
                    score += 1.0 * min(2, max(0.2, weight))
                    if !seeds.contains(seed) { seeds.append(seed) }
                case .friend(_, let weight): score += 0.9 * weight
                case .author: score += 0.5
                case .series: score += 1.6
                case .newRelease: score += 0.4
                case .genre: score += 0.25
                }
            }
            score += 0.5 * tanh(profile.authorAffinity(candidate.book.author) / 2)
            if let match = profile.genreMatch(candidate.genres) { score += 0.6 * match }
            if let rating = candidate.communityRating { score += (rating - 3.9) * 1.2 }
            if let count = candidate.ratingsCount, count > 0 { score += min(0.3, log10(Double(count)) / 20) }
            return Recommendation(book: candidate.book, score: score, reason: reason(for: candidate, seeds: seeds),
                                  genres: candidate.genres, communityRating: candidate.communityRating,
                                  ratingsCount: candidate.ratingsCount)
        }

        var perAuthor: [String: Int] = [:]
        return scored.sorted { $0.score > $1.score }.filter { item in
            let key = TasteProfile.authorKey(item.book.author)
            perAuthor[key, default: 0] += 1
            return perAuthor[key]! <= 2
        }.prefix(limit).map { $0 }
    }

    /// The strongest thing pointing to the book, in words.
    static func reason(for candidate: Candidate, seeds: [String]) -> String {
        if case .series(let title)? = candidate.sources.first(where: { if case .series = $0 { return true }; return false }) {
            return String(localized: "Next in \(title)")
        }
        if seeds.count > 1 {
            return String(localized: "Readers of \(seeds[0]) and \(seeds.count - 1) more of your favourites loved it")
        }
        if let seed = seeds.first {
            return String(localized: "Because you loved \(seed)")
        }
        for source in candidate.sources {
            switch source {
            case .friend(let reason, _): return reason
            case .newRelease(let author): return String(localized: "New from \(author)")
            case .author(let author): return String(localized: "More from \(author)")
            case .genre(let genre): return String(localized: "Well loved in \(GenreNames.display(genre))")
            default: continue
            }
        }
        return String(localized: "Picked for you")
    }
}

// MARK: - Gathering candidates

extension LibraryModel {
    /// Builds "Picked for You" and the Discover deck: books like your
    /// favourites (Goodreads' "Readers also enjoyed"), friends' favourites,
    /// more by authors you love, next in your series, new releases and
    /// well-rated books in your genres — scored against your taste.
    func buildRecommendations(force: Bool = false) async {
        if recommendations.isEmpty,
           let saved = await DataCache.shared.read([Recommendation].self, "picks", "all", ttl: 12 * 3600) {
            recommendations = saved.value
            if !saved.isStale && !force { return }
        } else if !force, !recommendations.isEmpty {
            return
        }
        guard !isBuildingRecommendations, let read = ShelfCache.read(.read)?.entries, !read.isEmpty else { return }
        isBuildingRecommendations = true
        defer { isBuildingRecommendations = false }

        let extras = await BookExtras.all()
        let swipes = await SwipeHistory.all()
        let abandoned = Array(await AbandonedBooks.all().values)
        let profile = TasteProfile.build(read: read, extras: extras, abandoned: abandoned, swipes: swipes)
        let prefs = Preferences.shared

        // Anything on a shelf, by title, by its original title and by its work.
        var excluded = Set(swipes.map(\.key)).union(abandoned.map { Candidate.key($0.title) })
        var excludedWorks = Set<String>()
        var languages: [String] = []
        for shelf in shelves {
            for entry in ShelfCache.read(shelf)?.entries ?? [] {
                excluded.insert(Candidate.key(entry.title))
                guard let page = await DataCache.shared.read(GoodreadsBookPage.Detail.self, "book-page", entry.bookID, ttl: .infinity)?.value
                else { continue }
                if let work = page.workID { excludedWorks.insert(work) }
                if let original = page.about?.originalTitle { excluded.insert(Candidate.key(original)) }
                if shelf.name == Shelf.read.name, let language = page.language { languages.append(language) }
            }
        }
        let allowed: Set<String> = prefs.bookLanguage == .any
            ? ReadingLanguages.codes(of: languages)
            : Set(prefs.bookLanguage.codes.filter { $0.count == 2 })
        var candidates: [Candidate] = []
        func publish() {
            recommendations = Recommender.rank(candidates, profile: profile, excluded: excluded, excludedWorks: excludedWorks)
        }

        // 1. Books readers of your favourites also enjoyed.
        recommendationNote = String(localized: "Looking at books like your favourites…")
        for seed in profile.seeds.prefix(force ? 14 : 10) where !Task.isCancelled {
            for item in await GoodreadsSimilar.similar(to: seed.entry.bookID).prefix(18)
            where ReadingLanguages.fits(title: item.title, blurb: item.blurb, allowed: allowed) {
                var candidate = Candidate(book: item.asBook, communityRating: item.rating, ratingsCount: item.ratingsCount)
                candidate.workID = item.workID
                candidate.sources = [.similar(seed: SeriesTracker.bareTitle(seed.entry.title), weight: seed.weight)]
                candidate.genres = extras[item.bookID]?.genres ?? []
                candidates.append(candidate)
            }
            publish()
        }

        // 2. Friends with your taste.
        await loadLovedSuggestions()
        for suggestion in lovedSuggestions {
            candidates.append(Candidate(book: suggestion.book, sources: [.friend(reason: suggestion.reason, weight: 0.8)]))
        }

        // 3. Next in your series, and new books by your authors.
        for series in seriesProgress where !series.isComplete && !series.nextIsWanted {
            if let next = series.next { candidates.append(Candidate(book: next, sources: [.series(series.title)])) }
        }
        for release in newReleases {
            candidates.append(Candidate(book: release.book, sources: [.newRelease(release.book.author)],
                                        genres: release.book.genresFromCategories))
        }

        // 4. More by the authors you rate highest.
        recommendationNote = String(localized: "Looking at your favourite authors…")
        let topAuthors = read.map(\.author).filter { !$0.isEmpty }
        var seenAuthors = Set<String>()
        let favouriteAuthors = topAuthors.filter { seenAuthors.insert(TasteProfile.authorKey($0)).inserted }
            .sorted { profile.authorAffinity($0) > profile.authorAffinity($1) }
            .filter { profile.authorAffinity($0) > 0.4 }.prefix(5)
        for author in favouriteAuthors where !Task.isCancelled {
            for book in ((try? await GoogleBooksClient.searchByAuthor(author)) ?? []).prefix(8)
            where Suggestions.looksLikeSameAuthor(book.author, author)
                && (prefs.bookLanguage.matches(book.language) || (book.language == nil && prefs.includeUnknownLanguage)) {
                candidates.append(Candidate(book: book, sources: [.author(author)], genres: book.genresFromCategories,
                                            communityRating: book.rating.flatMap(Double.init)))
            }
        }

        // 5. Well-rated books in the genres you love most.
        for genre in profile.topGenres.prefix(3) where !Task.isCancelled {
            for book in ((try? await GoogleBooksClient.search("subject:\"\(genre)\"", language: prefs.bookLanguage)) ?? []).prefix(10) {
                candidates.append(Candidate(book: book, sources: [.genre(genre)], genres: [genre] + book.genresFromCategories,
                                            communityRating: book.rating.flatMap(Double.init)))
            }
        }

        publish()
        Diagnostics.shared.log("suggestions", "\(candidates.count) candidates from \(profile.seeds.prefix(10).count) favourites → \(recommendations.count) picks; top: \(recommendations.prefix(3).map(\.book.title).joined(separator: ", "))",
                               ok: !recommendations.isEmpty)
        recommendationNote = recommendations.isEmpty ? String(localized: "Rate a few books you’ve read, and suggestions show up here.") : nil
        await DataCache.shared.write(recommendations, "picks", "all")
        suggestions = recommendations.prefix(15).map { Suggestion(book: $0.book, reason: $0.reason) }
    }
}
