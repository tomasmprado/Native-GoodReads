import SwiftUI

// MARK: - Numbers

/// Everything Goodreads' Year in Books shows, and a little more, for one year.
struct YearWrap: Equatable {
    struct Pick: Equatable {
        let entry: ShelfEntry
        let value: Int
    }

    let year: Int
    let books: [ShelfEntry]
    let pages: Int
    let pagesPerDay: Double
    let shortest: Pick?
    let longest: Pick?
    let averageLength: Int?
    let mostShelved: Pick?
    let leastShelved: Pick?
    let myAverage: Double?
    let othersAverage: Double?
    let highestRated: (entry: ShelfEntry, rating: Double)?
    let topGenres: [String]
    let topAuthor: (name: String, count: Int)?
    let months: [Int]
    let first: ShelfEntry?
    let last: ShelfEntry?
    let fiveStars: [ShelfEntry]

    static func == (a: YearWrap, b: YearWrap) -> Bool { a.year == b.year && a.books == b.books && a.pages == b.pages }

    var busiestMonth: Int? {
        guard let most = months.max(), most > 0 else { return nil }
        return months.firstIndex(of: most)
    }

    static func compute(read: [ShelfEntry], extras: [String: BookExtras], year: Int,
                        calendar: Calendar = .current, now: Date = Date()) -> YearWrap {
        let dated = read.compactMap { entry -> (ShelfEntry, Date)? in
            guard let date = Suggestions.parseDate(entry.dateRead ?? ""),
                  calendar.component(.year, from: date) == year else { return nil }
            return (entry, date)
        }.sorted { $0.1 < $1.1 }
        let books = dated.map(\.0)

        let withPages = books.compactMap { entry in extras[entry.bookID]?.pages.map { Pick(entry: entry, value: $0) } }
        let pages = withPages.reduce(0) { $0 + $1.value }
        let days: Double = {
            if calendar.component(.year, from: now) == year {
                return Double(calendar.ordinality(of: .day, in: .year, for: now) ?? 365)
            }
            return Double(calendar.range(of: .day, in: .year, for: calendar.date(from: DateComponents(year: year)) ?? now)?.count ?? 365)
        }()

        let shelved = books.compactMap { entry in extras[entry.bookID]?.ratingsCount.map { Pick(entry: entry, value: $0) } }
        let rated = books.compactMap { entry -> Int? in (entry.rating ?? 0) > 0 ? entry.rating : nil }
        let others = books.compactMap { extras[$0.bookID]?.rating }
        let highest = books.compactMap { entry in extras[entry.bookID]?.rating.map { (entry: entry, rating: $0) } }
            .max { $0.rating < $1.rating }

        var genres: [String: Int] = [:]
        var authors: [String: Int] = [:]
        var months = Array(repeating: 0, count: 12)
        for (entry, date) in dated {
            for genre in (extras[entry.bookID]?.genres ?? []).filter({ !ReadingStats.ignoredGenres.contains($0) }).prefix(3) {
                genres[genre, default: 0] += 1
            }
            if !entry.author.isEmpty { authors[entry.author, default: 0] += 1 }
            months[calendar.component(.month, from: date) - 1] += 1
        }
        let topGenres = genres.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3).map(\.key)
        let author = authors.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }

        return YearWrap(
            year: year, books: books, pages: pages, pagesPerDay: Double(pages) / max(days, 1),
            shortest: withPages.min { $0.value < $1.value },
            longest: withPages.max { $0.value < $1.value },
            averageLength: withPages.isEmpty ? nil : pages / withPages.count,
            mostShelved: shelved.max { $0.value < $1.value },
            leastShelved: shelved.count > 1 ? shelved.min { $0.value < $1.value } : nil,
            myAverage: rated.isEmpty ? nil : Double(rated.reduce(0, +)) / Double(rated.count),
            othersAverage: others.isEmpty ? nil : others.reduce(0, +) / Double(others.count),
            highestRated: highest,
            topGenres: topGenres,
            topAuthor: author.flatMap { $0.value >= 2 ? (name: $0.key, count: $0.value) : nil },
            months: months,
            first: books.first, last: books.count > 1 ? books.last : nil,
            fiveStars: books.filter { $0.rating == 5 }
        )
    }
}

// MARK: - Slides

