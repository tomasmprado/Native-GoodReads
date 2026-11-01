import Charts
import SwiftUI

/// Page count and genres for one book, from its Goodreads page. Shelf rows
/// carry neither, so these are collected as book pages get loaded (opening
/// a book, or "Fill In" on the Stats pane) and kept for good.
struct BookExtras: Codable, Sendable, Equatable {
    let pages: Int?
    let genres: [String]

    private static let namespace = "book-extras"
    private static let key = "all"

    static func all() async -> [String: BookExtras] {
        await DataCache.shared.read([String: BookExtras].self, namespace, key, ttl: .infinity)?.value ?? [:]
    }

    static func save(_ extras: BookExtras, for bookID: String) async {
        await DataCache.shared.modify([String: BookExtras].self, namespace, key, default: [:]) {
            $0[bookID] = extras
        }
    }
}

/// Numbers about your reading, worked out from the Read shelf. Goodreads
/// shelf rows carry no page counts, so everything here is book-based.
struct ReadingStats: Equatable {
    struct YearCount: Identifiable, Equatable {
        let year: Int
        let count: Int
        var id: Int { year }
    }

    struct AuthorCount: Identifiable, Equatable {
        let author: String
        let count: Int
        var id: String { author }
    }

    struct GenreCount: Identifiable, Equatable {
        let genre: String
        let count: Int
        var id: String { genre }
    }

    let totalRead: Int
    let readThisYear: Int
    /// Oldest year first, with empty years in between filled in as 0.
    let byYear: [YearCount]
    /// Average of the books you rated (unrated ones don't count as 0).
    let averageRating: Double?
    /// How many books got 1…5 stars, index 0 = 1 star.
    let ratingCounts: [Int]
    let topAuthors: [AuthorCount]
    /// Books read in each month of this year, index 0 = January.
    let thisYearByMonth: [Int]

    /// Pages read per year, over the same years as `byYear` — counting only
    /// books whose page count is known.
    var pagesByYear: [YearCount] = []
    var pagesThisYear = 0
    /// Most common genres across the books read (each book's top three).
    var topGenres: [GenreCount] = []
    /// How many of the books read have a known page count / genre list.
    var booksWithExtras = 0

    /// Too broad to say anything — nearly every book is one or the other.
    static let ignoredGenres: Set<String> = ["Fiction", "Nonfiction", "Audiobook"]

