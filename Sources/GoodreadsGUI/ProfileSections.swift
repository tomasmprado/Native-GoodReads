import SwiftUI

/// The parts of a profile beyond name and stats, in the profile sheet.
struct ProfileSections: View {
    @ObservedObject var model: LibraryModel
    let details: ProfileDetails
    let firstName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !details.rows.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(details.rows, id: \.self) { row in
                        GridRow {
                            Text(row.title).appFont(size: 11).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(row.value).appFont(size: 11).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let challenge = details.challenge {
                VStack(alignment: .leading, spacing: 4) {
                    Text(challenge.year.map { String(localized: "\(String($0)) Reading Challenge") } ?? String(localized: "Reading Challenge"))
                        .appFont(size: 12, weight: .semibold)
                    ProgressView(value: Double(min(challenge.read, challenge.goal)), total: Double(challenge.goal))
                    Text(String(localized: "\(challenge.read) of \(challenge.goal) books"))
                        .appFont(size: 11).foregroundStyle(.secondary)
                }
            }

            if !details.favouriteGenres.isEmpty {
                section(String(localized: "Favourite Genres")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(details.favouriteGenres, id: \.self) { genre in
                                Text(GenreNames.display(genre))
                                    .appFont(size: 11)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            }
                        }
                    }
                }
            }

            if !details.currentlyReading.isEmpty {
                section(String(localized: "\(firstName) Is Reading")) { books(details.currentlyReading) }
            }
            if !details.favouriteBooks.isEmpty {
                section(String(localized: "\(firstName)’s Favourite Books")) { books(details.favouriteBooks) }
            }

            if details.shelves.count > 3 {
                section(String(localized: "Shelves")) {
                    FlowShelves(shelves: details.shelves) { link in
                        Task { await model.openFriendShelf(Shelf(name: link.name, label: link.name)) }
                    }
                }
            }

            if !details.quotes.isEmpty {
                section(String(localized: "Quotes")) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(details.quotes.prefix(5)) { quote in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(quote.text).appFont(size: 12, italic: true).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let by = quote.attribution {
                                    Text("— \(by)").appFont(size: 11).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            if !details.friends.isEmpty {
                section(details.friendCount.map { String(localized: "Friends (\($0))") } ?? String(localized: "Friends")) {
                    people(details.friends)
                }
            }
            if !details.following.isEmpty {
                section(String(localized: "Following")) { people(details.following) }
            }

            HStack(spacing: 12) {
                if let url = details.yearInBooksURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label(String(localized: "\(firstName)’s Year in Books"), systemImage: "gift")
                    }
                    .buttonStyle(.link)
                    .appFont(size: 11)
                }
            }

            if details.isRestricted && details.rows.isEmpty {
                Label("\(firstName) shares some of their profile only with friends.", systemImage: "lock")
                    .appFont(size: 11)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).appFont(size: 12, weight: .semibold).foregroundStyle(.secondary)
            content()
        }
    }

    private func books(_ list: [ProfileDetails.BookLink]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(list) { book in
                    Button {
                        model.showBookDetail(Book(id: "gr:\(book.bookID)", title: book.title, author: book.author ?? "",
                                                  coverURL: book.coverURL, rating: nil, goodreadsID: book.bookID))
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            CachedAsyncImage(url: book.coverURL) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
                                        .overlay(Image(systemName: "book.closed").foregroundStyle(.tertiary))
                                }
                            }
                            .frame(width: 64, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(book.title).appFont(size: 10, weight: .medium).lineLimit(2)
                                .frame(width: 64, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(book.author.map { "\(book.title) — \($0)" } ?? book.title)
                }
            }
        }
    }

    private func people(_ list: [ProfileDetails.Person]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(list) { person in
                    Button {
                        if person.isAuthor {
                            model.showAuthorPage(person.url)
                        } else {
                            Task { await model.openFriendProfile(person.url) }
                        }
                    } label: {
                        VStack(spacing: 3) {
                            CachedAsyncImage(url: person.avatarURL) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Circle().fill(Color.secondary.opacity(0.2))
                                }
                            }
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())
                            Text(person.name).appFont(size: 10).lineLimit(1).frame(width: 60)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(person.name)
                }
            }
        }
    }
}

/// Shelf chips that wrap onto new lines.
private struct FlowShelves: View {
    let shelves: [ProfileDetails.ShelfLink]
    let open: (ProfileDetails.ShelfLink) -> Void

    var body: some View {
        // A simple wrap: rows of up to four chips.
        let rows = stride(from: 0, to: shelves.count, by: 4).map { Array(shelves[$0..<min($0 + 4, shelves.count)]) }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.prefix(6), id: \.first?.id) { row in
                HStack(spacing: 6) {
                    ForEach(row) { shelf in
                        Button {
                            open(shelf)
                        } label: {
                            HStack(spacing: 4) {
                                Text(Shelf(name: shelf.name, label: shelf.name).title).appFont(size: 11)
                                if let count = shelf.count {
                                    Text("\(count)").appFont(size: 10).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Long text that shows a few lines until "Show More".
struct ExpandableText: View {
    let text: String
    var lines = 6
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .appFont(size: 12)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : lines)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if text.count > 400 {
                Button(expanded ? String(localized: "Show Less") : String(localized: "Show More")) {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
                .buttonStyle(.link)
                .appFont(size: 11)
            }
        }
    }
}

/// An author's series; choosing one lists its books, read from the series page.
struct AuthorSeriesList: View {
    @ObservedObject var model: LibraryModel
    let series: [GoodreadsAuthorPage.SeriesLink]
    let author: String
    @State private var open: GoodreadsAuthorPage.SeriesLink?
    @State private var volumes: [GoodreadsSeries.Volume] = []
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Series").appFont(size: 12, weight: .semibold).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(series) { item in
                        Button {
                            Task { await toggle(item) }
                        } label: {
                            Text(item.title)
                                .appFont(size: 11)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(open == item ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if open != nil {
                if loading {
                    ProgressView().controlSize(.small)
                } else if volumes.isEmpty {
                    Text("Couldn’t read this series.").appFont(size: 11).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(volumes, id: \.bookID) { volume in
                            Button {
                                model.showBookDetail(volume.asBook)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(volume.position.map { "#\($0.formatted())" } ?? "–")
                                        .appFont(size: 11).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                                    Text(volume.title).appFont(size: 12).foregroundStyle(.primary).lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ item: GoodreadsAuthorPage.SeriesLink) async {
        if open == item { open = nil; return }
        open = item
        loading = true
        volumes = (try? await GoodreadsSeries.volumes(at: item.url)) ?? []
        loading = false
    }
}

/// "Wikipedia", when the author has an article.
struct WikipediaLink: View {
    let name: String
    @State private var article: AuthorWikipedia.Article?

    var body: some View {
        Group {
            if let article {
                Button("Wikipedia") { NSWorkspace.shared.open(article.url) }
                    .appFont(size: 11)
                    .buttonStyle(.link)
                    .help(article.description.map { "\($0) — \(article.url.host ?? "")" } ?? article.url.absoluteString)
            }
        }
        .task(id: name) { article = await AuthorWikipedia.article(for: name) }
    }
}
