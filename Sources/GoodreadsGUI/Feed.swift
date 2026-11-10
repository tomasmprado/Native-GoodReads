import Foundation

/// Discover ranks its cards the way a social feed does:
///
/// - **It learns from everything you do, as you do it.** Each card is a
///   handful of features (its genres, author, where the suggestion came
///   from, length, age, how popular and how well rated it is). A small
///   model learns a weight for each from every gesture: a heart, "read it",
///   a pass — a quick pass counts more than one you thought about — and
///   opening the details, or lingering on a card, as a softer yes.
/// - **It re-ranks after every swipe**, so the next cards already reflect
///   the last one.
/// - **It explores.** Features it knows little about get a bonus, and a
///   little chance, so the deck doesn't shrink to one genre; a card picked
///   that way says so.
/// - **It keeps variety.** The next card is the best one that isn't too
///   like the last few (same author, the same genres).
enum Feed {

    // MARK: Features

    /// What a card is, as named features with a strength each.
    static func features(of item: Recommendation, now: Date = Date()) -> [String: Double] {
        var features: [String: Double] = ["bias": 1]
        let genres = Array(Set(item.genres.map(normalized))).filter { !$0.isEmpty }.prefix(6)
        for genre in genres { features["genre:\(genre)"] = 1 / Double(max(1, genres.count)).squareRoot() }
        let author = TasteProfile.authorKey(item.book.author)
        if !author.isEmpty { features["author:\(author)"] = 1 }
        for source in item.sources ?? [] { features["from:\(source)"] = 1 }
        if let pages = item.book.pageCount, pages > 0 {
            features[pages < 220 ? "length:short" : pages < 450 ? "length:medium" : "length:long"] = 1
        }
        if let year = item.book.publishedDate.flatMap({ Int($0.prefix(4)) }) {
            let thisYear = Calendar.current.component(.year, from: now)
            features[year >= thisYear - 2 ? "age:new" : year >= 1990 ? "age:recent" : year >= 1900 ? "age:modern" : "age:classic"] = 1
        }
        if let count = item.ratingsCount {
            features[count < 2_000 ? "reach:niche" : count < 100_000 ? "reach:known" : "reach:hit"] = 1
        }
        if let rating = item.communityRating {
            features[rating >= 4.2 ? "rated:loved" : rating >= 3.8 ? "rated:liked" : "rated:mixed"] = 1
        }
        if let language = item.book.language, language.count >= 2 { features["lang:\(language.prefix(2).lowercased())"] = 1 }
        return features
    }

    private static func normalized(_ genre: String) -> String {
        genre.lowercased().trimmingCharacters(in: .whitespaces)
    }

    // MARK: The model

    /// Learned weights, and how often each feature has been seen.
    struct Model: Codable, Equatable, Sendable {
        var weights: [String: Double] = [:]
        var seen: [String: Double] = [:]
        var updates = 0

        /// How much the model expects you to want it, from 0 to 1.
        func likelihood(_ features: [String: Double]) -> Double {
            sigmoid(features.reduce(0) { $0 + (weights[$1.key] ?? 0) * $1.value })
        }

        /// Uncertainty: high for features rarely seen, shrinking as they're seen.
        func novelty(_ features: [String: Double]) -> Double {
            let named = features.filter { $0.key != "bias" }
            guard !named.isEmpty else { return 0 }
            return named.reduce(0) { $0 + 1 / (1 + (seen[$1.key] ?? 0)).squareRoot() } / Double(named.count)
        }

        /// One step of online logistic regression towards `label` (1 = want,
        /// 0 = not), `strength` times as hard as a plain swipe. Old weights
        /// shrink a little each time so tastes can change.
        mutating func learn(_ features: [String: Double], label: Double, strength: Double = 1) {
            let rate = 0.35 * strength
            let error = label - likelihood(features)
            for (name, value) in features {
                let decay = name == "bias" ? 1 : 0.995
                weights[name] = (weights[name] ?? 0) * decay + rate * error * value
                if name != "bias" { seen[name, default: 0] += strength }
            }
            updates += 1
        }
    }

    /// What happened to a card, as a training example.
    enum Signal: Equatable {
        case want, read, pass(seconds: Double), openedDetails, lingered

        var label: Double {
            switch self {
            case .want, .openedDetails, .lingered: 1
            case .read: 0.75
            case .pass: 0
            }
        }

        var strength: Double {
            switch self {
            case .want, .read: 1
            // A quick pass is a clear no; one you thought about, less so.
            case .pass(let seconds): seconds < 1.5 ? 1.4 : seconds > 8 ? 0.5 : 1
            case .openedDetails: 0.45
            case .lingered: 0.25
            }
        }
    }

