import SwiftUI

/// A book you stopped reading. Goodreads has no such shelf, so the record
/// is kept on this Mac (and in backups); the book itself goes wherever you
/// choose on Goodreads.
struct AbandonedBook: Codable, Sendable, Equatable, Identifiable {
    let bookID: String
    let title: String
    let author: String
    let coverURLString: String?
    var date: Date
    var reason: String
    /// How far you got, when known.
    var percent: Int?

    var id: String { bookID }
    var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }

    init(entry: ShelfEntry, reason: String, date: Date = Date()) {
        bookID = entry.bookID
        title = entry.title
        author = entry.author
        coverURLString = entry.coverURLString
        self.date = date
        self.reason = reason
        percent = entry.progress
    }

    var asEntry: ShelfEntry {
        ShelfEntry(id: bookID, bookID: bookID, reviewID: nil, title: title, author: author,
                   coverURLString: coverURLString, progress: percent)
    }
}

enum AbandonedBooks {
    private static let namespace = "abandoned"
    private static let key = "all"

    static func all() async -> [String: AbandonedBook] {
        await DataCache.shared.read([String: AbandonedBook].self, namespace, key, ttl: .infinity)?.value ?? [:]
    }

    static func add(_ book: AbandonedBook) async {
        await DataCache.shared.modify([String: AbandonedBook].self, namespace, key, default: [:]) {
            $0[book.bookID] = book
        }
    }

    static func remove(bookID: String) async {
        await DataCache.shared.modify([String: AbandonedBook].self, namespace, key, default: [:]) {
            $0[bookID] = nil
        }
    }

    /// Newest first, optionally only one year's.
    static func sorted(_ all: [String: AbandonedBook], year: Int? = nil,
                       calendar: Calendar = .current) -> [AbandonedBook] {
        all.values
            .filter { year == nil || calendar.component(.year, from: $0.date) == year }
            .sorted { $0.date > $1.date }
    }

    /// A custom shelf that already means "did not finish", if you have one.
    static func dnfShelf(in shelves: [Shelf]) -> Shelf? {
        let names = ["dnf", "did-not-finish", "abandoned", "abandonados", "nao-terminei", "não-terminei",
                     "gave-up", "unfinished", "stopped-reading"]
        return shelves.first { shelf in
            !shelf.isBuiltIn && names.contains(shelf.name.lowercased())
        }
    }

    /// Where the book goes on Goodreads.
    enum Destination: String, CaseIterable, Identifiable {
        case wantToRead
        case remove

        var id: String { rawValue }

        var title: String {
            switch self {
            case .wantToRead: return String(localized: "Move to Want to Read")
            case .remove:     return String(localized: "Remove from my Goodreads shelves")
            }
        }
    }
}

/// Asks why, and where the book should go on Goodreads.
struct AbandonSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: ShelfEntry
    let dnfShelf: Shelf?
    let commit: (_ reason: String, _ destination: AbandonedBooks.Destination, _ alsoShelf: Shelf?) -> Void

    @State private var reason = ""
    @State private var destination: AbandonedBooks.Destination = .wantToRead
    @State private var addToShelf = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stop Reading")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(entry.title) — \(entry.author)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            TextField("Why? (optional)", text: $reason, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)

            Picker("On Goodreads", selection: $destination) {
                ForEach(AbandonedBooks.Destination.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)

            if let dnfShelf {
                Toggle("Also add to “\(dnfShelf.title)”", isOn: $addToShelf)
                    .toggleStyle(.checkbox)
                    .disabled(destination == .remove)
            }

            Text("The app keeps a list of the books you stopped, with how far you got, under Stats. They don’t count as read.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Stop Reading") {
                    commit(reason.trimmingCharacters(in: .whitespacesAndNewlines), destination,
                           destination == .remove || !addToShelf ? nil : dnfShelf)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// The Stats card listing the books you stopped.
struct AbandonedCard: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        let books = AbandonedBooks.sorted(model.abandoned)
        if !books.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                let thisYear = AbandonedBooks.sorted(model.abandoned,
                                                     year: Calendar.current.component(.year, from: Date())).count
                HStack {
                    Text("Stopped Reading")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(thisYear) this year")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                ForEach(books.prefix(12)) { book in
                    HStack(spacing: 10) {
                        CachedAsyncImage(url: book.coverURL) { phase in
                            if case .success(let image) = phase {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                            }
                        }
                        .frame(width: 28, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(book.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(detail(book))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Menu {
                            Button("Resume Reading") { Task { await model.resumeAbandoned(book) } }
                            Button("View Details…") { model.showBookDetail(book.asEntry.asBook) }
                            Divider()
                            Button("Forget", role: .destructive) { Task { await model.forgetAbandoned(book) } }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel(Text("Actions for \(book.title)"))
                    }
                }
            }
            .padding(14)
            .glassCard(cornerRadius: 14)
        }
    }

    private func detail(_ book: AbandonedBook) -> String {
        var bits = [book.author, book.date.formatted(date: .abbreviated, time: .omitted)]
        if let percent = book.percent { bits.append(String(localized: "stopped at \(percent)%")) }
        if !book.reason.isEmpty { bits.append(book.reason) }
        return bits.joined(separator: " · ")
    }
}
