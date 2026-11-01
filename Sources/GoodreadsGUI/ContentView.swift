import SwiftUI

struct ContentView: View {
    @ObservedObject private var model = LibraryModel.shared
    @ObservedObject private var session = WebSession.shared
    #if os(iOS)
    /// On iPhone the sidebar is the first screen; this is the pane pushed
    /// over it, nil while the sidebar itself shows.
    @State private var pushedPane: LibraryModel.Pane?
    #endif

    private var sidebarSelection: Binding<LibraryModel.Pane?> {
        #if os(macOS)
        Binding(get: { model.selection }, set: { if let pane = $0 { model.selection = pane } })
        #else
        Binding(get: { pushedPane }, set: { pane in
            pushedPane = pane
            if let pane { model.selection = pane }
        })
        #endif
    }

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
                case .stats:       StatsPane(model: model)
                case .shelf:       ShelfPane(model: model)
                }
                Divider()
                StatusBar(model: model, session: session)
            }
            .macMinFrame(width: 480, height: 420)
        }
        .task {
            model.refreshUpNext()
            await model.checkSession()
            if model.isHome {
                await model.buildSuggestions()
                await model.loadCurrentlyReading()
            }
            await model.warmUp()
        }
        .task { await model.checkForUpdate() }
        .task { FriendNotifier.startPolling(model) }
        .task {
            Connectivity.shared.onReconnect = { [model] in
                Task { await model.refreshAfterReconnect() }
            }
        }
        .onChange(of: model.selection) { _ in Task { await model.paneChanged() } }
        // One item drives every sheet in the app — a book's detail sheet
        // opening an author page, or an author page opening another book's
        // detail, just replaces `activeSheet`'s value, and SwiftUI dismisses
        // the old presentation and brings up the new one on its own. The
        // previous design used eight sibling `.sheet` modifiers (SwiftUI
        // won't stack a second sheet on a view already presenting one from
        // the same modifier chain) and papered over that with a "dismiss,
        // sleep 350ms, then present" hand-off; a single `.sheet(item:)`
        // doesn't need it.
        .sheet(item: $model.activeSheet) { sheet in
            switch sheet {
            case .signIn:
                SignInSheet()
                    .onDisappear { Task { await model.signInSheetClosed() } }
            case .browser:
                BrowserSheet(isPresented: Binding(
                    get: { model.activeSheet == .browser },
                    set: { if !$0 { model.activeSheet = nil } }
                ))
            case .diagnostics:
                DiagnosticsSheet(isPresented: Binding(
                    get: { model.activeSheet == .diagnostics },
                    set: { if !$0 { model.activeSheet = nil } }
                ))
            case .progress(let entry):
                ProgressSheet(entry: entry) { percent, page, note in
                    Task { await model.updateProgress(entry, percent: percent, page: page, note: note) }
                }
            case .finish(let entry):
                FinishSheet(title: entry.title, author: entry.author) { rating, date, note in
                    Task {
                        await model.finish(bookID: entry.bookID, title: entry.title,
                                           rating: rating, dateRead: date, note: note)
                    }
                }
            case .finishBook(let book):
                FinishSheet(title: book.title, author: book.author) { rating, date, note in
                    Task {
                        await model.finishBook(book, rating: rating, dateRead: date, note: note)
                    }
                }
            case .detail(let book):
                BookDetailView(book: book)
            case .friendProfile:
                FriendProfileSheet(model: model)
            case .authorPage:
                AuthorPageSheet(model: model)
            case .settings:
                NavigationStack {
                    PreferencesView()
                        .navigationTitle("Settings")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { model.activeSheet = nil }
                            }
                        }
                }
            }
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Label("Home", systemImage: "house")
                .tag(LibraryModel.Pane.home)

            Label("Search", systemImage: "magnifyingglass")
                .tag(LibraryModel.Pane.search)

            Label("Suggestions", systemImage: "sparkles")
                .tag(LibraryModel.Pane.suggestions)

            Label("Friends", systemImage: "person.2")
                .tag(LibraryModel.Pane.friends)

            Label("Stats", systemImage: "chart.bar")
                .tag(LibraryModel.Pane.stats)

            Section("Shelves") {
                ForEach(model.shelves) { shelf in
                    ShelfSidebarRow(model: model, shelf: shelf)
                        .tag(LibraryModel.Pane.shelf(shelf.name))
                }
            }
        }
        .frame(minWidth: 190)
        #if os(iOS)
        .navigationTitle("Goodreads")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(model.loggedIn ? String(localized: "Sign Out") : String(localized: "Log In")) {
                        if model.loggedIn {
                            Task { await model.signOut() }
                        } else {
                            model.startSignIn()
                        }
                    }
                    Button { model.activeSheet = .settings } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    Divider()
                    Button { model.activeSheet = .diagnostics } label: {
                        Label("Log", systemImage: "list.bullet.rectangle")
                    }
                    Button { model.startBrowser() } label: {
                        Label("Browser", systemImage: "safari")
                    }
                } label: {
                    Label("Account", systemImage: model.loggedIn ? "person.crop.circle.fill" : "person.crop.circle")
                }
            }
        }
        #endif
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
                .glassButton()
                .disabled(model.isExporting)
                .help("Fetch every shelf and save one CSV")
            }
            .padding(.bottom, 8)
        }
    }
}