/// Your Year in Books as a story: one big fact at a time, moving on by
/// itself (or with the arrow keys / a click), ending on the card to share.
struct YearWrappedSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: LibraryModel

    @State private var read: [ShelfEntry] = []
    @State private var extras: [String: BookExtras] = [:]
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var index = 0
    @State private var preparing: String?
    @State private var paused = false
    @State private var showCard = false

    private var wrap: YearWrap { YearWrap.compute(read: read, extras: extras, year: year) }
    private var slides: [Slide] { Slide.all(for: wrap) }

    var body: some View {
        let slides = self.slides
        let current = slides.isEmpty ? nil : slides[min(index, slides.count - 1)]
        ZStack {
            (current?.background ?? Slide.palette[0]).ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: index)

            VStack(spacing: 0) {
                progressBars(count: slides.count)
                    .padding(.horizontal, 18).padding(.top, 14)
                HStack {
                    let years = YearSummary.years(in: read)
                    if years.count > 1 {
                        Picker("Year", selection: $year) {
                            ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Spacer()
                    Button(paused ? "Play" : "Pause") { paused.toggle() }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
                    Button("Share Card…") { showCard = true }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.plain).foregroundStyle(.white)
                }
                .appFont(size: 12, weight: .medium)
                .padding(.horizontal, 18).padding(.top, 10)

                Spacer()
                if let preparing {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large).tint(.white)
                        Text(preparing).foregroundStyle(.white.opacity(0.85))
                    }
                } else if let current {
                    current.content(model)
                        .id("\(year)-\(index)")
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                        .padding(.horizontal, 40)
                } else {
                    Text("No books marked read this year yet.").foregroundStyle(.white)
                }
                Spacer()
            }
        }
        .foregroundStyle(.white)
        .frame(width: 560, height: 720)
        .fixedSheetWindow()
        .contentShape(Rectangle())
        .onTapGesture { advance(slides.count) }
        .background {
            // Arrow keys move between slides, Space pauses.
            Group {
                Button("") { advance(slides.count) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { withAnimation { index = max(0, index - 1) } }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { paused.toggle() }.keyboardShortcut(.space, modifiers: [])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .task { await load() }
        .task(id: "\(year)-\(index)-\(paused)") {
            guard !paused, preparing == nil else { return }
            try? await Task.sleep(for: .seconds(5.5))
            guard !Task.isCancelled, index < slides.count - 1 else { return }
            advance(slides.count)
        }
        .onChange(of: year) { _ in index = 0; Task { await fillIn() } }
        .sheet(isPresented: $showCard) { YearInReviewSheet() }
    }

    private func advance(_ count: Int) {
        guard count > 0 else { return }
        withAnimation(.easeInOut(duration: 0.45)) { index = min(count - 1, index + 1) }
    }

    private func progressBars(count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<max(count, 1), id: \.self) { i in
                Capsule().fill(.white.opacity(i <= index ? 0.95 : 0.3)).frame(height: 3)
            }
        }
    }

    private func load() async {
        read = ShelfCache.read(.read)?.entries ?? []
        extras = await BookExtras.all()
        if let latest = YearSummary.years(in: read).first, latest < year,
           YearWrap.compute(read: read, extras: extras, year: year).books.isEmpty { year = latest }
        await fillIn()
    }

    /// The year's books need page counts and rating counts from their pages.
    private func fillIn() async {
        let missing = wrap.books.filter { extras[$0.bookID]?.pages == nil || extras[$0.bookID]?.ratingsCount == nil }
        guard !missing.isEmpty else { return }
        for (offset, entry) in missing.enumerated() {
            preparing = String(localized: "Getting your year ready… \(offset + 1) of \(missing.count)")
            await BookExtras.fetch(entry)
        }
        extras = await BookExtras.all()
        preparing = nil
    }
}

private struct Slide {
    let background: LinearGradient
    let content: @MainActor (LibraryModel) -> AnyView

    static let palette: [LinearGradient] = [
        [Color(red: 0.36, green: 0.22, blue: 0.13), Color(red: 0.75, green: 0.45, blue: 0.2)],
        [Color(red: 0.12, green: 0.25, blue: 0.45), Color(red: 0.35, green: 0.6, blue: 0.85)],
        [Color(red: 0.4, green: 0.12, blue: 0.35), Color(red: 0.85, green: 0.35, blue: 0.5)],
        [Color(red: 0.1, green: 0.35, blue: 0.25), Color(red: 0.35, green: 0.75, blue: 0.5)],
        [Color(red: 0.25, green: 0.15, blue: 0.5), Color(red: 0.55, green: 0.4, blue: 0.9)],
        [Color(red: 0.5, green: 0.2, blue: 0.1), Color(red: 0.95, green: 0.55, blue: 0.25)],
    ].map { LinearGradient(colors: $0, startPoint: .topLeading, endPoint: .bottomTrailing) }

