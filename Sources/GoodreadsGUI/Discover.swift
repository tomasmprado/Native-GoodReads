import SwiftUI

/// Discover: suggestions one card at a time. Swipe right (→) for Want to
/// Read, left (←) to pass, up (↑) if you've read it already. Every swipe
/// is remembered and teaches the suggestions what you like.
struct DiscoverPane: View {
    @ObservedObject var model: LibraryModel

    @State private var gone: Set<String> = []
    @State private var history: [(item: Recommendation, verdict: SwipeDecision.Verdict)] = []
    @State private var drag: CGSize = .zero
    @State private var flying: (id: String, offset: CGSize)?
    @State private var details: [String: Book] = [:]
    @State private var loadedSwipes = false

    private var deck: [Recommendation] {
        model.recommendations.filter { !gone.contains($0.id) }
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
            loadedSwipes = true
            await model.buildRecommendations()
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
        return VStack(spacing: 0) {
            CachedAsyncImage(url: book.coverURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                        .overlay(Image(systemName: "book.closed").appFont(size: 34).foregroundStyle(.tertiary))
                        .aspectRatio(2 / 3, contentMode: .fit)
                }
            }
            .frame(maxHeight: 300)
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
                if let text = book.description, !text.isEmpty {
                    Text(text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
                        .appFont(size: 12).foregroundStyle(.secondary)
                        .lineLimit(5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            Spacer(minLength: 0)
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
        .onTapGesture(count: 2) { if isTop { model.showBookDetail(book) } }
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
                if let item = deck.first { model.showBookDetail(details[item.id].map { item.book.filled(from: $0) } ?? item.book) }
            }
            .keyboardShortcut(.space, modifiers: [])
            circle("heart.fill", .green, help: String(localized: "Want to Read")) { decide(.want) }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
    }

    private func circle(_ symbol: String, _ color: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(Circle().stroke(color.opacity(0.4), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
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
        withAnimation(.easeIn(duration: 0.25)) { flying = (item.id, direction) }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            gone.insert(item.id)
            flying = nil
            drag = .zero
            history.append((item, verdict))
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
        withAnimation(.spring()) { _ = gone.remove(last.item.id) }
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