    /// The model brought up to date with past swipes — for the first time
    /// the feed runs, so it starts from what you've already told Discover.
    static func warmStart(_ swipes: [SwipeDecision]) -> Model {
        var model = Model()
        for swipe in swipes {
            let item = Recommendation(book: Book(id: swipe.key, title: swipe.title, author: swipe.author,
                                                 coverURL: nil, rating: nil),
                                      score: 0, reason: "", genres: swipe.genres)
            let signal: Signal = switch swipe.verdict {
            case .want: .want
            case .read: .read
            case .pass: .pass(seconds: 3)
            }
            model.learn(features(of: item), label: signal.label, strength: signal.strength)
        }
        return model
    }

    // MARK: Ranking

    struct Ranked: Equatable {
        let item: Recommendation
        let score: Double
        /// Picked for variety rather than for a sure match.
        let isExploration: Bool
    }

    /// The deck in the order to show it. `recent` are the cards just shown
    /// (newest last), kept from repeating. `seed` changes the small dose of
    /// chance between sessions.
    static func rank(_ items: [Recommendation], model: Model, recent: [Recommendation] = [],
                     seed: UInt64 = 1, explore: Double = 0.35) -> [Ranked] {
        guard !items.isEmpty else { return [] }
        let maxPrior = max(items.map(\.score).max() ?? 1, 0.001)
        var random = SeededRandom(seed: seed)
        // Confidence grows with what the model has learnt.
        let trust = min(1, Double(model.updates) / 25)

        var pool: [(item: Recommendation, features: [String: Double], base: Double, novelty: Double)] = items.map { item in
            let features = features(of: item)
            let prior = max(0, item.score) / maxPrior                     // what the suggestions thought
            let learned = model.likelihood(features)                      // what your gestures taught
            let base = (1 - 0.6 * trust) * prior + 0.6 * trust * learned + 0.08 * Double.random(in: 0..<1, using: &random)
            return (item, features, base, model.novelty(features))
        }

        var shown = recent.suffix(3).map { (author: TasteProfile.authorKey($0.book.author), genres: Set($0.genres.map(normalized))) }
        var ranked: [Ranked] = []
        while !pool.isEmpty {
            var bestIndex = 0
            var bestScore = -Double.infinity
            var bestExplores = false
            for (index, candidate) in pool.enumerated() {
                let author = TasteProfile.authorKey(candidate.item.book.author)
                let genres = Set(candidate.item.genres.map(normalized))
                // Too like the last few cards: same author, or the same genres.
                var sameness = 0.0
                for (age, previous) in shown.reversed().enumerated() {
                    let fade = 1 / Double(age + 1)
                    if !author.isEmpty, author == previous.author { sameness += 0.6 * fade }
                    if !genres.isEmpty, !previous.genres.isEmpty {
                        let overlap = Double(genres.intersection(previous.genres).count) / Double(genres.union(previous.genres).count)
                        sameness += 0.3 * overlap * fade
                    }
                }
                let exploration = explore * candidate.novelty
                let score = candidate.base + exploration - sameness
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                    bestExplores = exploration > 0.12 && exploration > candidate.base * 0.5
                }
            }
            let pick = pool.remove(at: bestIndex)
            ranked.append(Ranked(item: pick.item, score: bestScore, isExploration: bestExplores))
            shown.append((TasteProfile.authorKey(pick.item.book.author), Set(pick.item.genres.map(normalized))))
            if shown.count > 3 { shown.removeFirst() }
        }
        return ranked
    }
}

private func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-max(-30, min(30, x)))) }

// MARK: - Kept between launches

/// The feed's model, saved after every gesture.
@MainActor
final class FeedLearner: ObservableObject {
    static let shared = FeedLearner()

    @Published private(set) var model = Feed.Model()
    private var loaded = false
    /// Changes once per launch, so the dose of chance differs between sessions.
    let sessionSeed = UInt64(Date().timeIntervalSince1970)

    func load() async {
        guard !loaded else { return }
        loaded = true
        if let saved = await DataCache.shared.read(Feed.Model.self, "discover-model", "all", ttl: .infinity)?.value {
            model = saved
        } else {
            model = Feed.warmStart(await SwipeHistory.all())
            await save()
        }
    }

    func learn(_ item: Recommendation, _ signal: Feed.Signal) {
        model.learn(Feed.features(of: item), label: signal.label, strength: signal.strength)
        Task { await save() }
    }

    /// Takes back the last swipe's lesson (Undo), by teaching the opposite.
    func unlearn(_ item: Recommendation, _ signal: Feed.Signal) {
        model.learn(Feed.features(of: item), label: 1 - signal.label, strength: signal.strength * 0.8)
        Task { await save() }
    }

    /// How much your gestures add to a suggestion's score elsewhere (the
    /// Suggestions list): from −0.5 to +0.5, nothing until it has learnt.
    func boost(_ item: Recommendation) -> Double {
        guard model.updates >= 8 else { return 0 }
        return model.likelihood(Feed.features(of: item)) - 0.5
    }

    private func save() async {
        await DataCache.shared.write(model, "discover-model", "all")
    }
}