    static func compute(from entries: [ShelfEntry],
                        extras: [String: BookExtras] = [:],
                        now: Date = Date(),
                        calendar: Calendar = .current) -> ReadingStats {
        let thisYear = calendar.component(.year, from: now)
        var perYear: [Int: Int] = [:]
        var pagesPerYear: [Int: Int] = [:]
        var perMonth = Array(repeating: 0, count: 12)

        for entry in entries {
            guard let date = Suggestions.parseDate(entry.dateRead ?? "") else { continue }
            let year = calendar.component(.year, from: date)
            perYear[year, default: 0] += 1
            if let pages = extras[entry.bookID]?.pages {
                pagesPerYear[year, default: 0] += pages
            }
            if year == thisYear {
                perMonth[calendar.component(.month, from: date) - 1] += 1
            }
        }

        var byYear: [YearCount] = []
        var pagesByYear: [YearCount] = []
        if let first = perYear.keys.min() {
            for year in first...max(thisYear, perYear.keys.max() ?? thisYear) {
                byYear.append(YearCount(year: year, count: perYear[year] ?? 0))
                pagesByYear.append(YearCount(year: year, count: pagesPerYear[year] ?? 0))
            }
        }

        var perGenre: [String: Int] = [:]
        var withExtras = 0
        for entry in entries {
            guard let found = extras[entry.bookID] else { continue }
            withExtras += 1
            for genre in found.genres.filter({ !ignoredGenres.contains($0) }).prefix(3) {
                perGenre[genre, default: 0] += 1
            }
        }
        let topGenres = perGenre
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(6)
            .map { GenreCount(genre: $0.key, count: $0.value) }

        let ratings = entries.compactMap(\.rating).filter { (1...5).contains($0) }
        var ratingCounts = Array(repeating: 0, count: 5)
        for rating in ratings { ratingCounts[rating - 1] += 1 }

        var perAuthor: [String: Int] = [:]
        for entry in entries where !entry.author.isEmpty {
            perAuthor[entry.author, default: 0] += 1
        }
        let topAuthors = perAuthor
            .filter { $0.value > 1 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(5)
            .map { AuthorCount(author: $0.key, count: $0.value) }

        return ReadingStats(
            totalRead: entries.count,
            readThisYear: perYear[thisYear] ?? 0,
            byYear: byYear,
            averageRating: ratings.isEmpty ? nil : Double(ratings.reduce(0, +)) / Double(ratings.count),
            ratingCounts: ratingCounts,
            topAuthors: Array(topAuthors),
            thisYearByMonth: perMonth,
            pagesByYear: pagesByYear,
            pagesThisYear: pagesPerYear[thisYear] ?? 0,
            topGenres: Array(topGenres),
            booksWithExtras: withExtras
        )
    }

    /// Where you should be by today to finish `goal` books by 31 December.
    static func expectedByToday(goal: Int, now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard goal > 0,
              let dayOfYear = calendar.ordinality(of: .day, in: .year, for: now),
              let days = calendar.range(of: .day, in: .year, for: now)?.count else { return 0 }
        return Int((Double(goal) * Double(dayOfYear) / Double(days)).rounded(.down))
    }
}

// MARK: - Pane

struct StatsPane: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var prefs = Preferences.shared
    @State private var showingYear = false

