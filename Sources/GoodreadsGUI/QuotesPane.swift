import SwiftUI
import UniformTypeIdentifiers

/// Every quote and highlight you've saved, across all your books.
struct SavedQuote: Identifiable, Equatable, Sendable {
    let bookID: String
    let index: Int
    let text: String
    var id: String { "\(bookID)#\(index)" }
}

struct QuoteBook: Identifiable, Equatable, Sendable {
    let bookID: String
    let title: String
    let author: String
    let coverURL: URL?
    let quotes: [SavedQuote]
    let updated: Date
    /// What you wrote in the book's notes, if anything.
    var note: String = ""
    var id: String { bookID }
}

enum QuoteLibrary {
    /// Books with quotes, most recently changed first, named from your
    /// shelves or — for books not on one — the saved book page.
    static func books(notes: [String: BookNote], shelves: [ShelfEntry],
                      titles: [String: (String, String)] = [:]) -> [QuoteBook] {
        let entries = Dictionary(shelves.map { ($0.bookID, $0) }, uniquingKeysWith: { first, _ in first })
        return notes.compactMap { bookID, note -> QuoteBook? in
            guard !note.isEmpty else { return nil }
            let entry = entries[bookID]
            let fallback = titles[bookID]
            return QuoteBook(
                bookID: bookID,
                title: entry?.title ?? fallback?.0 ?? String(localized: "Unknown book"),
                author: entry?.author ?? fallback?.1 ?? "",
                coverURL: entry?.coverURL,
                quotes: note.quotes.enumerated().map { SavedQuote(bookID: bookID, index: $0.offset, text: $0.element) },
                updated: note.updated,
                note: note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        .sorted { $0.updated > $1.updated }
    }

    static func filter(_ books: [QuoteBook], _ term: String) -> [QuoteBook] {
        let needle = term.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return books }
        return books.compactMap { book in
            if book.title.localizedCaseInsensitiveContains(needle) || book.author.localizedCaseInsensitiveContains(needle) {
                return book
            }
            let quotes = book.quotes.filter { $0.text.localizedCaseInsensitiveContains(needle) }
            let noteMatches = book.note.localizedCaseInsensitiveContains(needle)
            guard !quotes.isEmpty || noteMatches else { return nil }
            return QuoteBook(bookID: book.bookID, title: book.title, author: book.author,
                             coverURL: book.coverURL, quotes: quotes, updated: book.updated,
                             note: noteMatches ? book.note : "")
        }
    }
}

struct QuotesPane: View {
    @ObservedObject var model: LibraryModel
    @State private var books: [QuoteBook] = []
    @State private var search = ""
    @State private var sharing: (QuoteBook, SavedQuote)?
    @State private var loaded = false

