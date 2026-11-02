import SwiftUI

/// Google Books' metadata plus Goodreads' community reviews for one book, with
/// the ability to post your own rating and review — which, like every other
/// rating action in this app, also moves the book to your Read shelf.
struct BookDetailView: View {
    let book: Book

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = LibraryModel.shared

    @State private var goodreadsID: String?
    @State private var resolveError: String?

    @State private var reviews: [GoodreadsBookPage.Review] = []
    @State private var pageLanguage: String?
    @State private var authorURL: URL?
    @State private var series: GoodreadsSeries.Ref?
    @State private var about: GoodreadsBookPage.About?
    @State private var genres: [String] = []
    @State private var pageCount: Int?
    @State private var note = BookNote()
    @State private var noteLoaded = false
    @State private var savedNote = BookNote()
    @State private var newQuote = ""
    @State private var nextInSeries: GoodreadsSeries.Volume?
    @State private var isLoadingReviews = false
    @State private var reviewsError: String?

    @State private var rating = 0
    @State private var reviewText = ""
    @State private var isPosting = false

    var body: some View {
        VStack(spacing: 0) {
            GlassHeader {
                Text("Book Details")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let goodreadsID, let url = LibraryModel.goodreadsURL(bookID: goodreadsID) {
                    ShareLink(item: url,
                              subject: Text(book.title),
                              message: Text("\(book.title) — \(book.author)")) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .glassButton()
                    .help("Share this book")
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .glassButton()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    BookAboutView(about: about, genres: genres, book: book,
                                  pages: pageCount, language: pageLanguage)
                    friendsSection
                    Divider()
                    composeBox
                    Divider()
                    notesSection
                    Divider()
                    reviewsSection
                }
                .padding(16)
            }
        }
        .frame(width: 720, height: 720)
        .background(alignment: .top) { CoverBackdrop(url: book.coverURL) }
        .task { await resolveAndLoad() }
        .task(id: series) { await loadNextInSeries() }
        .task(id: noteKey) {
            guard let noteKey else { return }
            note = await BookNotes.note(for: noteKey)
            savedNote = note
            noteLoaded = true
        }
        .task(id: note) {
            // Saved a moment after typing stops.
            guard noteLoaded, let noteKey, note != savedNote else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await BookNotes.save(note, for: noteKey)
            savedNote = note
        }
        .onDisappear {
            // Closing within the pause above would otherwise drop the last edit.
            guard noteLoaded, let noteKey, note != savedNote else { return }
            let pending = note
            Task { await BookNotes.save(pending, for: noteKey) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let url = book.coverURL {
                    CachedAsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fit)
                        } else {
                            coverPlaceholder
                        }
                    }
                } else {
                    coverPlaceholder
                }
            }
            .frame(width: 110, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.system(size: 17, weight: .semibold))
                    .textSelection(.enabled)
                if let authorURL {
                    Button(authorName) { model.showAuthorPage(authorURL) }
                        .font(.system(size: 13))
                        .buttonStyle(.link)
                } else {
                    Text(authorName)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                if let series {
                    seriesLine(series)
                }

                HStack(spacing: 6) {
                    ForEach(metaBits, id: \.self) { bit in
                        Text(bit)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)

                if let rating = book.rating {
                    Text("Google rating: ★ \(rating)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if let resolveError {
                    Text(resolveError)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else if goodreadsID == nil {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Finding this book on Goodreads…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func seriesLine(_ series: GoodreadsSeries.Ref) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                NSWorkspace.shared.open(series.url)
            } label: {
                Label(series.position.map { String(localized: "\(series.title) #\($0)") } ?? series.title,
                      systemImage: "books.vertical")
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
            .help("Open the series on Goodreads")

            if let next = nextInSeries {
                HStack(spacing: 6) {
                    Text("Next: \(next.title)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Details") { model.showBookDetail(next.asBook) }
                        .controlSize(.small)
                        .glassButton()
                    Button("Want to Read") {
                        Task { await model.shelve(next.asBook, to: .wantToRead) }
                    }
                    .controlSize(.small)
                    .glassButton()
                    .disabled(model.busyBookID != nil)
                }
            }
        }
    }

    private func loadNextInSeries() async {
        guard let series else { nextInSeries = nil; return }
        let volumes = (try? await GoodreadsSeries.volumes(at: series.url)) ?? []
        nextInSeries = GoodreadsSeries.next(after: series.position, in: volumes)
    }

    /// A short line under the title; the full list is under Details.
    private var metaBits: [String] {
        var bits: [String] = []
        if let format = about?.format { bits.append(format) }
        if let pages = pageCount ?? book.pageCount { bits.append(String(localized: "\(pages) pages")) }
        if let year = (about?.firstPublished ?? about?.published).map({ $0.formatted(.dateTime.year()) })
            ?? book.publishedDate.map({ String($0.prefix(4)) }) {
            bits.append(year)
        }
        return bits
    }

    /// Books opened from a friend's update arrive without an author.
    private var authorName: String {
        book.author.isEmpty ? (about?.authorName ?? "") : book.author
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.secondary.opacity(0.15))
            .overlay(Image(systemName: "book.closed").font(.system(size: 24)).foregroundStyle(.tertiary))
    }

    // MARK: - Friends

    @ViewBuilder
    private var friendsSection: some View {
        if let goodreadsID {
            let readers = FriendsBooks.friends(with: goodreadsID, in: model.friendsBooks)
            if !readers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Friends Who Read This")
                        .font(.system(size: 12, weight: .semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(readers) { friendChip($0) }
                        }
                    }
                }
            } else if let progress = model.friendsBooksProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if model.friendsBooks.isEmpty {
                Button {
                    Task { await model.syncFriendsBooks() }
                } label: {
                    Label("See which friends have read this", systemImage: "person.2")
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .help("Reads your friends’ Read and Currently Reading shelves once; refreshed every few days")
            }
        }
    }

    private func friendChip(_ friend: FriendReading) -> some View {
        Button {
            if let url = friend.profileURL { Task { await model.openFriendProfile(url) } }
        } label: {
            HStack(spacing: 6) {
                CachedAsyncImage(url: friend.avatarURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Circle().fill(Color.secondary.opacity(0.2))
                    }
                }
                .frame(width: 22, height: 22)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(friend.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Group {
                        switch friend.book.state {
                        case .reading:
                            Text("Reading now")
                        case .read:
                            if let rating = friend.book.rating {
                                Text(String(repeating: "★", count: rating)).foregroundStyle(.orange)
                            } else {
                                Text("Read it")
                            }
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.secondary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText(friend)))
    }

    private func accessibilityText(_ friend: FriendReading) -> String {
        switch friend.book.state {
        case .reading: return String(localized: "\(friend.name), reading it now")
        case .read:
            if let rating = friend.book.rating { return String(localized: "\(friend.name), rated it \(rating) stars") }
            return String(localized: "\(friend.name), read it")
        }
    }

    // MARK: - Notes

    /// Notes are filed under the Goodreads id, so they're found again from
    /// any shelf or search result. A book Goodreads doesn't know falls back
    /// to its own id.
    private var noteKey: String? {
        goodreadsID ?? (resolveError != nil ? book.id : nil)
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("My Notes")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Only on this Mac")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            TextEditor(text: $note.text)
                .font(.system(size: 12))
                .frame(minHeight: 54, maxHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                .disabled(!noteLoaded)
                .accessibilityLabel(Text("My notes"))

            ForEach(Array(note.quotes.enumerated()), id: \.offset) { index, quote in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(quote)
                        .font(.system(size: 12).italic())
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        note.quotes.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Remove quote"))
                }
            }

            HStack {
                TextField("Add a quote", text: $newQuote, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .onSubmit(addQuote)
                Button("Add", action: addQuote)
                    .disabled(newQuote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !noteLoaded)
            }
        }
    }

    private func addQuote() {
        let quote = newQuote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty, noteLoaded else { return }
        note.quotes.append(quote)
        newQuote = ""
    }

    // MARK: - Compose

    private var composeBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your rating")
                .font(.system(size: 12, weight: .semibold))

            StarPicker(rating: $rating)

            TextField("Review (optional)", text: $reviewText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            HStack {
                Spacer()
                if isPosting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Post") { Task { await post() } }
                        .disabled(rating == 0 || goodreadsID == nil)
                }
            }
        }
    }

    private func post() async {
        guard let goodreadsID else { return }
        isPosting = true
        defer { isPosting = false }

        await model.finish(bookID: goodreadsID, title: book.title,
                           rating: rating, dateRead: Date(), note: reviewText)
        reviewText = ""
        await loadReviews(bookID: goodreadsID)
    }

    // MARK: - Reviews

    private var reviewsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Goodreads Reviews")
                    .font(.system(size: 12, weight: .semibold))
                if isLoadingReviews {
                    ProgressView().controlSize(.small)
                }
            }

            if let reviewsError {
                Text(reviewsError)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if reviews.isEmpty && !isLoadingReviews {
                Text("No reviews to show yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(reviews) { review in
                        ReviewRow(review: review)
                    }
                }
            }
        }
    }

    // MARK: - Loading

    private func resolveAndLoad() async {
        do {
            let id = try await GoodreadsLookup.bookID(for: book)
            goodreadsID = id
            await loadReviews(bookID: id)
        } catch {
            resolveError = String(localized: "Couldn't find this book on Goodreads.")
        }
    }

    private func loadReviews(bookID: String) async {
        isLoadingReviews = true
        defer { isLoadingReviews = false }

        do {
            // A book seen before opens with its reviews already there.
            try await DataCache.load("book-page", bookID, ttl: DataCache.TTL.bookPage) {
                try await GoodreadsBookPage.fetch(bookID: bookID)
            } show: { detail, _ in
                apply(detail)
            }
            // Pages saved before the app read synopses and publishers get
            // fetched again once, so those show up straight away.
            if about == nil {
                try await DataCache.load("book-page", bookID, ttl: DataCache.TTL.bookPage, force: true) {
                    try await GoodreadsBookPage.fetch(bookID: bookID)
                } show: { detail, _ in
                    apply(detail)
                }
            }
        } catch {
            reviewsError = String(localized: "Couldn't load reviews: \(error.localizedDescription)")
        }
    }

    private func apply(_ detail: GoodreadsBookPage.Detail) {
        reviews = detail.reviews
        pageLanguage = detail.language
        authorURL = detail.authorURL
        series = detail.series
        about = detail.about
        genres = detail.genres ?? []
        pageCount = detail.pageCount
        reviewsError = nil
    }
}

private struct ReviewRow: View {
    let review: GoodreadsBookPage.Review

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CachedAsyncImage(url: review.reviewerAvatarURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Circle().fill(Color.secondary.opacity(0.2))
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(review.reviewerName)
                        .font(.system(size: 12, weight: .medium))
                    if let rating = review.rating {
                        Text(String(repeating: "★", count: rating))
                            .font(.system(size: 11))
                            .foregroundStyle(.yellow)
                            .accessibilityLabel(Text("\(rating) stars"))
                    }
                }
                Text(review.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
                if let likes = review.likeCount, likes > 0 {
                    Text("\(likes) likes")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// The book's cover, blurred and faded behind the top of the sheet — gives
/// the glass header something to refract, the way Apple's own apps do.
private struct CoverBackdrop: View {
    let url: URL?

    var body: some View {
        if hasLiquidGlass, let url {
            CachedAsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.clear
                }
            }
            .frame(height: 260)
            .frame(maxWidth: .infinity)
            .clipped()
            .blur(radius: 40)
            .opacity(0.55)
            .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