/// A shelf in the sidebar — also a drop target for books dragged out of
/// the shelf on screen.
private struct ShelfSidebarRow: View {
    @ObservedObject var model: LibraryModel
    let shelf: Shelf
    @State private var isTargeted = false

    var body: some View {
        HStack {
            Label(shelf.title, systemImage: shelf.symbol)
            Spacer()
            if let count = shelf.count {
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(isTargeted ? 0.25 : 0))
        )
        .dropDestination(for: String.self) { payloads, _ in
            model.drop(payloads, on: shelf)
        } isTargeted: { targeted in
            isTargeted = targeted && model.currentShelf?.name != shelf.name
        }
        .accessibilityHint(Text("Drop books here to move them to this shelf"))
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

            TypewriterText(text: String(localized: "Welcome to Goodreads"), font: .system(size: 22, weight: .semibold))

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

            if let next = model.upNext {
                Button {
                    model.showBookDetail(next.asBook)
                } label: {
                    Label {
                        Text("Up next: \(next.title)")
                    } icon: {
                        Image(systemName: "arrow.right.circle")
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassCapsule(interactive: true)
                }
                .buttonStyle(.plain)
                .help("The first book in your Want to Read order")
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
    private static var icon: PlatformImage? {
        #if os(macOS)
        Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
        #else
        UIImage(named: "AppIcon")
        #endif
    }

    var body: some View {
        if let image = Self.icon {
            Image(platformImage: image)
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
                    .glassProminentButton()
                }
            }
            .padding(14)
            .frame(width: 230)
            .glassCard(cornerRadius: 18)
            .padding(16)
        }
    }

    @ViewBuilder
    private func coverImage(_ url: URL?) -> some View {
        Group {
            if let url {
                CachedAsyncImage(url: url) { phase in
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

    private var subtitle: String {
        var bits: [String] = []
        if !model.suggestionBasis.isEmpty {
            bits.append(String(localized: "from \(model.suggestionBasis.count) finished in \(prefs.suggestionWindowDays) days"))
        }
        if prefs.bookLanguage != .any { bits.append(prefs.bookLanguage.label) }
        return bits.joined(separator: " · ")
    }

    private func suggestionRow(_ suggestion: Suggestion, detail: String?) -> some View {
        BookRow(
            title: suggestion.book.title,
            author: suggestion.book.author,
            cover: suggestion.book.coverURL,
            detail: detail,
            stars: nil,
            isBusy: model.busyBookID == suggestion.book.id
        ) {
            ForEach(model.shelves) { shelf in
                Button {
                    Task { await model.shelve(suggestion.book, to: shelf) }
                } label: {
                    Label(shelf.title, systemImage: shelf.symbol)
                }
            }
            Divider()
            Button("View Details…") { model.showBookDetail(suggestion.book) }
            Button("Open on Goodreads") { Task { await model.openOnGoodreads(suggestion.book) } }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.suggestions.isEmpty && model.newReleases.isEmpty {
                EmptyPane(symbol: model.isBuildingSuggestions ? "hourglass" : "sparkles",
                          text: model.suggestionNote ?? String(localized: "Nothing to suggest yet."))
            } else {
                List {
                    if !model.newReleases.isEmpty {
                        Section("New from Your Authors") {
                            ForEach(model.newReleases) { suggestion in
                                suggestionRow(suggestion, detail: [suggestion.reason, suggestion.book.publishedDate]
                                    .compactMap { $0 }.joined(separator: " · "))
                            }
                        }
                    }
                    if !model.suggestions.isEmpty {
                        Section("More by Authors You’ve Read") {
                            ForEach(model.suggestions) { suggestion in
                                suggestionRow(suggestion,
                                              detail: detailLine(suggestion.reason, publisher: suggestion.book.publisher))
                            }
                        }
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
        .navigationTitle("Suggestions")
        .navSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isBuildingSuggestions {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task {
                            await model.buildSuggestions(force: true)
                            await model.loadNewReleases(force: true)
                        }
                    } label: {
                        Label("Rebuild suggestions", systemImage: "arrow.clockwise")
                    }
                    .help("Rebuild suggestions")
                }
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
                          text: model.friendsNote ?? String(localized: "No friends found yet."))
            }
        }
        .navigationTitle("Friends")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isLoadingFriends {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await model.loadFriends(force: true) } } label: {
                        Label("Refresh friends", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh")
                }
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
                CachedAsyncImage(url: friend.avatarURL) { phase in
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
                    CachedAsyncImage(url: cover) { phase in
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
        .help(friend.profileURL == nil ? "" : String(localized: "See \(friend.name)’s profile"))
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
                    CachedAsyncImage(url: group.avatarURL) { phase in
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
                    CachedAsyncImage(url: cover) { phase in
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
                            .accessibilityLabel(Text("\(rating) stars"))
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
            GlassHeader {
                Text("Profile")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .glassButton()
            }

            if model.isLoadingFriendProfile {
                EmptyPane(symbol: "hourglass", text: String(localized: "Loading…"))
            } else if let error = model.friendProfileError {
                EmptyPane(symbol: "exclamationmark.triangle", text: error)
            } else if let profile = model.friendProfile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            CachedAsyncImage(url: profile.avatarURL) { phase in
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
                                    Button("Open on Goodreads") { Platform.open(url) }
                                        .font(.system(size: 11))
                                        .linkButtonStyle()
                                }
                            }
                        }

                        FriendCollectionsPicker(model: model)

                        HStack(spacing: 8) {
                            Button {
                                Task { await model.compareTastes() }
                            } label: {
                                Label("Compare Tastes", systemImage: "person.2.wave.2")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .tint(model.tasteComparison != nil && model.friendShelf == nil ? .accentColor : .secondary)
                            .disabled(model.isComparingTastes)
                            if model.isComparingTastes { ProgressView().controlSize(.small) }
                            if let error = model.tasteError {
                                Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                            }
                        }

                        if model.friendShelf != nil {
                            FriendShelfContent(model: model)
                        } else if let comparison = model.tasteComparison {
                            TasteComparisonView(comparison: comparison,
                                                friendName: profile.name.split(separator: " ").first.map(String.init) ?? profile.name) { entry in
                                model.showBookDetail(entry.asBook)
                            }
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
        .sheetFrame(width: 480, height: 620)
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
                        Label(shelf.title, systemImage: shelf.symbol)
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
                Text(model.friendShelf?.title ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                if model.isLoadingFriendShelf {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Close") { model.closeFriendShelf() }
                    .font(.system(size: 11))
                    .linkButtonStyle()
            }

            if let error = model.friendShelfError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if model.friendShelfEntries.isEmpty {
                Text(model.isLoadingFriendShelf ? String(localized: "Loading…") : String(localized: "Nothing on this shelf."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.friendShelfEntries) { entry in
                        BookRow(
                            title: entry.title,
                            author: entry.author,
                            cover: entry.coverURL,
                            detail: entry.dateRead.map { String(localized: "read \($0)") },
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
            GlassHeader {
                Text("Author")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .glassButton()
            }

            if model.isLoadingAuthorPage {
                EmptyPane(symbol: "hourglass", text: String(localized: "Loading…"))
            } else if let error = model.authorPageError {
                EmptyPane(symbol: "exclamationmark.triangle", text: error)
            } else if let author = model.authorPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 14) {
                            CachedAsyncImage(url: author.photoURL) { phase in
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
                                    Button("Website") { Platform.open(website) }
                                        .font(.system(size: 11))
                                        .linkButtonStyle()
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
                                                CachedAsyncImage(url: cover) { phase in
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
        .sheetFrame(width: 480, height: 560)
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
            .macWidth(130)
            .onChange(of: model.searchLanguage) { _ in model.filtersChanged() }

            Picker("", selection: $model.searchSortNewest) {
                Text("Relevance").tag(false)
                Text("Newest").tag(true)
            }
            .labelsHidden()
            .macWidth(110)
            .onChange(of: model.searchSortNewest) { _ in model.filtersChanged() }

            HStack(spacing: 5) {
                Image(systemName: "bookmark").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("Subject", text: $model.searchSubject)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onChange(of: model.searchSubject) { _ in model.filtersChanged() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .macWidth(140)
            .glassCapsule(interactive: true)

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
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCapsule(interactive: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            SearchFilterRow(model: model)
                .glassGroup()

            if model.results.isEmpty && model.libraryMatches.isEmpty {
                EmptyPane(symbol: "books.vertical",
                          text: String(localized: "Search for a book, then add it to a shelf."))
            } else {
                List {
                    if !model.libraryMatches.isEmpty {
                        Section("On Your Shelves") {
                            ForEach(model.libraryMatches) { match in
                                BookRow(
                                    title: match.entry.title,
                                    author: match.entry.author,
                                    cover: match.entry.coverURL,
                                    detail: match.shelves.joined(separator: " · "),
                                    stars: match.entry.rating,
                                    isBusy: model.busyBookID == match.entry.bookID
                                ) {
                                    Button("View Details…") { model.showBookDetail(match.entry.asBook) }
                                    Button("Open on Goodreads") { model.openOnGoodreads(bookID: match.entry.bookID) }
                                }
                            }
                        }
                    }
                    if !model.results.isEmpty {
                        Section("Goodreads") {
                            ForEach(model.results) { book in
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
                                            Label(shelf.title, systemImage: shelf.symbol)
                                        }
                                    }
                                    Divider()
                                    Button {
                                        model.activeSheet = .finishBook(book)
                                    } label: {
                                        Label("Mark Read & Rate…", systemImage: "star")
                                    }
                                    Button("View Details…") { model.showBookDetail(book) }
                                    Button("Open on Goodreads") { Task { await model.openOnGoodreads(book) } }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Search")
        .onAppear { focused = true }
    }
}

// MARK: - Shelf

private struct ShelfPane: View {
    @ObservedObject var model: LibraryModel
    @AppStorage("shelfLayout") private var layout = "list"

    var body: some View {
        VStack(spacing: 0) {
            if model.visibleEntries.isEmpty {
                EmptyPane(
                    symbol: model.isLoadingShelf ? "hourglass" : "tray",
                    text: emptyText
                )
            } else if layout == "grid" {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 16, alignment: .top)],
                              spacing: 18) {
                        ForEach(model.visibleEntries) { entry in
                            CoverTile(entry: entry, isBusy: model.busyBookID == entry.bookID) {
                                model.showBookDetail(entry.asBook)
                            }
                            .contextMenu { rowActions(entry) }
                            .draggable(LibraryModel.dragPrefix + entry.id) {
                                Label(entry.title, systemImage: "book.closed").padding(6)
                            }
                        }
                    }
                    .padding(16)
                }
            } else {
                List {
                    ForEach(model.visibleEntries) { entry in
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
                        .draggable(LibraryModel.dragPrefix + entry.id) {
                            Label(entry.title, systemImage: "book.closed")
                                .padding(6)
                        }
                    }
                    .onMove(perform: model.canReorder ? { model.moveInQueue(from: $0, to: $1) } : nil)
                }
                .listStyle(.inset)
            }
            if model.sortOrder == .myOrder && !model.canReorder && !model.visibleEntries.isEmpty {
                Divider()
                Text("Clear the filters to drag books into your order.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
        .navigationTitle(model.currentShelf?.title ?? "")
        .navSubtitle(subtitle)
        .searchable(text: $model.filter, placement: .toolbar, prompt: "Filter")
        .task(id: model.shelfEntries.count) {
            ImageMemoryCache.shared.prefetch(model.visibleEntries.prefix(40).compactMap(\.coverURL))
        }
        .toolbar { toolbarContent }
    }

    private var subtitle: String {
        var bits: [String] = []
        if !model.shelfEntries.isEmpty { bits.append(String(localized: "\(model.visibleEntries.count) books")) }
        if let note = model.loadProgress ?? model.cacheNote { bits.append(note) }
        return bits.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            #if os(macOS)
            Picker("Layout", selection: $layout) {
                Label("List", systemImage: "list.bullet").tag("list")
                Label("Covers", systemImage: "square.grid.2x2").tag("grid")
            }
            .pickerStyle(.segmented)
            .help("Show as a list or as covers")
            #else
            // A segmented picker doesn't fit in the iOS toolbar: one button
            // that shows the other layout instead.
            Button { layout = layout == "grid" ? "list" : "grid" } label: {
                if layout == "grid" {
                    Label("List", systemImage: "list.bullet")
                } else {
                    Label("Covers", systemImage: "square.grid.2x2")
                }
            }
            #endif

            filterMenu

            Menu {
                Picker("Sort", selection: $model.sortOrder) {
                    ForEach(ShelfSortOrder.allCases.filter {
                        $0 != .myOrder || model.currentShelf?.name == Shelf.wantToRead.name
                    }) { order in
                        Text(order.title).tag(order)
                    }
                }
            } label: {
                Label("Sort shelf", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort: \(model.sortOrder.title)")

            Button { model.exportCurrentShelf() } label: {
                Label("Export shelf as CSV", systemImage: "square.and.arrow.down")
            }
            .help("Export this shelf as CSV")

            if model.isLoadingShelf {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await model.loadShelf(force: true) } } label: {
                    Label("Reload shelf", systemImage: "arrow.clockwise")
                }
                .help("Reload this shelf")
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Rating", selection: $model.filters.rating) {
                ForEach(ShelfFilters.Rating.allCases) { Text($0.title).tag($0) }
            }
            let years = ShelfFilters.years(in: model.shelfEntries)
            if !years.isEmpty {
                Picker("Year Read", selection: $model.filters.year) {
                    Text("Any year").tag(Int?.none)
                    ForEach(years, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
                }
            }
            let genres = ShelfFilters.genres(in: model.shelfEntries, extras: model.bookExtras)
            if !genres.isEmpty {
                Picker("Genre", selection: $model.filters.genre) {
                    Text("Any genre").tag(String?.none)
                    ForEach(genres, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            } else {
                Text("Genres appear once books have been opened, or after Stats → Fill In.")
            }
            if model.filters.isActive {
                Divider()
                Button("Clear Filters") { model.filters = ShelfFilters() }
            }
        } label: {
            Label("Filter shelf",
                  systemImage: model.filters.isActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
        }
        .help("Filter by rating, year read or genre")
    }

    private var emptyText: String {
        if model.isLoadingShelf { return model.loadProgress ?? String(localized: "Loading your shelf…") }
        if model.filters.isActive { return String(localized: "No books match these filters.") }
        if !model.filter.isEmpty { return String(localized: "Nothing matches “\(model.filter)”.") }
        return String(localized: "Nothing here yet.")
    }

    private func detailLine(_ entry: ShelfEntry) -> String? {
        var bits: [String] = []
        if let progress = entry.progress { bits.append("\(progress)%") }
        if let date = entry.dateRead, !date.isEmpty { bits.append(String(localized: "read \(date)")) }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    @ViewBuilder
    private func rowActions(_ entry: ShelfEntry) -> some View {
        if model.currentShelf?.name == "currently-reading" {
            Button {
                model.activeSheet = .progress(entry)
            } label: {
                Label("Update Progress…", systemImage: "chart.bar")
            }
        }

        Button {
            model.activeSheet = .finish(entry)
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
                    Label(shelf.title, systemImage: shelf.symbol)
                }
            }
        }

        Divider()

        Button("View Details…") { model.showBookDetail(entry.asBook) }
        Button("Open on Goodreads") { model.openOnGoodreads(bookID: entry.bookID) }
        if let url = LibraryModel.goodreadsURL(bookID: entry.bookID) {
            ShareLink(item: url, subject: Text(entry.title),
                      message: Text("\(entry.title) — \(entry.author)")) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
        }
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

/// A shelf book in the Covers layout.
private struct CoverTile: View {
    let entry: ShelfEntry
    let isBusy: Bool
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: open) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.15))
                        .overlay(Image(systemName: "book.closed").foregroundStyle(.tertiary))
                    if let cover = entry.coverURL {
                        CachedAsyncImage(url: cover) { phase in
                            if case .success(let image) = phase {
                                image.resizable().aspectRatio(contentMode: .fill)
                            }
                        }
                    }
                    if isBusy {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 112, height: 166)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
            }
            .buttonStyle(.plain)

            Text(entry.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
            Text(entry.author)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let stars = entry.rating, stars > 0 {
                Text(String(repeating: "★", count: stars))
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
                    .accessibilityLabel(Text("\(stars) stars"))
            } else if let progress = entry.progress {
                ProgressView(value: Double(progress), total: 100)
                    .accessibilityLabel(Text("Progress"))
            }
        }
        .frame(width: 112, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
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
                        CurrentlyReadingCard(entry: entry, isBusy: model.busyBookID == entry.bookID,
                                             finishEstimate: model.finishEstimate(for: entry)) {
                            model.activeSheet = .progress(entry)
                        } onOpenDetail: {
                            model.showBookDetail(entry.asBook)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .glassGroup(spacing: 12)
            }
        }
        .padding(.vertical, 10)
    }
}

private struct CurrentlyReadingCard: View {
    let entry: ShelfEntry
    let isBusy: Bool
    let finishEstimate: Date?
    let onUpdateProgress: () -> Void
    let onOpenDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onOpenDetail) {
                Group {
                    if let cover = entry.coverURL {
                        CachedAsyncImage(url: cover) { phase in
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
            .accessibilityLabel(Text("Details for \(entry.title)"))

            Text(entry.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .frame(width: 96, alignment: .leading)

            if let progress = entry.progress {
                ProgressView(value: Double(progress), total: 100)
                    .frame(width: 96)
                    .accessibilityLabel(Text("Progress"))
                Text("\(progress)%")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                if let finishEstimate {
                    Text("Done around \(LibraryModel.shortDate(finishEstimate))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("At your pace so far")
                }
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
                    .linkButtonStyle()
            }
        }
        .frame(width: 96)
        .padding(10)
        .glassCard(cornerRadius: 14)
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
                            .accessibilityLabel(Text("\(stars) stars"))
                    }
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Menu { actions() } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More actions for \(title)")
            }
        }
        .padding(.vertical, 4)
        .contextMenu { actions() }
    }

    @ViewBuilder
    private var coverImage: some View {
        if let cover {
            CachedAsyncImage(url: cover) { phase in
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
            .accessibilityHidden(true)
    }
}

private struct StatusBar: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var session: WebSession
    @ObservedObject private var connectivity = Connectivity.shared

    var body: some View {
        HStack(spacing: 8) {
            if !connectivity.isOnline {
                Label("Offline — showing saved data", systemImage: "wifi.slash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .glassCapsule()
                    .help("No internet connection. What you see is from the cache, and refreshes once you're back online.")
            }
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
                Text(model.loggedIn ? String(localized: "Signed in") : String(localized: "Not signed in"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let pending = model.pendingUndo {
                Button("Undo") { Task { await model.performPendingUndo() } }
                    .controlSize(.small)
                    .glassButton()
                    .help(pending.label)
            }

            #if os(macOS)
            if let update = model.updateAvailable {
                UpdateButton(update: update)
            }
            #endif

            if session.isBusy { ProgressView().controlSize(.small) }

            #if os(macOS)
            Button("Log") { model.activeSheet = .diagnostics }
                .controlSize(.small)
                .glassButton()
                .help("Every request this app has made — copyable when something breaks.")

            Button("Browser") { model.startBrowser() }
                .controlSize(.small)
                .glassButton()
                .help("Watch what the app is doing in the page — for troubleshooting.")

            Button(model.loggedIn ? String(localized: "Sign Out") : String(localized: "Log In")) {
                if model.loggedIn {
                    Task { await model.signOut() }
                } else {
                    model.startSignIn()
                }
            }
            .controlSize(.small)
            .glassProminentButton()
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

#if os(macOS)
/// "Update to x.y.z…" in the status bar — shows what's new first, then
/// installs and relaunches when it can, otherwise opens the release page.
private struct UpdateButton: View {
    let update: UpdateChecker.Available
    @ObservedObject private var updater = SelfUpdater.shared
    @State private var showingNotes = false

    var body: some View {
        switch updater.state {
        case .downloading(let fraction):
            HStack(spacing: 6) {
                Text("Downloading \(update.version)…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(width: 80)
                        .accessibilityLabel(Text("Download progress"))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        case .installing:
            Label("Installing…", systemImage: "gearshape")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .idle, .failed:
            Button(String(localized: "Update to \(update.version)…")) { showingNotes = true }
                .controlSize(.small)
                .glassProminentButton()
                .help(helpText)
                .popover(isPresented: $showingNotes, arrowEdge: .top) {
                    UpdateNotesView(update: update,
                                    canInstallInPlace: updater.canInstallInPlace && update.dmgURL != nil) {
                        showingNotes = false
                        updater.install(update)
                    }
                }
        }
    }

    private var helpText: String {
        if case .failed(let message) = updater.state {
            return String(localized: "The last attempt failed: \(message). Click to try again.")
        }
        return String(localized: "See what's new in \(update.version)")
    }
}
#endif