    var body: some View {
        let shown = QuoteLibrary.filter(books, search)
        Group {
            if books.isEmpty {
                EmptyQuotes(loaded: loaded)
            } else if shown.isEmpty {
                VStack { Spacer(); Text("Nothing matches “\(search)”.").foregroundStyle(.secondary); Spacer() }
                    .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(shown) { book in
                        Section {
                            if !book.note.isEmpty {
                                Text(book.note)
                                    .appFont(size: 12)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.vertical, 2)
                            }
                            ForEach(book.quotes) { quote in
                                quoteRow(quote, in: book)
                            }
                        } header: {
                            bookHeader(book)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Notes")
        .navigationSubtitle(books.isEmpty ? "" : String(localized: "\(books.reduce(0) { $0 + $1.quotes.count }) quotes from \(books.count) books"))
        .searchable(text: $search, placement: .toolbar, prompt: "Search notes and quotes")
        .task { await load() }
        .sheet(item: Binding(
            get: { sharing.map { QuoteShare(book: $0.0, quote: $0.1) } },
            set: { if $0 == nil { sharing = nil } }
        )) { share in
            QuoteImageSheet(book: share.book, quote: share.quote)
        }
    }

    private func load() async {
        let notes = await BookNotes.all()
        let shelfEntries = model.shelves.flatMap { ShelfCache.read($0)?.entries ?? [] }
        var titles: [String: (String, String)] = [:]
        let known = Set(shelfEntries.map(\.bookID))
        for (bookID, note) in notes where !note.isEmpty && !known.contains(bookID) {
            if let detail = await DataCache.shared.read(GoodreadsBookPage.Detail.self, "book-page", bookID, ttl: .infinity)?.value,
               let title = detail.about?.title {
                titles[bookID] = (title, detail.about?.authorName ?? "")
            }
        }
        books = QuoteLibrary.books(notes: notes, shelves: shelfEntries, titles: titles)
        loaded = true
    }

    private func bookHeader(_ book: QuoteBook) -> some View {
        Button {
            model.showBookDetail(Book(id: book.bookID, title: book.title, author: book.author,
                                      coverURL: book.coverURL, rating: nil, goodreadsID: book.bookID))
        } label: {
            HStack(spacing: 8) {
                CachedAsyncImage(url: book.coverURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.15))
                    }
                }
                .frame(width: 20, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                VStack(alignment: .leading, spacing: 0) {
                    Text(book.title).appFont(size: 12, weight: .semibold).foregroundStyle(.primary)
                    if !book.author.isEmpty {
                        Text(book.author).appFont(size: 11).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("View Details")
    }

    private func quoteRow(_ quote: SavedQuote, in book: QuoteBook) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "quote.opening")
                .appFont(size: 10)
                .foregroundStyle(.secondary)
                .padding(.top, 3)
            Text(quote.text)
                .appFont(size: 13, italic: true)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Menu {
                Button("Copy") { copy(quote, from: book) }
                Button("Share as Image…") { sharing = (book, quote) }
                Divider()
                Button("View Details…") {
                    model.showBookDetail(Book(id: book.bookID, title: book.title, author: book.author,
                                              coverURL: book.coverURL, rating: nil, goodreadsID: book.bookID))
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Actions for this quote"))
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy") { copy(quote, from: book) }
            Button("Share as Image…") { sharing = (book, quote) }
        }
    }

    private func copy(_ quote: SavedQuote, from book: QuoteBook) {
        let attribution = [book.title, book.author].filter { !$0.isEmpty }.joined(separator: ", ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("“\(quote.text)” — \(attribution)", forType: .string)
        model.status = .init(text: String(localized: "Copied the quote."), isError: false)
    }
}

private struct QuoteShare: Identifiable {
    let book: QuoteBook
    let quote: SavedQuote
    var id: String { quote.id }
}

private struct EmptyQuotes: View {
    let loaded: Bool
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "quote.bubble")
                .appFont(size: 40)
                .foregroundStyle(.tertiary)
            Text(loaded ? String(localized: "Quotes you save in a book’s notes, or import with File → Import Highlights, show up here.")
                        : String(localized: "Loading…"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// A quote as a card, to save or share — fixed colours and sizes so the
/// image looks the same everywhere.
struct QuoteCard: View {
    let quote: String
    let title: String
    let author: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "quote.opening")
                .font(.system(size: 28, weight: .bold))
                .opacity(0.5)
            Text(quote)
                .font(.system(size: quote.count > 280 ? 19 : 24, weight: .medium, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if !author.isEmpty { Text(author).font(.system(size: 13)).opacity(0.75) }
            }
        }
        .foregroundStyle(.white)
        .padding(36)
        .frame(width: 560, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 0.36, green: 0.22, blue: 0.13),
                                    Color(red: 0.62, green: 0.39, blue: 0.20)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

private struct QuoteImageSheet: View {
    @Environment(\.dismiss) private var dismiss
    let book: QuoteBook
    let quote: SavedQuote
    @State private var png: Data?
    @State private var message: String?

    private var card: QuoteCard { QuoteCard(quote: quote.text, title: book.title, author: book.author) }

    var body: some View {
        VStack(spacing: 0) {
            GlassHeader {
                Text("Share Quote").appFont(size: 13, weight: .semibold)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .glassButton()
            }
            ScrollView {
                card.padding(20)
            }
            HStack {
                if let message { Text(message).appFont(size: 11).foregroundStyle(.secondary) }
                Spacer()
                if let png, let image = NSImage(data: png) {
                    ShareLink(item: Image(nsImage: image), preview: SharePreview(book.title, image: Image(nsImage: image))) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    .glassButton()
                }
                Button("Save Image…", action: save)
                    .keyboardShortcut(.defaultAction)
                    .glassProminentButton()
                    .disabled(png == nil)
            }
            .padding(12)
        }
        .frame(width: 620, height: 520)
        .task { png = render() }
    }

    private func render() -> Data? {
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    private func save() {
        guard let png else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "quote.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
            message = String(localized: "Saved \(url.lastPathComponent).")
        } catch {
            message = error.localizedDescription
        }
    }
}
