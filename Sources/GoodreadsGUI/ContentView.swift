import SwiftUI

struct ContentView: View {
    @ObservedObject private var model = LibraryModel.shared
    @ObservedObject private var session = WebSession.shared

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                switch model.selection {
                case .home:        HomePane(model: model)
                case .search:      SearchPane(model: model)
                case .suggestions: SuggestionsPane(model: model)
                case .friends:     FriendsPane(model: model)
                case .shelf:       ShelfPane(model: model)
                }
                Divider()
                StatusBar(model: model, session: session)
            }
            .frame(minWidth: 480, minHeight: 420)
        }
        .task {
            await model.checkSession()
            if model.isHome {
                await model.buildSuggestions()
                await model.loadCurrentlyReading()
            }
        }
        .onChange(of: model.selection) { _ in Task { await model.paneChanged() } }
        .sheet(isPresented: Binding(
            get: { model.webSheet == .signIn },
            set: { if !$0 { model.webSheet = nil } }
        ), onDismiss: {
            Task { await model.signInSheetClosed() }
        }) {
            SignInSheet()
        }
        .sheet(isPresented: Binding(
            get: { model.webSheet == .browser },
            set: { if !$0 { model.webSheet = nil } }
        )) {
            BrowserSheet(isPresented: Binding(
                get: { model.webSheet == .browser },
                set: { if !$0 { model.webSheet = nil } }
            ))
        }
        .sheet(isPresented: $model.showDiagnostics) {
            DiagnosticsSheet(isPresented: $model.showDiagnostics)
        }
        .sheet(item: $model.progressTarget) { entry in
            ProgressSheet(entry: entry) { percent, page, note in
                Task { await model.updateProgress(entry, percent: percent, page: page, note: note) }
            }
        }
        .sheet(item: $model.finishTarget) { entry in
            FinishSheet(title: entry.title, author: entry.author) { rating, date, note in
                Task {
                    await model.finish(bookID: entry.bookID, title: entry.title,
                                       rating: rating, dateRead: date, note: note)
                }
            }
        }
        .sheet(item: $model.finishBook) { book in
            FinishSheet(title: book.title, author: book.author) { rating, date, note in
                Task {
                    await model.finishBook(book, rating: rating, dateRead: date, note: note)
                }
            }
        }
        .sheet(item: $model.detailBook) { book in
            BookDetailView(book: book)
        }
        .sheet(isPresented: Binding(
            get: { model.friendProfileURL != nil },
            set: { if !$0 { model.friendProfileURL = nil } }
        )) {
            FriendProfileSheet(model: model)
        }
        .sheet(isPresented: Binding(
            get: { model.authorPageURL != nil },
            set: { if !$0 { model.authorPageURL = nil } }
        )) {
            AuthorPageSheet(model: model)
        }
    }

    private var sidebar: some View {
        List(selection: $model.selection) {
            Label("Home", systemImage: "house")
                .tag(LibraryModel.Pane.home)

            Label("Search", systemImage: "magnifyingglass")
                .tag(LibraryModel.Pane.search)

            Label("Suggestions", systemImage: "sparkles")
                .tag(LibraryModel.Pane.suggestions)

            Label("Friends", systemImage: "person.2")
                .tag(LibraryModel.Pane.friends)

            Section("Shelves") {
                ForEach(model.shelves) { shelf in
                    HStack {
                        Label(shelf.label, systemImage: shelf.symbol)
                        Spacer()
                        if let count = shelf.count {
                            Text("\(count)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .tag(LibraryModel.Pane.shelf(shelf.name))
                }
            }
        }
        .frame(minWidth: 190)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                if model.isExporting, let note = model.exportProgress {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await model.exportEverything() }
                } label: {
                    if model.isExporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Export Library…", systemImage: "square.and.arrow.down")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.isExporting)
                .help("Fetch every shelf and save one CSV")
            }
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Home

/// A calm landing screen — an animated welcome, the app's own icon, what
/// you're currently reading, and one pick for what's next. Suggestions live
/// in their own section now; this only ever shows the single top pick.
private struct HomePane: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 10)

            TypewriterText(text: "Welcome to Goodreads", font: .system(size: 22, weight: .semibold))

            AppLogoImage()

            if !model.currentlyReading.isEmpty {
                CurrentlyReadingCarousel(model: model)
            } else if model.isLoadingCurrentlyReading {
                ProgressView().controlSize(.small)
            } else {
                Text("Nothing on Currently Reading yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) { ReadNextCard(model: model) }
    }
}

/// Reveals `text` a character at a time, replaying on every appearance —
/// `.task` re-runs whenever this view comes back on screen, since Home is
/// recreated each time the sidebar selection returns to it.
private struct TypewriterText: View {
    let text: String
    let font: Font

    @State private var shown = ""

    var body: some View {
        Text(shown)
            .font(font)
            .task {
                shown = ""
                for character in text {
                    shown.append(character)
                    try? await Task.sleep(for: .milliseconds(45))
                }
            }
    }
}

private struct AppLogoImage: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
        } else {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
        }
    }
}