    var body: some View {
        Group {
            if let stats = model.readingStats, stats.totalRead > 0 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        goalCard(stats)
                        HStack(alignment: .top, spacing: 16) {
                            numberCard(String(localized: "Books read"), "\(stats.totalRead)", symbol: "books.vertical")
                            numberCard(String(localized: "Average rating"),
                                       stats.averageRating.map { String(format: "%.1f ★", $0) } ?? "—",
                                       symbol: "star")
                            numberCard(String(localized: "Currently reading"), "\(model.currentlyReading.count)",
                                       symbol: "book")
                            if stats.pagesThisYear > 0 {
                                numberCard(String(localized: "Pages this year"),
                                           stats.pagesThisYear.formatted(), symbol: "doc.plaintext")
                            }
                        }
                        .glassGroup(spacing: 16)
                        perYearCard(stats)
                        HStack(alignment: .top, spacing: 16) {
                            ratingsCard(stats)
                            authorsCard(stats)
                        }
                        extrasCard(stats)
                    }
                    .padding(16)
                }
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: model.isLoadingStats ? "hourglass" : "chart.bar")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text(model.isLoadingStats ? String(localized: "Counting your books…") : String(localized: "Mark a book read and your stats show up here."))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Stats")
        .sheet(isPresented: $showingYear) { YearInReviewSheet() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingYear = true } label: {
                    Label("Your Year in Books", systemImage: "gift")
                }
                .help("Your year in books, as an image to save or share")
                .disabled(model.readingStats == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                if model.isLoadingStats {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await model.loadStats(force: true) } } label: {
                        Label("Refresh stats", systemImage: "arrow.clockwise")
                    }
                    .help("Reload your Read shelf")
                }
            }
        }
        .task { await model.loadStats() }
    }

    // MARK: Cards

    private func goalCard(_ stats: ReadingStats) -> some View {
        let goal = prefs.yearlyGoal
        let expected = ReadingStats.expectedByToday(goal: goal)
        let year = Calendar.current.component(.year, from: Date())
        let ahead = stats.readThisYear - expected

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(String(year)) Reading Goal")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Stepper("Goal: \(goal)", value: $prefs.yearlyGoal, in: 1...500)
                    .font(.system(size: 11))
                    .fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(stats.readThisYear)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("of \(goal) books")
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(min(stats.readThisYear, goal)), total: Double(goal))
            Text(ahead >= 0
                 ? (stats.readThisYear >= goal ? String(localized: "Goal reached 🎉") : String(localized: "\(ahead) ahead of schedule"))
                 : String(localized: "\(-ahead) behind schedule"))
                .font(.system(size: 11))
                .foregroundStyle(ahead >= 0 ? Color.green : Color.orange)

            Chart(Array(stats.thisYearByMonth.enumerated()), id: \.offset) { month, count in
                BarMark(x: .value("Month", monthName(month)), y: .value("Books", count))
                    .foregroundStyle(Color.accentColor.gradient)
            }
            .chartXScale(domain: (0..<12).map(monthName))
            .frame(height: 90)
            .accessibilityLabel(Text("Books read each month this year"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18)
    }

    private func numberCard(_ title: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16)
    }

    private func perYearCard(_ stats: ReadingStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Books per Year")
                .font(.system(size: 13, weight: .semibold))
            Chart(stats.byYear.suffix(10)) { item in
                BarMark(x: .value("Year", String(item.year)), y: .value("Books", item.count))
                    .foregroundStyle(Color.accentColor.gradient)
                    .annotation(position: .top) {
                        if item.count > 0 {
                            Text("\(item.count)").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
            }
            .frame(height: 150)
            .accessibilityLabel(Text("Books per year"))
        }
        .padding(16)
        .glassCard(cornerRadius: 18)
    }

    /// Pages per year and top genres — only as complete as the book pages
    /// fetched so far, which this card also offers to fill in.
    private func extrasCard(_ stats: ReadingStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pages and Genres")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.isFillingExtras {
                    ProgressView(value: Double(model.extrasDone), total: Double(max(model.extrasTotal, 1)))
                        .frame(width: 120)
                    Text("\(model.extrasDone) of \(model.extrasTotal)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if stats.booksWithExtras < stats.totalRead {
                    Button("Fill In") { Task { await model.fillBookExtras() } }
                        .controlSize(.small)
                        .glassButton()
                        .help("Fetch the Goodreads page of each read book for its page count and genres")
                }
            }
            Text("Known for \(stats.booksWithExtras) of \(stats.totalRead) books read.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if stats.booksWithExtras > 0 {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pages per Year")
                            .font(.system(size: 12, weight: .medium))
                        Chart(stats.pagesByYear.suffix(10)) { item in
                            BarMark(x: .value("Year", String(item.year)), y: .value("Pages", item.count))
                                .foregroundStyle(Color.teal.gradient)
                        }
                        .frame(height: 130)
                        .accessibilityLabel(Text("Pages per year"))
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Top Genres")
                            .font(.system(size: 12, weight: .medium))
                        ForEach(stats.topGenres) { item in
                            HStack {
                                Text(item.genre).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                Text("\(item.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(width: 200)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18)
    }

    private func ratingsCard(_ stats: ReadingStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Ratings")
                .font(.system(size: 13, weight: .semibold))
            Chart(Array(stats.ratingCounts.enumerated()), id: \.offset) { index, count in
                BarMark(x: .value("Books", count), y: .value("Stars", String(repeating: "★", count: index + 1)))
                    .foregroundStyle(Color.yellow.gradient)
            }
            .chartYScale(domain: (1...5).reversed().map { String(repeating: "★", count: $0) })
            .frame(height: 130)
            .accessibilityLabel(Text("How many books got each rating"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18)
    }

    private func authorsCard(_ stats: ReadingStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Most-Read Authors")
                .font(.system(size: 13, weight: .semibold))
            if stats.topAuthors.isEmpty {
                Text("No author read more than once yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(stats.topAuthors) { item in
                HStack {
                    Text(item.author).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text("\(item.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard(cornerRadius: 18)
    }

    private func monthName(_ index: Int) -> String {
        // Three-letter names: the one-letter ones repeat (J, J, M, M…), and
        // the chart would merge their bars.
        Calendar.current.shortMonthSymbols[index]
    }
}
