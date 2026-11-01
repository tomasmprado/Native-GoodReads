import SwiftUI

/// Your Read shelf next to a friend's: what you've both read, where your
/// stars disagree most, and what they loved that you haven't touched.
///
/// Books are matched by Goodreads id, or failing that by title and author —
/// two people often read different editions, which have different ids.
struct TasteComparison: Equatable {

    struct Pair: Identifiable, Equatable {
        let mine: ShelfEntry
        let theirs: ShelfEntry
        var id: String { mine.bookID }

        /// Their stars minus yours, when you both rated it.
        var difference: Int? {
            guard let a = mine.rating, a > 0, let b = theirs.rating, b > 0 else { return nil }
            return b - a
        }
    }

    let inCommon: [Pair]
    /// Both rated, two or more stars apart, biggest gap first.
    let disagreements: [Pair]
    /// Of the books you both rated, the share within one star of each other.
    let agreementPercent: Int?
    /// Rated 4–5 by them, on none of your shelves, best first.
    let theirFavourites: [ShelfEntry]

    static func compute(myRead: [ShelfEntry], myOtherShelves: [ShelfEntry],
                        theirRead: [ShelfEntry]) -> TasteComparison {
        let mine = Matcher(myRead)
        let anyOfMine = Matcher(myRead + myOtherShelves)

        var pairs: [Pair] = []
        var favourites: [ShelfEntry] = []
        for theirs in theirRead {
            if let match = mine.match(theirs) {
                pairs.append(Pair(mine: match, theirs: theirs))
            } else if (theirs.rating ?? 0) >= 4, anyOfMine.match(theirs) == nil {
                favourites.append(theirs)
            }
        }

        let rated = pairs.compactMap { pair in pair.difference.map { (pair, $0) } }
        let agreement = rated.isEmpty ? nil
            : Int((Double(rated.filter { abs($0.1) <= 1 }.count) / Double(rated.count) * 100).rounded())
        let disagreements = rated.filter { abs($0.1) >= 2 }
            .sorted { abs($0.1) > abs($1.1) }
            .prefix(6).map(\.0)

        return TasteComparison(
            inCommon: pairs,
            disagreements: Array(disagreements),
            agreementPercent: agreement,
            theirFavourites: Array(favourites.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }.prefix(10))
        )
    }

    private struct Matcher {
        let byID: [String: ShelfEntry]
        let byTitle: [String: [ShelfEntry]]

        init(_ entries: [ShelfEntry]) {
            byID = Dictionary(entries.map { ($0.bookID, $0) }, uniquingKeysWith: { first, _ in first })
            byTitle = Dictionary(grouping: entries) { Suggestions.normalizedTitle($0.title) }
        }

        func match(_ entry: ShelfEntry) -> ShelfEntry? {
            if let hit = byID[entry.bookID] { return hit }
            return byTitle[Suggestions.normalizedTitle(entry.title)]?
                .first { Suggestions.looksLikeSameAuthor($0.author, entry.author) }
        }
    }
}

/// The comparison, in the friend's profile sheet.
struct TasteComparisonView: View {
    let comparison: TasteComparison
    let friendName: String
    let openBook: (ShelfEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                stat("\(comparison.inCommon.count)", String(localized: "read by both"))
                if let agreement = comparison.agreementPercent {
                    stat("\(agreement)%", String(localized: "within a star"))
                }
            }

            if !comparison.disagreements.isEmpty {
                section(String(localized: "Where You Disagree")) {
                    ForEach(comparison.disagreements) { pair in
                        Button { openBook(pair.mine) } label: {
                            HStack {
                                Text(pair.mine.title).lineLimit(1)
                                Spacer()
                                Text(String(localized: "you \(pair.mine.rating ?? 0)★ · \(friendName) \(pair.theirs.rating ?? 0)★"))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !comparison.theirFavourites.isEmpty {
                section(String(localized: "\(friendName) Loved, You Haven’t Read")) {
                    ForEach(comparison.theirFavourites) { entry in
                        Button { openBook(entry) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.title).lineLimit(1)
                                    Text(entry.author).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(String(repeating: "★", count: entry.rating ?? 0))
                                    .foregroundStyle(.yellow)
                                    .accessibilityLabel(Text("\(entry.rating ?? 0) stars"))
                            }
                            .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if comparison.inCommon.isEmpty && comparison.theirFavourites.isEmpty {
                Text("Nothing to compare yet — no books in common, and no rated favourites.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 14)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