/// One book — the top-ranked suggestion — pinned in the corner with a
/// one-tap way to start it, so Home surfaces a pick without becoming a list.
private struct ReadNextCard: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        if let suggestion = model.suggestions.first {
            VStack(alignment: .leading, spacing: 8) {
                Text("Read Next")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    coverImage(suggestion.book.coverURL)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.book.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                        Text(suggestion.book.author)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if model.busyBookID == suggestion.book.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Add to Currently Reading") {
                        Task { await model.shelve(suggestion.book, to: .currentlyReading) }
                    }
                    .font(.system(size: 11))
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            .frame(width: 220)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 4)
            .padding(16)
        }
    }

    @ViewBuilder
    private func coverImage(_ url: URL?) -> some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 34, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.secondary.opacity(0.15))
            .overlay(Image(systemName: "book.closed").font(.system(size: 12)).foregroundStyle(.tertiary))
    }
}

// MARK: - Suggestions

private struct SuggestionsPane: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Suggestions")
                    .font(.system(size: 13, weight: .semibold))

                if !model.suggestionBasis.isEmpty {
                    Text("from \(model.suggestionBasis.count) finished in \(prefs.suggestionWindowDays) days")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if prefs.bookLanguage != .any {
                    Text(prefs.bookLanguage.label)
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }

                if model.isBuildingSuggestions {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await model.buildSuggestions(force: true) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Rebuild suggestions")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if model.suggestions.isEmpty {
                EmptyPane(symbol: model.isBuildingSuggestions ? "hourglass" : "sparkles",
                          text: model.suggestionNote ?? "Nothing to suggest yet.")
            } else {
                List(model.suggestions) { suggestion in
                    BookRow(
                        title: suggestion.book.title,
                        author: suggestion.book.author,
                        cover: suggestion.book.coverURL,
                        detail: detailLine(suggestion.reason, publisher: suggestion.book.publisher),
                        stars: nil,
                        isBusy: model.busyBookID == suggestion.book.id
                    ) {
                        ForEach(model.shelves) { shelf in
                            Button {
                                Task { await model.shelve(suggestion.book, to: shelf) }
                            } label: {
                                Label(shelf.label, systemImage: shelf.symbol)
                            }
                        }
                        Divider()
                        Button("View Details…") { model.showBookDetail(suggestion.book) }
                        Button("Open on Goodreads") { Task { await model.openOnGoodreads(suggestion.book) } }
                    }
                }
                .listStyle(.inset)
            }

            if let note = model.suggestionNote, !model.suggestions.isEmpty {
                Divider()
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
        }
    }
}

// MARK: - Friends

/// One friend's recent activity, up to five books, grouped from the flat
/// scrape result — preserves the order friends first appear in the feed.
private struct FriendGroup: Identifiable {
    let id: String
    let name: String
    let avatarURL: URL?
    let profileURL: URL?
    let items: [GoodreadsFriends.Activity]
}

private struct FriendsPane: View {
    @ObservedObject var model: LibraryModel

