import SwiftUI

/// Discover: suggestions one card at a time. Swipe right (→) for Want to
/// Read, left (←) to pass, up (↑) if you've read it already. The deck is a
/// feed (see Feed.swift): it learns from every swipe, from how long you
/// look at a card and from opening its details, re-ranks after each one,
/// and mixes in something different now and then.
struct DiscoverPane: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var learner = FeedLearner.shared

    @State private var gone: Set<String> = []
    @State private var history: [(item: Recommendation, verdict: SwipeDecision.Verdict, signal: Feed.Signal)] = []
    /// The deck in the feed's order; the top card stays put until decided.
    @State private var order: [Feed.Ranked] = []
    /// When the top card came up, for how long it was looked at.
    @State private var shownAt = Date()
    /// Cards whose details were opened, or that were lingered on (taught once).
    @State private var noticed: Set<String> = []
    @State private var drag: CGSize = .zero
    @State private var flying: (id: String, offset: CGSize)?
    @State private var details: [String: Book] = [:]
    @State private var loadedSwipes = false

    private var deck: [Recommendation] {
        let available = model.recommendations.filter { !gone.contains($0.id) }
        let ids = Set(available.map(\.id))
        let ranked = order.map(\.item).filter { ids.contains($0.id) }
        let rankedIDs = Set(ranked.map(\.id))
        // Books that arrived since the last re-rank wait at the end.
        return ranked + available.filter { !rankedIDs.contains($0.id) }
    }

    private func isExploring(_ id: String) -> Bool {
        order.first { $0.item.id == id }?.isExploration ?? false
    }

    /// Puts the deck in the feed's order. The card on top stays on top
    /// unless `keepTop` is false (it was just decided).
    private func rerank(keepTop: Bool) {
        let available = model.recommendations.filter { !gone.contains($0.id) }
        let top = keepTop ? deck.first : nil
        var ranked = Feed.rank(available.filter { $0.id != top?.id }, model: learner.model,
                               recent: history.suffix(3).map(\.item) + (top.map { [$0] } ?? []),
                               seed: learner.sessionSeed &+ UInt64(gone.count))
        if let top { ranked.insert(Feed.Ranked(item: top, score: 0, isExploration: isExploring(top.id)), at: 0) }
        order = ranked
    }

    /// A softer yes, taught once per card.
    private func notice(_ item: Recommendation, _ signal: Feed.Signal) {
        guard noticed.insert(item.id).inserted else { return }
        learner.learn(item, signal)
    }

    private func openDetails(_ item: Recommendation) {
        notice(item, .openedDetails)
        model.showBookDetail(details[item.id].map { item.book.filled(from: $0) } ?? item.book)
    }

    var body: some View {
        VStack(spacing: 14) {
            if !loadedSwipes {
                Spacer()
            } else if let top = deck.first {
                ZStack {
                    ForEach(Array(deck.prefix(3).enumerated()).reversed(), id: \.element.id) { index, item in
                        card(item, isTop: index == 0)
                            .scaleEffect(1 - CGFloat(index) * 0.04)
                            .offset(y: CGFloat(index) * 12)
                            .opacity(index == 2 ? 0.6 : 1)
                    }
                }
                .frame(maxWidth: 420, maxHeight: .infinity)
                .padding(.top, 8)
                buttons(top)
                Text("\(deck.count) to go · ← pass · → want to read · ↑ read it · space for details")
                    .appFont(size: 10).foregroundStyle(.tertiary)
            } else {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: model.isBuildingRecommendations ? "hourglass" : "rectangle.stack")
                        .appFont(size: 40).foregroundStyle(.tertiary)
                    Text(model.isBuildingRecommendations ? String(localized: "Finding books for you…")
                                                         : (model.recommendationNote ?? String(localized: "You’ve seen them all for now.")))
                        .foregroundStyle(.secondary)
                    if !model.isBuildingRecommendations {
                        Button("Find More") { Task { await model.buildRecommendations(force: true) } }
                            .glassButton()
                    }
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Discover")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(history.isEmpty)
                    .help("Bring back the last book")
            }
        }
        .task {
            gone = Set(await SwipeHistory.all().map(\.key))
            await learner.load()
            rerank(keepTop: false)
            loadedSwipes = true
            await model.buildRecommendations()
        }
        .onChange(of: model.recommendations.count) { _ in rerank(keepTop: true) }
        .onChange(of: deck.first?.id) { _ in shownAt = Date() }
        .task(id: deck.first?.id) {
            // Lingering on a card is a quiet sign of interest.
            guard let item = deck.first else { return }
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled, deck.first?.id == item.id { notice(item, .lingered) }
        }
        .onChange(of: deck.count) { count in
            // Running low: look for more in the background.
            if count < 5, loadedSwipes, !model.isBuildingRecommendations {
                Task { await model.buildRecommendations(force: true) }
            }
        }
    }

    // MARK: Card

    private func card(_ item: Recommendation, isTop: Bool) -> some View {
        let book = details[item.id].map { item.book.filled(from: $0) } ?? item.book
        let offset = flying?.id == item.id ? flying!.offset : (isTop ? drag : .zero)
        return GeometryReader { geo in
            // The cover takes about half the card, whatever the window's
            // height; the text gets the rest.
            let coverHeight = max(110, geo.size.height * 0.52)
            let blurbLines = max(1, Int((geo.size.height - coverHeight - 150) / 16))
            VStack(spacing: 0) {
                CachedAsyncImage(url: book.coverURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                            .overlay(Image(systemName: "book.closed").appFont(size: 34).foregroundStyle(.tertiary))
                            .aspectRatio(2 / 3, contentMode: .fit)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: coverHeight)
                .frame(height: coverHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(radius: 6, y: 3)
                .padding(.top, 18)
                .padding(.horizontal, 18)

                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title).appFont(size: 17, weight: .semibold).lineLimit(2)
                    Text(book.author).appFont(size: 13).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 8) {
                        if let rating = item.communityRating {
                            Label(String(format: "%.2f", rating), systemImage: "star.fill")
                                .foregroundStyle(.orange)
                        }
                        if let count = item.ratingsCount {
                            Text("\(count.formatted()) ratings").foregroundStyle(.secondary)
                        }
                        if let pages = book.pageCount { Text("\(pages) pages").foregroundStyle(.secondary) }
                    }
                    .appFont(size: 11)
                    Label(item.reason, systemImage: "sparkles")
                        .appFont(size: 11, weight: .medium)
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(2)
                    if isExploring(item.id) {
                        Label("Something different, to see if you like it", systemImage: "dice")
                            .appFont(size: 10, weight: .medium)
                            .foregroundStyle(.purple)
                            .lineLimit(1)
                    }
                    if let text = book.description, !text.isEmpty {
                        Text(text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
                            .appFont(size: 12).foregroundStyle(.secondary)
                            .lineLimit(blurbLines)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.primary.opacity(0.1)))
        .overlay(alignment: .top) { if isTop { stamp(for: offset) } }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .offset(offset)
        .rotationEffect(.degrees(Double(offset.width) / 22), anchor: .bottom)
        .gesture(isTop ? DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                let t = value.translation
                if t.width > 120 { decide(.want) }
                else if t.width < -120 { decide(.pass) }
                else if t.height < -140 { decide(.read) }
                else { withAnimation(.spring()) { drag = .zero } }
            } : nil)
        .onTapGesture(count: 2) { if isTop { openDetails(item) } }
        .task(id: item.id) { if isTop { await loadDetails(item) } }
    }

    /// "WANT TO READ" / "PASS" / "READ IT" as the card is dragged.
    @ViewBuilder
    private func stamp(for offset: CGSize) -> some View {
        let label: (text: String, color: Color)? = {
            if offset.width > 40 { return (String(localized: "WANT TO READ"), .green) }
            if offset.width < -40 { return (String(localized: "PASS"), .red) }
            if offset.height < -60 { return (String(localized: "READ IT"), .blue) }
            return nil
        }()
        if let (text, color) = label {
            Text(text)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 3))
                .rotationEffect(.degrees(offset.width > 0 ? -12 : 12))
                .padding(.top, 34)
                .opacity(min(1, Double(max(abs(offset.width), -offset.height)) / 120))
        }
    }

    private func buttons(_ top: Recommendation) -> some View {
        HStack(spacing: 22) {
            circle("xmark", .red, help: String(localized: "Pass")) { decide(.pass) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            circle("checkmark", .blue, help: String(localized: "I’ve read it")) { decide(.read) }
                .keyboardShortcut(.upArrow, modifiers: [])
            circle("info", .secondary, help: String(localized: "Details")) {
                if let item = deck.first { openDetails(item) }
            }
            .keyboardShortcut(.space, modifiers: [])
            circle("heart.fill", .green, help: String(localized: "Want to Read")) { decide(.want) }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .glassGroup(spacing: 22)
    }

    private func circle(_ symbol: String, _ color: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCircle(tint: color)
        .help(help)
        .disabled(flying != nil)
    }

    // MARK: Actions

    /// Acts on the card on top now — read when the key is pressed, not
    /// when the button was drawn.
    private func decide(_ verdict: SwipeDecision.Verdict) {
        guard flying == nil, let item = deck.first else { return }
        let book = details[item.id].map { item.book.filled(from: $0) } ?? item.book
        let direction: CGSize = switch verdict {
        case .want: CGSize(width: 700, height: 40)
        case .pass: CGSize(width: -700, height: 40)
        case .read: CGSize(width: 0, height: -900)
        }
        let signal: Feed.Signal = switch verdict {
        case .want: .want
        case .read: .read
        case .pass: .pass(seconds: Date().timeIntervalSince(shownAt))
        }
        learner.learn(item, signal)
        withAnimation(.easeIn(duration: 0.25)) { flying = (item.id, direction) }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            gone.insert(item.id)
            flying = nil
            drag = .zero
            history.append((item, verdict, signal))
            // The next cards already reflect this one.
            rerank(keepTop: false)
            await SwipeHistory.add(SwipeDecision(key: item.id, title: book.title, author: book.author,
                                                 genres: item.genres.isEmpty ? book.genresFromCategories : item.genres,
                                                 verdict: verdict, date: Date(), bookID: book.goodreadsID, workID: item.workID))
            switch verdict {
            case .want: await model.shelve(book, to: .wantToRead)
            case .read: model.activeSheet = .finishBook(book)
            case .pass: break
            }
        }
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        learner.unlearn(last.item, last.signal)
        withAnimation(.spring()) {
            _ = gone.remove(last.item.id)
            order.removeAll { $0.item.id == last.item.id }
            order.insert(Feed.Ranked(item: last.item, score: 0, isExploration: false), at: 0)
        }
        Task {
            await SwipeHistory.remove(last.item.id)
            if last.verdict == .want,
               let entry = ShelfCache.read(.wantToRead)?.entries.first(where: {
                   $0.bookID == last.item.book.goodreadsID || Candidate.key($0.title) == last.item.id
               }) {
                await model.remove(entry)
            }
        }
    }

    /// The description and page count, from Google Books, for the card on top.
    private func loadDetails(_ item: Recommendation) async {
        guard details[item.id] == nil, item.book.description?.isEmpty ?? true || item.book.pageCount == nil else { return }
        if let found = await GoogleBooksClient.details(isbn: item.book.isbn, title: SeriesTracker.bareTitle(item.book.title),
                                                       author: item.book.author) {
            details[item.id] = found
        }
    }
}