    @MainActor
    static func all(for wrap: YearWrap) -> [Slide] {
        guard !wrap.books.isEmpty else { return [] }
        var slides: [Slide] = []
        func add(@ViewBuilder _ view: @escaping @MainActor (LibraryModel) -> some View) {
            slides.append(Slide(background: palette[slides.count % palette.count]) { AnyView(view($0)) })
        }

        add { _ in
            VStack(spacing: 18) {
                CoverMosaic(entries: Array(wrap.books.prefix(12)))
                Text(verbatim: String(wrap.year)).font(.system(size: 64, weight: .heavy, design: .rounded))
                Text("Your Year in Books").font(.system(size: 24, weight: .semibold))
            }
        }
        add { _ in
            BigNumber(caption: String(localized: "You read"), value: wrap.books.count,
                      unit: wrap.books.count == 1 ? String(localized: "book") : String(localized: "books"))
        }
        if wrap.pages > 0 {
            add { _ in
                VStack(spacing: 14) {
                    BigNumber(caption: String(localized: "That's"), value: wrap.pages, unit: String(localized: "pages"))
                    Text("about \(Int(wrap.pagesPerDay.rounded())) pages a day").font(.system(size: 18)).opacity(0.85)
                    if let average = wrap.averageLength {
                        Text("Your books were \(average) pages long on average").font(.system(size: 15)).opacity(0.7)
                    }
                }
            }
        }
        if let month = wrap.busiestMonth {
            add { _ in
                VStack(spacing: 18) {
                    Text("Your busiest month").font(.system(size: 18)).opacity(0.85)
                    Text(Calendar.current.monthSymbols[month].capitalized).font(.system(size: 44, weight: .heavy, design: .rounded))
                    MonthBars(months: wrap.months, highlight: month)
                }
            }
        }
        if let genre = wrap.topGenres.first {
            add { _ in
                VStack(spacing: 14) {
                    Text("Your top genre").font(.system(size: 18)).opacity(0.85)
                    Text(GenreNames.display(genre)).font(.system(size: 44, weight: .heavy, design: .rounded))
                        .multilineTextAlignment(.center)
                    if wrap.topGenres.count > 1 {
                        Text("then \(wrap.topGenres.dropFirst().map(GenreNames.display).joined(separator: ", "))")
                            .font(.system(size: 16)).opacity(0.8)
                    }
                }
            }
        }
        if let author = wrap.topAuthor {
            add { _ in
                VStack(spacing: 14) {
                    Text("You couldn't get enough of").font(.system(size: 18)).opacity(0.85)
                    Text(author.name).font(.system(size: 40, weight: .heavy, design: .rounded)).multilineTextAlignment(.center)
                    Text("\(author.count) books").font(.system(size: 18)).opacity(0.85)
                }
            }
        }
        if let shortest = wrap.shortest, let longest = wrap.longest, shortest.entry != longest.entry {
            add { _ in
                HStack(alignment: .top, spacing: 28) {
                    BookPick(caption: String(localized: "Shortest"), entry: shortest.entry, detail: String(localized: "\(shortest.value) pages"))
                    BookPick(caption: String(localized: "Longest"), entry: longest.entry, detail: String(localized: "\(longest.value) pages"))
                }
            }
        }
        if let mine = wrap.myAverage {
            add { _ in
                VStack(spacing: 14) {
                    Text("Your average rating").font(.system(size: 18)).opacity(0.85)
                    Text(String(format: "%.1f ★", mine)).font(.system(size: 64, weight: .heavy, design: .rounded))
                    if let others = wrap.othersAverage {
                        let kinder = mine > others + 0.15, tougher = mine < others - 0.15
                        Text(kinder ? String(localized: "Kinder than most readers (they gave \(String(format: "%.1f", others)))")
                             : tougher ? String(localized: "Tougher than most readers (they gave \(String(format: "%.1f", others)))")
                             : String(localized: "Right in line with everyone else (\(String(format: "%.1f", others)))"))
                            .font(.system(size: 16)).opacity(0.85).multilineTextAlignment(.center)
                    }
                }
            }
        }
        if let most = wrap.mostShelved {
            add { _ in
                HStack(alignment: .top, spacing: 28) {
                    BookPick(caption: String(localized: "Most popular"), entry: most.entry,
                             detail: String(localized: "\(most.value.formatted()) ratings"))
                    if let least = wrap.leastShelved, least.entry != most.entry {
                        BookPick(caption: String(localized: "Hidden gem"), entry: least.entry,
                                 detail: String(localized: "only \(least.value.formatted()) ratings"))
                    }
                }
            }
        }
        if let best = wrap.highestRated {
            add { _ in
                VStack(spacing: 10) {
                    BookPick(caption: String(localized: "Highest rated on Goodreads"), entry: best.entry,
                             detail: String(format: "%.2f ★", best.rating))
                }
            }
        }
        if let first = wrap.first {
            add { _ in
                HStack(alignment: .top, spacing: 28) {
                    BookPick(caption: String(localized: "Your first"), entry: first, detail: first.dateRead ?? "")
                    if let last = wrap.last {
                        BookPick(caption: String(localized: "Your latest"), entry: last, detail: last.dateRead ?? "")
                    }
                }
            }
        }
        if !wrap.fiveStars.isEmpty {
            add { _ in
                VStack(spacing: 16) {
                    Text("Your five-star books").font(.system(size: 24, weight: .bold))
                    CoverMosaic(entries: Array(wrap.fiveStars.prefix(12)))
                }
            }
        }
        add { _ in
            VStack(spacing: 14) {
                Text("That was your \(String(wrap.year))").font(.system(size: 30, weight: .heavy, design: .rounded))
                Text("\(wrap.books.count) books · \(wrap.pages.formatted()) pages").font(.system(size: 18)).opacity(0.85)
                Text("Choose Share Card… to save it as an image.").font(.system(size: 14)).opacity(0.7)
            }
        }
        return slides
    }
}