    private var groups: [FriendGroup] {
        var order: [String] = []
        var byFriend: [String: [GoodreadsFriends.Activity]] = [:]

        for item in model.friendActivity {
            let key = item.friendProfileURL?.absoluteString ?? item.friendName
            if byFriend[key] == nil {
                byFriend[key] = []
                order.append(key)
            }
            if byFriend[key]!.count < 5 {
                byFriend[key]!.append(item)
            }
        }

        return order.compactMap { key in
            guard let items = byFriend[key], let first = items.first else { return nil }
            return FriendGroup(id: key, name: first.friendName,
                               avatarURL: model.avatarURL(forFriendProfile: first.friendProfileURL),
                               profileURL: first.friendProfileURL, items: items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Friends")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.isLoadingFriends {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await model.loadFriends(force: true) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            let groups = groups
            if !groups.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(groups) { group in
                            FriendSection(model: model, group: group)
                        }
                    }
                    .padding(14)
                }
            } else if !model.friends.isEmpty {
                // The home feed's activity table came back empty — Goodreads
                // seems to have restructured it. Fall back to each friend's
                // own status line from `/friend`, which does still parse.
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.friends) { friend in
                            FriendStatusRow(model: model, friend: friend)
                            if friend.id != model.friends.last?.id { Divider() }
                        }
                    }
                    .padding(.vertical, 8)
                }
            } else {
                EmptyPane(symbol: model.isLoadingFriends ? "hourglass" : "person.2",
                          text: model.friendsNote ?? "No friends found yet.")
            }
        }
    }
}

private struct FriendStatusRow: View {
    @ObservedObject var model: LibraryModel
    let friend: GoodreadsFriends.Friend

    var body: some View {
        Button {
            guard let url = friend.profileURL else { return }
            Task { await model.openFriendProfile(url) }
        } label: {
            HStack(spacing: 10) {
                AsyncImage(url: friend.avatarURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Circle().fill(Color.secondary.opacity(0.15))
                    }
                }
                .frame(width: 30, height: 30)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    if let label = friend.statusLabel, let title = friend.statusBookTitle {
                        Text("\(label) \(title)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let title = friend.statusBookTitle {
                        Text(title)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("No current status")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 8)

                if let cover = friend.statusCoverURL {
                    AsyncImage(url: cover) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                    .frame(width: 24, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(friend.profileURL == nil ? "" : "See \(friend.name)’s profile")
    }
}

private struct FriendSection: View {
    @ObservedObject var model: LibraryModel
    let group: FriendGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                guard let url = group.profileURL else { return }
                Task { await model.openFriendProfile(url) }
            } label: {
                HStack(spacing: 8) {
                    AsyncImage(url: group.avatarURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Circle().fill(Color.secondary.opacity(0.15))
                        }
                    }
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())

                    Text(group.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help("See \(group.name)’s profile")

            VStack(spacing: 0) {
                ForEach(group.items) { item in
                    FriendActivityRow(item: item)
                    if item.id != group.items.last?.id { Divider() }
                }
            }
            .padding(.leading, 4)
        }
    }
}

private struct FriendActivityRow: View {
    let item: GoodreadsFriends.Activity

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let cover = item.coverURL {
                    AsyncImage(url: cover) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 30, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            VStack(alignment: .leading, spacing: 2) {
                if let title = item.bookTitle {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                }

                HStack(spacing: 5) {
                    Text(item.action)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    if let rating = item.rating {
                        Text(String(repeating: "★", count: rating))
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow)
                    }
                }

                if let comment = item.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Friend profile

private struct FriendProfileSheet: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Profile")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)

            Divider()

            if model.isLoadingFriendProfile {
                EmptyPane(symbol: "hourglass", text: "Loading…")
            } else if let error = model.friendProfileError {
                EmptyPane(symbol: "exclamationmark.triangle", text: error)
            } else if let profile = model.friendProfile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            AsyncImage(url: profile.avatarURL) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Circle().fill(Color.secondary.opacity(0.15))
                                }
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name)
                                    .font(.system(size: 16, weight: .semibold))
                                if let stats = profile.stats {
                                    Text(stats)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                if let url = model.friendProfileURL {
                                    Button("Open on Goodreads") { NSWorkspace.shared.open(url) }
                                        .font(.system(size: 11))
                                        .buttonStyle(.link)
                                }
                            }
                        }

                        FriendCollectionsPicker(model: model)