private struct BigNumber: View {
    let caption: String
    let value: Int
    let unit: String
    @State private var shown = 0

    var body: some View {
        VStack(spacing: 6) {
            Text(caption).font(.system(size: 20)).opacity(0.85)
            Text("\(shown.formatted())").font(.system(size: 88, weight: .heavy, design: .rounded))
                .contentTransition(.numericText())
                .monospacedDigit()
            Text(unit).font(.system(size: 26, weight: .semibold))
        }
        .task {
            shown = 0
            let steps = 30
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(28))
                withAnimation(.easeOut(duration: 0.05)) { shown = value * step / steps }
            }
        }
    }
}

private struct MonthBars: View {
    let months: [Int]
    let highlight: Int
    @State private var grown = false

    var body: some View {
        let most = max(months.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<12, id: \.self) { month in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white.opacity(month == highlight ? 1 : 0.45))
                        .frame(width: 22, height: grown ? max(4, 150 * CGFloat(months[month]) / CGFloat(most)) : 4)
                    Text(Calendar.current.veryShortMonthSymbols[month]).font(.system(size: 10)).opacity(0.75)
                }
            }
        }
        .frame(height: 175, alignment: .bottom)
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.7).delay(0.15)) { grown = true } }
    }
}

private struct BookPick: View {
    let caption: String
    let entry: ShelfEntry
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Text(caption).font(.system(size: 16, weight: .semibold)).opacity(0.85)
            CachedAsyncImage(url: entry.coverURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.15))
                }
            }
            .frame(width: 130, height: 196)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(radius: 12, y: 6)
            Text(entry.title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center).lineLimit(3)
                .frame(width: 170)
            Text(detail).font(.system(size: 13)).opacity(0.8)
        }
    }
}

private struct CoverMosaic: View {
    let entries: [ShelfEntry]
    @State private var shown = false

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(70), spacing: 8), count: min(4, max(entries.count, 1)))
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { offset, entry in
                CachedAsyncImage(url: entry.coverURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.15))
                    }
                }
                .frame(width: 70, height: 105)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .rotationEffect(.degrees(shown ? 0 : Double((offset % 3) - 1) * 8))
                .offset(y: shown ? 0 : 30)
                .opacity(shown ? 1 : 0)
                .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(Double(offset) * 0.05), value: shown)
            }
        }
        .onAppear { shown = true }
    }
}