                        if model.friendShelf != nil {
                            FriendShelfContent(model: model)
                        } else if !profile.activity.isEmpty {
                            Text("Recent Activity")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)

                            VStack(spacing: 0) {
                                ForEach(profile.activity.prefix(20)) { item in
                                    FriendActivityRow(item: item)
                                    if item.id != profile.activity.prefix(20).last?.id { Divider() }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 480, height: 620)
    }
}

/// Want to Read / Currently Reading / Read — a friend's collections, same as
/// the sidebar's own shelf list but scoped to their id.
private struct FriendCollectionsPicker: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Collections")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(Shelf.builtIn) { shelf in
                    let isSelected = model.friendShelf?.name == shelf.name
                    Button {
                        Task { await model.openFriendShelf(shelf) }
                    } label: {
                        Label(shelf.label, systemImage: shelf.symbol)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .tint(isSelected ? .accentColor : .secondary)
                }
            }
        }
    }
}

/// A friend's shelf, read back the same way the sidebar reads your own —
/// `ShelfLibrary.load(_:ofUser:)` — so their star ratings come along with it.
/// Read-only: no shelving actions against someone else's library.
private struct FriendShelfContent: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model.friendShelf?.label ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                if model.isLoadingFriendShelf {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Close") { model.closeFriendShelf() }
                    .font(.system(size: 11))
                    .buttonStyle(.link)
            }

            if let error = model.friendShelfError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if model.friendShelfEntries.isEmpty {
                Text(model.isLoadingFriendShelf ? "Loading…" : "Nothing on this shelf.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.friendShelfEntries) { entry in
                        BookRow(
                            title: entry.title,
                            author: entry.author,
                            cover: entry.coverURL,
                            detail: entry.dateRead.map { "read \($0)" },
                            stars: entry.rating,
                            isBusy: false
                        ) {
                            Button("View Details…") { model.showBookDetail(entry.asBook) }
                            Button("Open on Goodreads") { model.openOnGoodreads(bookID: entry.bookID) }
                        }
                        if entry.id != model.friendShelfEntries.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

// MARK: - Author page

private struct AuthorPageSheet: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Author")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)

            Divider()

            if model.isLoadingAuthorPage {
                EmptyPane(symbol: "hourglass", text: "Loading…")
            } else if let error = model.authorPageError {
                EmptyPane(symbol: "exclamationmark.triangle", text: error)
            } else if let author = model.authorPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 14) {
                            AsyncImage(url: author.photoURL) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Circle().fill(Color.secondary.opacity(0.15))
                                }
                            }
                            .frame(width: 80, height: 80)
                            .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 4) {
                                Text(author.name)
                                    .font(.system(size: 17, weight: .semibold))
                                if let born = author.born {
                                    Text("Born \(born)")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                if let genres = author.genres {
                                    Text(genres)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                if let avg = author.averageRating {
                                    Text("★ \(avg)" + (author.ratingsCount.map { " (\($0))" } ?? ""))
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                if let website = author.website {
                                    Button("Website") { NSWorkspace.shared.open(website) }
                                        .font(.system(size: 11))
                                        .buttonStyle(.link)
                                }
                            }
                        }

                        if let bio = author.bio, !bio.isEmpty {
                            Text(bio)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        if !author.books.isEmpty {
                            Divider()
                            Text("Books")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)

                            ForEach(author.books) { book in
                                Button {
                                    model.showBookDetail(Book(
                                        id: "gr:\(book.id)", title: book.title, author: author.name,
                                        coverURL: book.coverURL, rating: nil, goodreadsID: book.id
                                    ))
                                } label: {
                                    HStack(spacing: 10) {
                                        Group {
                                            if let cover = book.coverURL {
                                                AsyncImage(url: cover) { phase in
                                                    if case .success(let image) = phase {
                                                        image.resizable().aspectRatio(contentMode: .fill)
                                                    } else {
                                                        Color.secondary.opacity(0.15)
                                                    }
                                                }
                                            } else {
                                                Color.secondary.opacity(0.15)
                                            }
                                        }
                                        .frame(width: 30, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(book.title)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(.primary)
                                            if let line = book.ratingLine {
                                                Text(line)
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 480, height: 560)
    }
}

// MARK: - Search

private struct SearchFilterRow: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.searchLanguage) {
                ForEach(BookLanguage.allCases) { language in
                    Text(language.label).tag(language)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            .onChange(of: model.searchLanguage) { _ in model.filtersChanged() }

            Picker("", selection: $model.searchSortNewest) {
                Text("Relevance").tag(false)
                Text("Newest").tag(true)
            }
            .labelsHidden()
            .frame(width: 110)
            .onChange(of: model.searchSortNewest) { _ in model.filtersChanged() }

            HStack(spacing: 5) {
                Image(systemName: "bookmark").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("Subject", text: $model.searchSubject)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onChange(of: model.searchSubject) { _ in model.filtersChanged() }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(width: 130)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

private struct SearchPane: View {
    @ObservedObject var model: LibraryModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)

                TextField("Search Goodreads", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onChange(of: model.query) { _ in model.queryChanged() }
                    .onSubmit { model.searchNow() }

                if model.isSearching {
                    ProgressView().controlSize(.small)
                } else if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            SearchFilterRow(model: model)

            Divider()

            if model.results.isEmpty {
                EmptyPane(symbol: "books.vertical",
                          text: "Search for a book, then add it to a shelf.")
            } else {
                List(model.results) { book in
                    BookRow(
                        title: book.title,
                        author: book.author,
                        cover: book.coverURL,
                        detail: detailLine(book.rating.map { "★ \($0)" }, publisher: book.publisher),
                        stars: nil,
                        isBusy: model.busyBookID == book.id
                    ) {
                        ForEach(model.shelves) { shelf in
                            Button {
                                Task { await model.shelve(book, to: shelf) }
                            } label: {
                                Label(shelf.label, systemImage: shelf.symbol)
                            }
                        }
                        Divider()
                        Button {
                            model.finishBook = book
                        } label: {
                            Label("Mark Read & Rate…", systemImage: "star")
                        }
                        Button("View Details…") { model.showBookDetail(book) }
                        Button("Open on Goodreads") { Task { await model.openOnGoodreads(book) } }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Shelf

private struct ShelfPane: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if model.visibleEntries.isEmpty {
                EmptyPane(
                    symbol: model.isLoadingShelf ? "hourglass" : "tray",
                    text: emptyText
                )
            } else {
                List(model.visibleEntries) { entry in
                    BookRow(
                        title: entry.title,
                        author: entry.author,
                        cover: entry.coverURL,
                        detail: detailLine(entry),
                        stars: entry.rating,
                        isBusy: model.busyBookID == entry.bookID
                    ) {
                        rowActions(entry)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.currentShelf?.label ?? "")
                .font(.system(size: 13, weight: .semibold))

            if !model.shelfEntries.isEmpty {
                Text("\(model.visibleEntries.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let note = model.loadProgress ?? model.cacheNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $model.filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 130)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))

            Button { model.exportCurrentShelf() } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            .help("Export this shelf as CSV")

            if model.isLoadingShelf {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await model.loadShelf(force: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Reload this shelf")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyText: String {
        if model.isLoadingShelf { return model.loadProgress ?? "Loading your shelf…" }
        if !model.filter.isEmpty { return "Nothing matches “\(model.filter)”." }
        return "Nothing here yet."
    }

    private func detailLine(_ entry: ShelfEntry) -> String? {
        var bits: [String] = []
        if let progress = entry.progress { bits.append("\(progress)%") }
        if let date = entry.dateRead, !date.isEmpty { bits.append("read \(date)") }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    @ViewBuilder
    private func rowActions(_ entry: ShelfEntry) -> some View {
        if model.currentShelf?.name == "currently-reading" {
            Button {
                model.progressTarget = entry
            } label: {
                Label("Update Progress…", systemImage: "chart.bar")
            }
        }

        Button {
            model.finishTarget = entry
        } label: {
            Label("Mark Read & Rate…", systemImage: "star")
        }

        Menu("Rate") {
            ForEach((1...5).reversed(), id: \.self) { stars in
                Button("\(stars) ★ — \(StarPicker.phrase(stars))") {
                    Task { await model.rate(entry, stars: stars) }
                }
            }
        }

        Divider()

        Menu("Move to") {
            ForEach(model.shelves.filter { $0.name != model.currentShelf?.name }) { shelf in
                Button {
                    Task { await model.move(entry, to: shelf) }
                } label: {
                    Label(shelf.label, systemImage: shelf.symbol)
                }
            }
        }

        Divider()

        Button("View Details…") { model.showBookDetail(entry.asBook) }
        Button("Open on Goodreads") { model.openOnGoodreads(bookID: entry.bookID) }
        Button("Remove from Shelf", role: .destructive) {
            Task { await model.remove(entry) }
        }
    }
}

/// Combines an existing detail string (a rating, a suggestion's reason) with
/// the publisher, when there is one, into one line for `BookRow`.
private func detailLine(_ existing: String?, publisher: String?) -> String? {
    let parts = [existing, publisher.map { "· \($0)" }].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}

// MARK: - Currently Reading carousel

private struct CurrentlyReadingCarousel: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Currently Reading")
                    .font(.system(size: 13, weight: .semibold))
                if model.isLoadingCurrentlyReading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.currentlyReading) { entry in
                        CurrentlyReadingCard(entry: entry, isBusy: model.busyBookID == entry.bookID) {
                            model.progressTarget = entry
                        } onOpenDetail: {
                            model.showBookDetail(entry.asBook)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 10)
    }
}

private struct CurrentlyReadingCard: View {
    let entry: ShelfEntry
    let isBusy: Bool
    let onUpdateProgress: () -> Void
    let onOpenDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onOpenDetail) {
                Group {
                    if let cover = entry.coverURL {
                        AsyncImage(url: cover) { phase in
                            if case .success(let image) = phase {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                coverPlaceholder
                            }
                        }
                    } else {
                        coverPlaceholder
                    }
                }
                .frame(width: 96, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)

            Text(entry.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .frame(width: 96, alignment: .leading)

            if let progress = entry.progress {
                ProgressView(value: Double(progress), total: 100)
                    .frame(width: 96)
                Text("\(progress)%")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("No progress yet")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button("Update Progress…", action: onUpdateProgress)
                    .font(.system(size: 10))
                    .buttonStyle(.link)
            }
        }
        .frame(width: 96)
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.secondary.opacity(0.15))
            .overlay(Image(systemName: "book.closed").foregroundStyle(.tertiary))
    }
}

// MARK: - Shared pieces

private struct EmptyPane: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BookRow<Actions: View>: View {
    let title: String
    let author: String
    let cover: URL?
    let detail: String?
    let stars: Int?
    let isBusy: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            coverImage

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                Text(author)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let stars, stars > 0 {
                        Text(String(repeating: "★", count: stars))
                            .font(.system(size: 11))
                            .foregroundStyle(.yellow)
                    }
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Menu { actions() } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
        }
        .padding(.vertical, 4)
        .contextMenu { actions() }
    }

    @ViewBuilder
    private var coverImage: some View {
        if let cover {
            AsyncImage(url: cover) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    placeholder
                }
            }
            .frame(width: 34, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            placeholder.frame(width: 34, height: 50)
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.secondary.opacity(0.15))
            .overlay(
                Image(systemName: "book.closed")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            )
    }
}

private struct StatusBar: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var session: WebSession

    var body: some View {
        HStack(spacing: 8) {
            if let status = model.status {
                Image(systemName: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(status.isError ? .orange : .green)
                Text(status.text)
                    .lineLimit(2)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
            } else {
                Circle()
                    .fill(model.loggedIn ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(model.loggedIn ? "Signed in" : "Not signed in")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if session.isBusy { ProgressView().controlSize(.small) }

            Button("Log") { model.showDiagnostics = true }
                .controlSize(.small)
                .help("Every request this app has made — copyable when something breaks.")

            Button("Browser") { model.startBrowser() }
                .controlSize(.small)
                .help("Watch what the app is doing in the page — for troubleshooting.")

            Button(model.loggedIn ? "Sign Out" : "Log In") {
                if model.loggedIn {
                    Task { await model.signOut() }
                } else {
                    model.startSignIn()
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
