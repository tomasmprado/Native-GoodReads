import Foundation
import SwiftUI

@MainActor
final class LibraryModel: ObservableObject {

    /// Shared so the main window and the ⌥Space panel see the same state.
    static let shared = LibraryModel()

    // Search
    @Published var query = ""
    @Published var results: [Book] = []
    @Published var isSearching = false

    // Shelves
    @Published var shelves: [Shelf] = Shelf.builtIn
    @Published var selection: Pane = .home
    @Published var shelfEntries: [ShelfEntry] = []
    @Published var filter = ""
    @Published var sortOrder: ShelfSortOrder = .asShelved
    @Published var filters = ShelfFilters()
    /// Page counts and genres, for the genre filter.
    @Published var bookExtras: [String: BookExtras] = [:] {
        didSet { WidgetBridge.scheduleUpdate() }
    }
    /// Search: books already on your shelves that match the query.
    @Published var libraryMatches: [LibraryMatch] = []
    /// The top of your own Want to Read order, for Home.
    @Published var upNext: ShelfEntry?
    private var libraryCache: (loaded: Date, shelves: [(shelf: Shelf, entries: [ShelfEntry])])?
    @Published var isLoadingShelf = false
    @Published var loadProgress: String?
    @Published var cacheNote: String?

    // Export — kept separate from `isLoadingShelf`/`loadProgress` above.
    // `exportEverything` used to reuse those, so exporting while a shelf pane
    // was on screen made it look like that shelf was reloading.
    @Published var isExporting = false
    @Published var exportProgress: String?

    // Chrome
    @Published var busyBookID: String?
    @Published var status: Status?
    @Published var loggedIn = false

    /// A just-completed remove or move, offered back for ~8 seconds — see
    /// `offerUndo`.
    struct PendingUndo: Identifiable {
        let id = UUID()
        let label: String
        let action: () async -> Void
    }
    @Published var pendingUndo: PendingUndo?
    private var undoResetTask: Task<Void, Never>?

    @Published var updateAvailable: UpdateChecker.Available?

    /// Every sheet in the app, as one item — a book's detail sheet opening an
    /// author page (or vice versa) just replaces this value, and SwiftUI
    /// dismisses whatever's showing and presents the new one on its own;
    /// nothing here needs to know or care whether something else was already
    /// up. `.friendProfile` and `.authorPage` carry no payload of their own
    /// since the sheets they present already read `friendProfile`/
    /// `authorPage` below — they exist in this enum purely to gate
    /// presentation the same way every other case does.
    enum PresentedSheet: Identifiable, Equatable {
        case signIn
        case browser
        case diagnostics
        case progress(ShelfEntry)
        case finish(ShelfEntry)
        case finishBook(Book)
        case abandon(ShelfEntry)
        case importHighlights
        case detail(Book)
        case friendProfile
        case authorPage

        var id: String {
            switch self {
            case .signIn:               return "signIn"
            case .browser:              return "browser"
            case .diagnostics:          return "diagnostics"
            case .progress(let entry):  return "progress-\(entry.id)"
            case .finish(let entry):    return "finish-\(entry.id)"
            case .finishBook(let book): return "finishBook-\(book.id)"
            case .abandon(let entry):   return "abandon-\(entry.id)"
            case .importHighlights:     return "importHighlights"
            case .detail(let book):     return "detail-\(book.id)"
            case .friendProfile:        return "friendProfile"
            case .authorPage:           return "authorPage"
            }
        }
    }
    @Published var activeSheet: PresentedSheet?

    // Home
    @Published var suggestions: [Suggestion] = []
    @Published var suggestionBasis: [ShelfEntry] = []
    @Published var isBuildingSuggestions = false
    @Published var suggestionNote: String?
    /// Recent books by authors you've read more than once.
    @Published var newReleases: [Suggestion] = []

    @Published var currentlyReading: [ShelfEntry] = [] {
        didSet { WidgetBridge.scheduleUpdate() }
    }
    /// Progress over time per book id, for finish-date estimates.
    @Published var progressHistory: [String: [ProgressPoint]] = [:] {
        didSet { WidgetBridge.scheduleUpdate() }
    }
    @Published var isLoadingCurrentlyReading = false
    /// Books you stopped reading, by book id — kept on this Mac.
    @Published var abandoned: [String: AbandonedBook] = [:]

    // Search filters
    @Published var searchLanguage: BookLanguage = .any
    @Published var searchSortNewest = false
    @Published var searchSubject = ""

    // Stats
    @Published var readingStats: ReadingStats? {
        didSet { WidgetBridge.scheduleUpdate() }
    }
    @Published var isLoadingStats = false
    /// This year's Goodreads Reading Challenge, once read.
    @Published var challenge: ReadingChallenge?
    /// "Fill In" on the Stats pane: book pages fetched so far, of how many.
    @Published var extrasDone = 0
    @Published var extrasTotal = 0
    @Published var isFillingExtras = false

    // Friends
    @Published var friends: [GoodreadsFriends.Friend] = []
    @Published var friendActivity: [GoodreadsFriends.Activity] = []
    /// When the friend list was last refreshed this session.
    private var friendsFetched: Date?
    @Published var isLoadingFriends = false
    @Published var friendsNote: String?
    /// Friends' Read and Currently Reading shelves, for "Friends who read this".
    @Published var friendsBooks: [String: FriendLibrary] = [:]
    @Published var friendsBooksProgress: String?

    // Friend profile — the "dive deeper" sheet
    @Published var friendProfileURL: URL?
    @Published var friendProfile: GoodreadsFriends.Profile?
    @Published var isLoadingFriendProfile = false
    @Published var friendProfileError: String?

    // A friend's own shelves ("collections"), browsed from their profile —
    // nil `friendShelf` means the shelf picker is showing, not a shelf itself.
    @Published var friendShelf: Shelf?
    @Published var friendShelfEntries: [ShelfEntry] = []
    @Published var isLoadingFriendShelf = false
    @Published var friendShelfError: String?

    // Comparing your Read shelf with the open friend's
    @Published var tasteComparison: TasteComparison?
    @Published var isComparingTastes = false
    @Published var tasteError: String?

    // Author page
    @Published var authorPageURL: URL?
    @Published var authorPage: GoodreadsAuthorPage.Detail?
    @Published var isLoadingAuthorPage = false
    @Published var authorPageError: String?

    enum Pane: Hashable {
        case home
        case search
        case suggestions
        case friends
        case stats
        case quotes
        case shelf(String)      // shelf slug
    }

    struct Status: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    private var searchTask: Task<Void, Never>?
    private var shelfTask: Task<Void, Never>?
    private var searchCache: [String: (date: Date, books: [Book])] = [:]
    private var didWarmUp = false
    private let debounce = Duration.milliseconds(250)

    var isHome: Bool { selection == .home }

    var currentShelf: Shelf? {
        guard case .shelf(let slug) = selection else { return nil }
        return shelves.first { $0.name == slug } ?? Shelf.fromSlug(slug)
    }

    var visibleEntries: [ShelfEntry] {
        let shown = shelfEntries.filter {
            $0.matches(filter) && filters.matches($0, extras: bookExtras, favouriteAuthors: favouriteAuthors)
        }
        return filters.ordered(shown, extras: bookExtras) ?? sortOrder.sorted(shown)
    }

    /// For the "By authors you love" smart list, from the Read shelf.
    @Published var favouriteAuthors: Set<String> = []

    /// Books on the shelf on screen whose page count or rating isn't known,
    /// for the smart lists that need them.
    var shelfEntriesMissingPages: [ShelfEntry] {
        shelfEntries.filter { extras in
            guard let known = bookExtras[extras.bookID] else { return true }
            return known.pages == nil || known.rating == nil
        }
    }

    /// Fetches the book pages the smart lists need, for the shelf on screen.
    func fillShelfExtras() async {
        let missing = shelfEntriesMissingPages
        guard !isFillingExtras, !missing.isEmpty else { return }
        isFillingExtras = true
        extrasDone = 0
        extrasTotal = missing.count
        defer {
            isFillingExtras = false
            extrasTotal = 0
        }
        await withTaskGroup(of: Void.self) { group in
            var queue = missing.makeIterator()
            func addNext() {
                guard let entry = queue.next() else { return }
                group.addTask { await BookExtras.fetch(entry) }
            }
            for _ in 0..<3 { addNext() }
            while await group.next() != nil {
                extrasDone += 1
                if extrasDone % 10 == 0 { bookExtras = await BookExtras.all() }
                addNext()
            }
        }
        bookExtras = await BookExtras.all()
    }

    /// Rows can be dragged into your own order only when all of them show.
    var canReorder: Bool {
        sortOrder == .myOrder && filter.isEmpty && !filters.isActive
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        objectWillChange.send()
        QueueOrder.save(QueueOrder.moved(visibleEntries, from: source, to: destination))
        refreshUpNext()
    }

    func refreshUpNext() {
        upNext = QueueOrder.upNext(in: ShelfCache.read(.wantToRead)?.entries ?? [])
    }

    /// Every cached shelf, re-read from disk at most once a minute.
    private func library() -> [(shelf: Shelf, entries: [ShelfEntry])] {
        if let cache = libraryCache, Date().timeIntervalSince(cache.loaded) < 60 { return cache.shelves }
        let shelves = shelves.compactMap { shelf in ShelfCache.read(shelf).map { (shelf, $0.entries) } }
        libraryCache = (Date(), shelves)
        return shelves
    }

    // MARK: - Search

    /// Called on every keystroke. Waits for a pause before hitting the network,
    /// and cancels any request still in flight from the previous keystroke.
    func queryChanged() {
        searchTask?.cancel()
        status = nil

        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        libraryMatches = LibraryMatch.find(term, in: library())

        // One character matches half of Goodreads — not worth the round trip.
        guard term.count >= 2 else {
            results = []
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounce)
            guard !Task.isCancelled else { return }
            await self.performSearch(term)
        }
    }

    /// Return key — skip the debounce and search immediately.
    func searchNow() {
        searchTask?.cancel()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }

        status = nil
        isSearching = true
        searchTask = Task { [weak self] in
            await self?.performSearch(term)
        }
    }

    /// Re-runs the last search with the current filters — called when a
    /// filter changes rather than the query text itself.
    func filtersChanged() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { return }
        searchNow()
    }

    private func performSearch(_ term: String) async {
        do {
            // Going back to a recent search (or a filter you just undid) is
            // instant — results are kept for the session for a few minutes.
            let key = "\(term.lowercased())|\(searchLanguage.rawValue)|\(searchSortNewest)|\(searchSubject)"
            let found: [Book]
            if let hit = searchCache[key], Date().timeIntervalSince(hit.date) < 600 {
                found = hit.books
            } else {
                found = try await GoogleBooksClient.search(
                    term, language: searchLanguage, sortNewest: searchSortNewest, subject: searchSubject
                )
                searchCache[key] = (Date(), found)
            }
            ImageMemoryCache.shared.prefetch(found.prefix(20).compactMap(\.coverURL))

            // A newer keystroke may have superseded this request while it was
            // in flight — drop the stale response rather than flashing it.
            guard !Task.isCancelled,
                  term == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

            results = found
            isSearching = false
            if found.isEmpty {
                status = Status(text: String(localized: "No books matched “\(term)”."), isError: false)
            }
        } catch {
            guard !Task.isCancelled, !isCancellation(error) else { return }
            results = []
            isSearching = false
            status = Status(text: error.localizedDescription, isError: true)
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    // MARK: - Session

    func startSignIn() { activeSheet = .signIn }
    func startBrowser() { activeSheet = .browser }

    func signInSheetClosed() async {
        loggedIn = await WebSession.shared.refreshSignInState()
        status = Status(text: loggedIn ? String(localized: "Signed in.") : String(localized: "Still signed out."), isError: !loggedIn)
        if loggedIn {
            await refreshShelfList()
            if currentShelf != nil { await loadShelf(force: true) }
        }
    }

    func checkSession() async {
        loggedIn = await WebSession.shared.refreshSignInState()
        if loggedIn { await refreshShelfList() }
    }

    /// Runs once, a few seconds after launch: fills in whatever has never
    /// been cached (built-in shelves, friends) so the first visit to those
    /// panes is instant too, and warms the covers Home is about to show.
    /// Only fills gaps — anything already cached refreshes on its own when
    /// opened — so it costs nothing on later launches.
    func warmUp() async {
        guard loggedIn, !didWarmUp else { return }
        didWarmUp = true

        ImageMemoryCache.shared.prefetch(
            (currentlyReading.map(\.coverURL) + suggestions.prefix(10).map(\.book.coverURL)).compactMap { $0 }
        )

        try? await Task.sleep(for: .seconds(3))
        indexCachedShelves()
        for shelf in Shelf.builtIn where ShelfCache.read(shelf) == nil {
            guard !Task.isCancelled else { return }
            if let entries = try? await ShelfLibrary.load(shelf) {
                ShelfCache.write(entries, for: shelf)
                setCount(entries.count, for: shelf)
            }
        }
        if friends.isEmpty {
            await loadFriends()
        }
        await loadNewReleases()
        Task { await fetchCleanTitles() }
        friendsBooks = await FriendsBooks.index()
        if FriendsBooks.isStale(friendsBooks) { await syncFriendsBooks() }
    }

    /// Reads every friend's Read and Currently Reading shelves.
    func syncFriendsBooks() async {
        guard friendsBooksProgress == nil else { return }
        if friends.isEmpty { await loadFriends() }
        guard !friends.isEmpty else { return }
        friendsBooks = await FriendsBooks.sync(friends) { [weak self] done, total in
            self?.friendsBooksProgress = String(localized: "Reading friends’ shelves… \(done) of \(total)")
        }
        friendsBooksProgress = nil
    }

    /// "New from your authors" — refreshed at most daily, since each author
    /// costs a Google Books query.
    func loadNewReleases(force: Bool = false) async {
        if let hit = await DataCache.shared.read([Suggestion].self, "new-releases", "all",
                                                 ttl: DataCache.TTL.newReleases) {
            newReleases = hit.value
            if !hit.isStale && !force { return }
        }
        guard let read = ShelfCache.read(.read)?.entries, !read.isEmpty else { return }

        var shelved = Set<String>()
        for shelf in shelves {
            for entry in ShelfCache.read(shelf)?.entries ?? [] {
                shelved.insert(Suggestions.normalizedTitle(entry.title))
            }
        }
        let prefs = Preferences.shared
        let found = await NewReleases.find(read: read, shelvedTitles: shelved,
                                           language: prefs.bookLanguage,
                                           includeUnknown: prefs.includeUnknownLanguage)
        newReleases = found
        await DataCache.shared.write(found, "new-releases", "all")
        if prefs.notifyNewReleases { await NewReleases.notify(about: found) }
    }

    /// Puts every shelf already on disk into Spotlight — for books cached
    /// before indexing existed, or after turning it back on.
    func indexCachedShelves() {
        for shelf in shelves {
            if let cached = ShelfCache.read(shelf) {
                SpotlightIndex.update(cached.entries, shelf: shelf)
            }
        }
    }

    /// Once per launch is plenty — this is a nicety, not something worth
    /// polling for.
    func checkForUpdate() async {
        updateAvailable = await UpdateChecker.checkForUpdate()
    }

    func signOut() async {
        await WebSession.shared.signOut()
        loggedIn = WebSession.shared.isSignedIn
        shelfEntries = []
        shelves = Shelf.builtIn
        ShelfCache.clear()
        await DataCache.shared.clear()
        ImageMemoryCache.shared.removeAll()
        suggestions = []
        suggestionBasis = []
        friends = []
        friendActivity = []
        friendsFetched = nil
    }

    // MARK: - Shelves

    /// Sidebar counts come from a scrape done at sign-in, so they drift as soon
    /// as you move anything. Whenever we know the real number, use it.
    private func setCount(_ count: Int, for shelf: Shelf) {
        guard let index = shelves.firstIndex(where: { $0.name == shelf.name }) else { return }
        shelves[index].count = count
    }

    private func bumpCount(_ delta: Int, for shelf: Shelf) {
        guard let index = shelves.firstIndex(where: { $0.name == shelf.name }) else { return }
        shelves[index].count = max(0, (shelves[index].count ?? 0) + delta)
    }

    /// Only bumps when the cached copy of `shelf` doesn't already have this
    /// book — shelving something already on the shelf (the common outcome of
    /// re-rating, or moving a book to a shelf it's already on) shouldn't
    /// inflate the count. Imperfect when the cache is stale, but a real
    /// improvement over bumping unconditionally on every write.
    private func bumpCountIfNew(bookID: String, shelf: Shelf) {
        let alreadyThere = ShelfCache.read(shelf)?.entries.contains { $0.bookID == bookID } ?? false
        if !alreadyThere { bumpCount(1, for: shelf) }
    }

    func refreshShelfList() async {
        do {
            let found = try await ShelfLibrary.discoverShelves()
            if !found.isEmpty { shelves = found }
        } catch {
            // Silently keeping the three built-ins here is what made custom
            // shelves look like they'd vanished.
            status = Status(text: String(localized: "Couldn’t read your shelf list: \(error.localizedDescription)"),
                            isError: true)
        }
    }

    func paneChanged() async {
        // Drop whatever the previous shelf was still doing, and clear the list
        // now — leaving the old books on screen under a new shelf's name is
        // worse than showing nothing.
        shelfTask?.cancel()
        shelfTask = nil

        status = nil
        filter = ""
        filters = ShelfFilters()
        if sortOrder == .myOrder, currentShelf?.name != Shelf.wantToRead.name { sortOrder = .asShelved }
        shelfEntries = []
        cacheNote = nil

        switch selection {
        case .shelf:
            await loadShelf()
        case .home:
            refreshUpNext()
            await buildSuggestions()
            await loadCurrentlyReading()
        case .suggestions:
            await buildSuggestions()
            await loadNewReleases()
        case .friends:
            await loadFriends()
        case .stats:
            await loadStats()
        case .search, .quotes:
            break
        }
    }

    /// Back online: refresh what's on screen, keeping the filter and the
    /// rows already shown (each loader shows its cache first anyway).
    func refreshAfterReconnect() async {
        guard loggedIn else { await checkSession(); return }
        switch selection {
        case .shelf:       await loadShelf(force: true)
        case .home:        await loadCurrentlyReading(force: true)
        case .friends:     await loadFriends(force: true)
        case .stats:       await loadStats(force: true)
        case .suggestions, .search, .quotes: break
        }
    }

    // MARK: - Home

    /// Suggestions come from the Read shelf, so make sure we have it. The cache
    /// covers the common case without a fetch.
    func buildSuggestions(force: Bool = false) async {
        guard !isBuildingSuggestions else { return }
        let cachedRead = ShelfCache.read(.read)

        // Last launch's suggestions show on the first frame; they're only
        // rebuilt when they've aged out, the Read shelf moved, or on request.
        var savedStale = false
        if suggestions.isEmpty,
           let hit = await DataCache.shared.read(SavedSuggestions.self, "suggestions", "home",
                                                 ttl: DataCache.TTL.suggestions) {
            suggestions = hit.value.items
            suggestionBasis = hit.value.basis
            suggestionNote = nil
            savedStale = hit.isStale
            let readStale = cachedRead.map { ShelfCache.isStale($0.fetched) } ?? true
            if !hit.isStale && !force && !readStale { return }
        }
        // The cache used to never expire on its own — Home could sit on a
        // suggestion set built from a Read shelf that's since moved on for
        // as long as the app stayed open, since nothing else forced a
        // rebuild once `suggestions` was non-empty.
        let stale = cachedRead.map { ShelfCache.isStale($0.fetched) } ?? true
        if !suggestions.isEmpty && !force && !stale && !savedStale { return }

        isBuildingSuggestions = true
        suggestionNote = String(localized: "Looking at what you finished recently…")
        defer { isBuildingSuggestions = false }

        var readEntries = cachedRead?.entries ?? []

        if readEntries.isEmpty || force || stale {
            do {
                readEntries = try await ShelfLibrary.load(.read)
                ShelfCache.write(readEntries, for: .read)
                setCount(readEntries.count, for: .read)
            } catch {
                suggestionNote = String(localized: "Couldn’t read your Read shelf: \(error.localizedDescription)")
                return
            }
        }

        // Anything already on any shelf is not a suggestion. Goodreads shelf
        // entries never carry an ISBN, so exclusion matches on title text.
        var shelvedTitles = Set<String>()
        for shelf in shelves {
            for entry in ShelfCache.read(shelf)?.entries ?? [] {
                shelvedTitles.insert(Suggestions.normalizedTitle(entry.title))
            }
        }
        for entry in readEntries { shelvedTitles.insert(Suggestions.normalizedTitle(entry.title)) }
        // In-memory state can be fresher than the cache — a shelf loaded
        // earlier this session but not yet re-cached, or one never opened at
        // all this run. Cheap to fold in on top of the cache reads above.
        for entry in shelfEntries { shelvedTitles.insert(Suggestions.normalizedTitle(entry.title)) }
        for entry in currentlyReading { shelvedTitles.insert(Suggestions.normalizedTitle(entry.title)) }

        let prefs = Preferences.shared

        do {
            suggestionNote = String(localized: "Finding books…")
            let result = try await Suggestions.build(
                from: readEntries,
                excludingTitles: shelvedTitles,
                windowDays: prefs.suggestionWindowDays,
                language: prefs.bookLanguage,
                includeUnknown: prefs.includeUnknownLanguage
            )

            suggestions = result.items
            suggestionBasis = result.basis
            await DataCache.shared.write(SavedSuggestions(items: result.items, basis: result.basis),
                                         "suggestions", "home")

            if result.basis.isEmpty {
                suggestionNote = String(localized: "Nothing finished in the last \(prefs.suggestionWindowDays) days — mark a book read and this fills in.")
            } else if result.items.isEmpty {
                suggestionNote = prefs.bookLanguage == .any
                    ? String(localized: "No new books found from those authors.")
                    : String(localized: "Nothing found in \(prefs.bookLanguage.label.lowercased()). Try widening the language in Settings.")
            } else {
                suggestionNote = nil
            }
        } catch {
            suggestionNote = error.localizedDescription
        }
    }

    /// Same cache-then-refresh shape as `performLoad`, kept separate from
    /// `shelfEntries` so the Home carousel doesn't depend on which shelf pane
    /// (if any) happens to be selected.
    func loadCurrentlyReading(force: Bool = false) async {
        guard !isLoadingCurrentlyReading else { return }
        if progressHistory.isEmpty { progressHistory = await ReadingPace.all() }
        let cached = ShelfCache.read(.currentlyReading)
        if let cached { currentlyReading = cached.entries }
        if bookExtras.isEmpty { bookExtras = await BookExtras.all() }
        if friendsBooks.isEmpty { friendsBooks = await FriendsBooks.index() }
        let stale = cached.map { ShelfCache.isStale($0.fetched) } ?? true
        guard currentlyReading.isEmpty || force || stale else {
            await fillReadingPages()
            return
        }

        isLoadingCurrentlyReading = true
        defer { isLoadingCurrentlyReading = false }

        if var fetched = try? await ShelfLibrary.load(.currentlyReading) {
            await backfillProgress(into: &fetched)
            currentlyReading = fetched
            ShelfCache.write(fetched, for: .currentlyReading)
            setCount(fetched.count, for: .currentlyReading)
            ReadingReminder.reschedule()
        }
        await fillReadingPages()
        Task { await fetchCleanTitles() }
    }

    /// The shelf listing itself carries no progress field — only the home
    /// feed's Currently Reading widget does. Best-effort: a failure here
    /// just leaves entries showing no progress, same as before this existed.
    private func backfillProgress(into entries: inout [ShelfEntry]) async {
        guard let progress = try? await ShelfService.currentProgress(), !progress.isEmpty else { return }
        for i in entries.indices {
            if let percent = progress[entries[i].bookID] {
                entries[i].progress = percent
                await ReadingPace.record(percent, for: entries[i].bookID)
            }
        }
        progressHistory = await ReadingPace.all()
    }

    /// "14 Nov" — for finish estimates.
    nonisolated static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// Page counts known for what's on Currently Reading — fetched once for
    /// books that don't have one yet, so Home can show pages.
    private func fillReadingPages() async {
        var extras = await BookExtras.all()
        let missing = currentlyReading.filter { extras[$0.bookID]?.pages == nil }.prefix(8)
        for entry in missing {
            await BookExtras.fetch(entry)
        }
        if !missing.isEmpty { extras = await BookExtras.all() }
        bookExtras = extras
    }

    private var isFetchingTitles = false

    /// With a Google Books key, looks up clean titles by ISBN for your books —
    /// what's on screen first, then every saved shelf — and shows them as
    /// they arrive.
    func fetchCleanTitles() async {
        guard !isFetchingTitles,
              !Preferences.shared.googleBooksAPIKey.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isFetchingTitles = true
        defer { isFetchingTitles = false }

        var seen = Set<String>()
        let everything = (currentlyReading + shelfEntries + shelves.flatMap { ShelfCache.read($0)?.entries ?? [] })
            .filter { seen.insert($0.bookID).inserted }
        let todo = ShelfTitles.missing(everything)
        var index = 0
        while index < todo.count, !Task.isCancelled {
            let chunk = Array(todo[index..<min(index + 20, todo.count)])
            index += 20
            guard await ShelfTitles.fetch(chunk) else { continue }
            shelfEntries = ShelfTitles.apply(shelfEntries)
            currentlyReading = ShelfTitles.apply(currentlyReading)
            if let shelf = currentShelf { ShelfCache.write(shelfEntries, for: shelf) }
            ShelfCache.write(currentlyReading, for: .currentlyReading)
        }
    }

    /// Friends who have `bookID` on their Currently Reading shelf too.
    func friendsReading(_ bookID: String) -> [FriendReading] {
        FriendsBooks.friends(with: bookID, in: friendsBooks).filter { $0.book.state == .reading }
    }

    /// Page `n` of `total`, from the percentage and the book's page count.
    func pages(for entry: ShelfEntry) -> ReadingPace.Pages? {
        guard let percent = entry.progress, let total = bookExtras[entry.bookID]?.pages else { return nil }
        return ReadingPace.pages(percent: percent, total: total, history: progressHistory[entry.bookID] ?? [],
                                 startedOn: entry.dateAdded.flatMap(Suggestions.parseDate))
    }

    /// Roughly when `entry` will be finished at the pace so far.
    func finishEstimate(for entry: ShelfEntry) -> Date? {
        guard let history = progressHistory[entry.bookID] else { return nil }
        return ReadingPace.estimate(history, startedOn: entry.dateAdded.flatMap(Suggestions.parseDate))
    }

    // MARK: - Stats

    /// Worked out from the Read shelf — the cached copy if it's fresh,
    /// otherwise a reload (which also refreshes that cache for everyone else).
    func loadStats(force: Bool = false) async {
        guard !isLoadingStats else { return }
        abandoned = await AbandonedBooks.all()
        let extras = await BookExtras.all()
        let cached = ShelfCache.read(.read)
        if let cached { readingStats = ReadingStats.compute(from: cached.entries, extras: extras) }
        let stale = cached.map { ShelfCache.isStale($0.fetched) } ?? true
        guard force || stale else { return }

        isLoadingStats = true
        defer { isLoadingStats = false }
        if let entries = try? await ShelfLibrary.load(.read) {
            ShelfCache.write(entries, for: .read)
            setCount(entries.count, for: .read)
            readingStats = ReadingStats.compute(from: entries, extras: extras)
        }
        if currentlyReading.isEmpty { await loadCurrentlyReading() }
        await loadChallenge(force: force)
    }

    /// Reads this year's Reading Challenge and, when you've joined it, makes
    /// its goal the Stats goal. A page the app can't read changes nothing.
    func loadChallenge(force: Bool = false) async {
        guard loggedIn, Preferences.shared.useGoodreadsChallenge else { return }
        let year = Calendar.current.component(.year, from: Date())
        try? await DataCache.load("challenge", String(year), ttl: 12 * 3600, force: force) {
            try await GoodreadsChallenge.fetch(year: year)
        } show: { [weak self] challenge, _ in
            self?.challenge = challenge
            if let goal = challenge.goal, Preferences.shared.useGoodreadsChallenge {
                Preferences.shared.yearlyGoal = goal
            }
        }
    }

    /// Fetches the Goodreads page of every read book whose page count and
    /// genres aren't known yet, a few at a time, refreshing the stats as it
    /// goes. Book pages are public, so this doesn't touch the web session.
    func fillBookExtras() async {
        guard !isFillingExtras, let entries = ShelfCache.read(.read)?.entries else { return }
        isFillingExtras = true
        defer {
            isFillingExtras = false
            extrasTotal = 0
        }

        let known = await BookExtras.all()
        let missing = entries.filter { known[$0.bookID] == nil }
        extrasDone = 0
        extrasTotal = missing.count

        await withTaskGroup(of: Void.self) { group in
            var queue = missing.makeIterator()
            func addNext() {
                guard let entry = queue.next() else { return }
                group.addTask { await BookExtras.fetch(entry) }
            }
            for _ in 0..<3 { addNext() }
            while await group.next() != nil {
                extrasDone += 1
                if extrasDone % 15 == 0 {
                    readingStats = ReadingStats.compute(from: entries, extras: await BookExtras.all())
                }
                addNext()
            }
        }
        readingStats = ReadingStats.compute(from: entries, extras: await BookExtras.all())
    }

    // MARK: - Friends

    /// Activity and the friend list each cost a full page load, and the
    /// shared web view only lets one navigation happen at a time — running
    /// them back to back nearly doubles the wait. The friend list (each
    /// friend's own "currently reading" status, from `/friend`) loads first
    /// now — confirmed working markup, and what the pane falls back to
    /// whenever the activity table comes back empty — so it unblocks the
    /// view; the home feed's activity table runs afterward as a best-effort
    /// supplement, since Goodreads appears to have restructured it (it can
    /// still render visually while no longer matching what this app scrapes
    /// for it).
    func loadFriends(force: Bool = false) async {
        guard !isLoadingFriends else { return }
        if let fetched = friendsFetched, !force,
           Date().timeIntervalSince(fetched) < DataCache.TTL.friends { return }

        isLoadingFriends = true
        if friends.isEmpty { friendsNote = String(localized: "Looking at your Goodreads friends…") }

        // Last session's list shows instantly; the page load runs behind it.
        do {
            try await DataCache.load("friends", "list", ttl: DataCache.TTL.friends, force: force,
                                     accept: { !$0.isEmpty }) {
                try await GoodreadsFriends.fetchFriends()
            } show: { [weak self] list, fromCache in
                self?.friends = list
                if !list.isEmpty { self?.friendsNote = nil }
                if !fromCache { Task { await FriendNotifier.friendsRefreshed(list) } }
            }
        } catch {
            friendsNote = error.localizedDescription
            isLoadingFriends = false
            return
        }
        isLoadingFriends = false

        try? await DataCache.load("friends", "activity", ttl: DataCache.TTL.friends, force: force,
                                  accept: { !$0.isEmpty }) {
            try await GoodreadsFriends.fetchActivity()
        } show: { [weak self] activity, _ in
            self?.friendActivity = activity
        }
        friendsFetched = Date()

        friendsNote = (friends.isEmpty && friendActivity.isEmpty)
            ? String(localized: "Nothing found — Goodreads may have changed this page's layout.")
            : nil
    }

    /// Avatar for a friend named in an activity row — update rows don't
    /// carry one, so it's looked up from the friend list by user id.
    func avatarURL(forFriendProfile url: URL?) -> URL? {
        guard let id = GoodreadsFriends.userID(from: url) else { return nil }
        return friends.first { $0.id == id }?.avatarURL
    }

    func openFriendProfile(_ url: URL) async {
        activeSheet = .friendProfile
        friendProfileURL = url
        friendProfile = nil
        friendProfileError = nil
        isLoadingFriendProfile = true
        closeFriendShelf()
        tasteComparison = nil
        tasteError = nil
        defer { isLoadingFriendProfile = false }

        do {
            try await DataCache.load("profile", url.absoluteString, ttl: DataCache.TTL.profile,
                                     accept: { !$0.name.isEmpty }) {
                try await GoodreadsFriends.fetchProfile(url: url)
            } show: { [weak self] profile, _ in
                guard let self, self.friendProfileURL == url else { return }
                self.friendProfile = profile
                self.isLoadingFriendProfile = false
            }
        } catch {
            friendProfileError = error.localizedDescription
        }
    }

    // MARK: - A friend's shelves

    /// A friend's shelf reuses `ShelfLibrary.load` pointed at their id
    /// instead of the signed-in user's own — same `/review/list` template,
    /// same rating column, so their ratings come along for free.
    func openFriendShelf(_ shelf: Shelf) async {
        guard let userID = GoodreadsFriends.userID(from: friendProfileURL) else { return }

        friendShelf = shelf
        friendShelfEntries = []
        friendShelfError = nil
        isLoadingFriendShelf = true
        defer { isLoadingFriendShelf = false }

        do {
            try await DataCache.load("friend-shelf", "\(userID)/\(shelf.name)",
                                     ttl: DataCache.TTL.friendShelf) {
                try await ShelfLibrary.load(shelf, ofUser: userID)
            } show: { [weak self] entries, _ in
                guard let self, self.friendShelf == shelf else { return }
                self.friendShelfEntries = entries
                self.isLoadingFriendShelf = false
            }
        } catch {
            friendShelfError = error.localizedDescription
        }
    }

    /// Loads the friend's Read shelf (cached like any friend shelf) and
    /// your own, and compares them.
    func compareTastes() async {
        guard let userID = GoodreadsFriends.userID(from: friendProfileURL), !isComparingTastes else { return }
        closeFriendShelf()
        isComparingTastes = true
        tasteError = nil
        defer { isComparingTastes = false }

        do {
            let key = "\(userID)/\(Shelf.read.name)"
            let theirs: [ShelfEntry]
            if let hit = await DataCache.shared.read([ShelfEntry].self, "friend-shelf", key,
                                                     ttl: DataCache.TTL.friendShelf), !hit.isStale {
                theirs = hit.value
            } else {
                theirs = try await ShelfLibrary.load(.read, ofUser: userID)
                await DataCache.shared.write(theirs, "friend-shelf", key)
            }

            var mine = ShelfCache.read(.read)?.entries ?? []
            if mine.isEmpty {
                mine = try await ShelfLibrary.load(.read)
                ShelfCache.write(mine, for: .read)
            }
            let others = shelves.filter { $0.name != Shelf.read.name }
                .flatMap { ShelfCache.read($0)?.entries ?? [] }
            tasteComparison = TasteComparison.compute(myRead: mine, myOtherShelves: others, theirRead: theirs)
        } catch {
            tasteError = error.localizedDescription
        }
    }

    func closeFriendShelf() {
        friendShelf = nil
        friendShelfEntries = []
        friendShelfError = nil
    }

    // MARK: - Author page

    func openAuthorPage(_ url: URL) async {
        activeSheet = .authorPage
        authorPageURL = url
        authorPage = nil
        authorPageError = nil
        isLoadingAuthorPage = true
        defer { isLoadingAuthorPage = false }

        do {
            try await DataCache.load("author", url.absoluteString, ttl: DataCache.TTL.authorPage) {
                try await GoodreadsAuthorPage.fetch(url: url)
            } show: { [weak self] page, _ in
                guard let self, self.authorPageURL == url else { return }
                self.authorPage = page
                self.isLoadingAuthorPage = false
            }
        } catch {
            authorPageError = error.localizedDescription
        }
    }

    // MARK: - Sheet presentation

    /// Opening one sheet from inside another — a detail sheet's author link,
    /// an author's book row opening a detail sheet — just reassigns
    /// `activeSheet`; SwiftUI dismisses whatever's showing and presents the
    /// new one on its own. `activeSheet`'s doc comment has the rest of this
    /// story: it used to take eight sibling `.sheet` modifiers to get here,
    /// since SwiftUI won't stack a second sheet on a view already presenting
    /// one from the same modifier chain, and the old fix for that was a
    /// dismiss-then-sleep-350ms-then-present hand-off.
    func showBookDetail(_ book: Book) {
        activeSheet = .detail(book)
    }

    func showAuthorPage(_ url: URL) {
        Task { await openAuthorPage(url) }
    }

    /// Shows the cached copy immediately, then refreshes behind it.
    func loadShelf(force: Bool = false) async {
        guard let shelf = currentShelf else { return }

        shelfTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoad(of: shelf)
        }
        shelfTask = task
        await task.value
    }

    private func performLoad(of shelf: Shelf) async {
        bookExtras = await BookExtras.all()
        favouriteAuthors = ShelfFilters.favouriteAuthors(in: ShelfCache.read(.read)?.entries ?? [])
        if let cached = ShelfCache.read(shelf) {
            shelfEntries = cached.entries
            cacheNote = String(localized: "cached \(ShelfCache.age(cached.fetched))")
        } else {
            shelfEntries = []
            cacheNote = nil
        }

        isLoadingShelf = true
        loadProgress = shelfEntries.isEmpty ? String(localized: "Loading…") : nil
        defer {
            isLoadingShelf = false
            loadProgress = nil
        }

        do {
            var fetched = try await ShelfLibrary.load(shelf) { [weak self] count, pages in
                guard let self else { return }
                self.loadProgress = pages > 1 ? String(localized: "\(count) of ~\(pages * ShelfLibrary.perPage) so far…") : nil
            }
            if shelf.name == "currently-reading" { await backfillProgress(into: &fetched) }

            // The pane may have changed while we were paging.
            guard !Task.isCancelled, currentShelf?.name == shelf.name else { return }

            shelfEntries = fetched
            cacheNote = String(localized: "updated just now")
            ShelfCache.write(fetched, for: shelf)
            setCount(fetched.count, for: shelf)
            Task { await fetchCleanTitles() }

            if fetched.isEmpty {
                status = Status(text: String(localized: "Nothing on \(shelf.title) yet."), isError: false)
            }
        } catch is CancellationError {
            // Superseded by another shelf — say nothing.
        } catch {
            guard !Task.isCancelled, currentShelf?.name == shelf.name else { return }
            let message = error.localizedDescription
            status = Status(text: message, isError: true)
            // The JS side throws the literal "signed out" the moment a fetch
            // redirects to the sign-in page — a more immediate signal than
            // `WebSession.isSignedIn`, which is only ever refreshed by an
            // explicit check and can otherwise sit stale for a while after
            // the session actually lapses server-side.
            if !WebSession.shared.isSignedIn || message.localizedCaseInsensitiveContains("signed out") {
                loggedIn = false
                activeSheet = .signIn
            }
        }
    }

    /// Offers `action` back as an "Undo" button in the status bar for a
    /// short window — used after a remove or move, both of which are cheap
    /// to invert (the opposite shelf call) but easy to fat-finger from a
    /// context menu.
    private func offerUndo(_ label: String, action: @escaping () async -> Void) {
        undoResetTask?.cancel()
        pendingUndo = PendingUndo(label: label, action: action)
        undoResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.pendingUndo = nil
        }
    }

    func performPendingUndo() async {
        guard let pending = pendingUndo else { return }
        pendingUndo = nil
        undoResetTask?.cancel()
        await pending.action()
    }

    /// A trailing note for a status message when a write succeeded but its
    /// own read-back verification was inconclusive — see
    /// `ShelfService.WriteVerification`. Silent on `.confirmed`, since that's
    /// the ordinary case and doesn't need calling out.
    private func caveat(_ verification: ShelfService.WriteVerification) -> String {
        verification == .unknown ? String(localized: " (couldn't confirm — check the shelf)") : ""
    }

    /// Every write action funnels its failure through here so a session that
    /// silently expired — Goodreads' cookie can lapse without the app
    /// hearing about it any other way — gets caught and re-prompted
    /// immediately, rather than leaving `loggedIn` showing stale state until
    /// the next explicit `checkSession()`. `WebSession.isSignedIn` is itself
    /// only ever refreshed by an explicit check, so it can be just as stale;
    /// the JS side's own `getDoc` throws the literal string "signed out" the
    /// moment a fetch redirects to the sign-in page, and that's the more
    /// immediate signal.
    private func reportWriteFailure(_ prefix: String, error: Error) {
        let message = error.localizedDescription
        if !WebSession.shared.isSignedIn || message.localizedCaseInsensitiveContains("signed out") {
            loggedIn = false
            status = Status(text: String(localized: "\(prefix): you're signed out. Sign in and try again."), isError: true)
            activeSheet = .signIn
        } else {
            status = Status(text: String(localized: "\(prefix): \(message)"), isError: true)
        }
    }

    func remove(_ entry: ShelfEntry) async {
        guard let shelf = currentShelf else { return }

        busyBookID = entry.bookID
        status = nil
        defer { busyBookID = nil }

        do {
            let verification = try await ShelfService.remove(bookID: entry.bookID, from: shelf)
            shelfEntries.removeAll { $0.id == entry.id }
            ShelfCache.write(shelfEntries, for: shelf)
            setCount(shelfEntries.count, for: shelf)
            status = Status(text: String(localized: "Removed “\(entry.title)” from \(shelf.title).\(caveat(verification))"), isError: false)

            offerUndo(String(localized: "Undo remove of “\(entry.title)”")) { [weak self] in
                await self?.restoreRemoved(entry, to: shelf)
            }
        } catch {
            reportWriteFailure(String(localized: "Couldn’t remove “\(entry.title)”"), error: error)
        }
    }

    /// Re-adds a book removed via `remove(_:)`, for the undo button. A plain
    /// `ShelfService.add` — Goodreads doesn't distinguish "never shelved"
    /// from "shelved, then removed", so this is exactly what re-shelving it
    /// by hand would do.
    private func restoreRemoved(_ entry: ShelfEntry, to shelf: Shelf) async {
        do {
            try await ShelfService.add(bookID: entry.bookID, to: shelf)
            bumpCountIfNew(bookID: entry.bookID, shelf: shelf)
            if currentShelf?.name == shelf.name, !shelfEntries.contains(where: { $0.id == entry.id }) {
                shelfEntries.append(entry)
                ShelfCache.write(shelfEntries, for: shelf)
                setCount(shelfEntries.count, for: shelf)
            }
            status = Status(text: String(localized: "Restored “\(entry.title)” to \(shelf.title)."), isError: false)
        } catch {
            reportWriteFailure(String(localized: "Couldn’t undo"), error: error)
        }
    }

    /// Removes `entry` from `shelf` without assuming it's the shelf pane
    /// currently on screen — used to undo a "move to a custom shelf" (a
    /// stacking add, not a move), which can be triggered from Search or
    /// Suggestions just as easily as from a shelf pane.
    private func removeFromShelf(_ entry: ShelfEntry, shelf: Shelf, successText: String) async {
        do {
            try await ShelfService.remove(bookID: entry.bookID, from: shelf)
            bumpCount(-1, for: shelf)
            if currentShelf?.name == shelf.name {
                shelfEntries.removeAll { $0.id == entry.id }
                ShelfCache.write(shelfEntries, for: shelf)
                setCount(shelfEntries.count, for: shelf)
            }
            status = Status(text: successText, isError: false)
        } catch {
            reportWriteFailure(String(localized: "Couldn’t undo"), error: error)
        }
    }

    /// The three built-in shelves are exclusive, so adding to one moves it.
    /// Custom shelves stack instead, and the book stays where it was.
    func move(_ entry: ShelfEntry, to shelf: Shelf) async {
        busyBookID = entry.bookID
        status = nil
        defer { busyBookID = nil }

        let previousShelf = currentShelf
        do {
            let verification = try await ShelfService.add(bookID: entry.bookID, to: shelf)
            bumpCountIfNew(bookID: entry.bookID, shelf: shelf)

            var movedAwayFrom: Shelf?
            if let current = previousShelf, current.isExclusive, shelf.isExclusive,
               current.name != shelf.name {
                shelfEntries.removeAll { $0.id == entry.id }
                ShelfCache.write(shelfEntries, for: current)
                setCount(shelfEntries.count, for: current)
                movedAwayFrom = current
            }
            let verb = shelf.isExclusive ? "→" : String(localized: "also on")
            status = Status(text: String(localized: "“\(entry.title)” \(verb) \(shelf.title)\(caveat(verification))"), isError: false)

            if let movedAwayFrom {
                offerUndo(String(localized: "Undo move of “\(entry.title)”")) { [weak self] in
                    await self?.move(entry, to: movedAwayFrom)
                }
            } else if !shelf.isExclusive {
                offerUndo(String(localized: "Undo")) { [weak self] in
                    await self?.removeFromShelf(entry, shelf: shelf,
                                                successText: String(localized: "Removed “\(entry.title)” from \(shelf.title)."))
                }
            }
        } catch {
            reportWriteFailure(String(localized: "Couldn’t move “\(entry.title)”"), error: error)
        }
    }

    func updateProgress(_ entry: ShelfEntry, percent: Int?, page: Int?, note: String) async {
        busyBookID = entry.bookID
        status = nil
        defer { busyBookID = nil }

        do {
            let result = try await ShelfService.updateProgress(
                bookID: entry.bookID, percent: percent, page: page, note: note
            )
            // Prefer what Goodreads actually recorded — a page-mode entry
            // has no percent from the caller otherwise.
            let resolvedPercent = result.percent ?? percent
            if let resolvedPercent {
                await ReadingPace.record(resolvedPercent, for: entry.bookID)
                progressHistory = await ReadingPace.all()
            }

            if let index = shelfEntries.firstIndex(where: { $0.id == entry.id }) {
                shelfEntries[index].progress = resolvedPercent
            }
            if let index = currentlyReading.firstIndex(where: { $0.id == entry.id }) {
                currentlyReading[index].progress = resolvedPercent
                ShelfCache.write(currentlyReading, for: .currentlyReading)
                ReadingReminder.reschedule()
            }
            let amount = resolvedPercent.map { "\($0)%" } ?? page.map { String(localized: "page \($0)") } ?? String(localized: "progress")
            status = Status(text: String(localized: "Updated “\(entry.title)” to \(amount)."), isError: false)
        } catch {
            status = Status(text: String(localized: "Couldn’t update progress: \(error.localizedDescription)"),
                            isError: true)
        }
    }

    /// Rating, date read and the Read shelf in one post.
    func finish(bookID: String, title: String, rating: Int?, dateRead: Date?, note: String) async {
        busyBookID = bookID
        status = nil
        defer { busyBookID = nil }

        do {
            try await ShelfService.finish(bookID: bookID, rating: rating, dateRead: dateRead, note: note)

            bumpCountIfNew(bookID: bookID, shelf: .read)
            if let current = currentShelf, current.isExclusive, current.name != "read" {
                shelfEntries.removeAll { $0.bookID == bookID }
                ShelfCache.write(shelfEntries, for: current)
                setCount(shelfEntries.count, for: current)
            }

            let stars = rating.map { String(localized: " at \($0)★") } ?? ""
            status = Status(text: String(localized: "Marked “\(title)” read\(stars)."), isError: false)
        } catch {
            status = Status(text: String(localized: "Couldn’t finish “\(title)”: \(error.localizedDescription)"),
                            isError: true)
        }
    }

    // MARK: - Abandoned books

    /// Stops reading `entry`: records it here, then moves it on Goodreads.
    func abandon(_ entry: ShelfEntry, reason: String,
                 destination: AbandonedBooks.Destination, alsoShelf: Shelf?) async {
        busyBookID = entry.bookID
        status = nil
        defer { busyBookID = nil }

        do {
            switch destination {
            case .wantToRead:
                _ = try await ShelfService.add(bookID: entry.bookID, to: .wantToRead)
                bumpCountIfNew(bookID: entry.bookID, shelf: .wantToRead)
                bumpCount(-1, for: .currentlyReading)
                if let alsoShelf {
                    _ = try await ShelfService.add(bookID: entry.bookID, to: alsoShelf)
                    bumpCountIfNew(bookID: entry.bookID, shelf: alsoShelf)
                }
            case .remove:
                _ = try await ShelfService.remove(bookID: entry.bookID, from: .currentlyReading)
                bumpCount(-1, for: .currentlyReading)
            }
        } catch {
            reportWriteFailure(String(localized: "Couldn’t stop reading “\(entry.title)”"), error: error)
            return
        }

        await AbandonedBooks.add(AbandonedBook(entry: entry, reason: reason))
        abandoned = await AbandonedBooks.all()

        currentlyReading.removeAll { $0.bookID == entry.bookID }
        ShelfCache.write(currentlyReading, for: .currentlyReading)
        if currentShelf?.name == Shelf.currentlyReading.name {
            shelfEntries.removeAll { $0.bookID == entry.bookID }
            ShelfCache.write(shelfEntries, for: .currentlyReading)
        }
        ReadingReminder.reschedule()
        status = Status(text: String(localized: "Stopped reading “\(entry.title)”."), isError: false)
    }

    /// Back on Currently Reading, and off the abandoned list.
    func resumeAbandoned(_ book: AbandonedBook) async {
        busyBookID = book.bookID
        status = nil
        defer { busyBookID = nil }

        do {
            _ = try await ShelfService.add(bookID: book.bookID, to: .currentlyReading)
            bumpCountIfNew(bookID: book.bookID, shelf: .currentlyReading)
        } catch {
            reportWriteFailure(String(localized: "Couldn’t resume “\(book.title)”"), error: error)
            return
        }
        await AbandonedBooks.remove(bookID: book.bookID)
        abandoned = await AbandonedBooks.all()
        status = Status(text: String(localized: "“\(book.title)” is back on Currently Reading."), isError: false)
        await loadCurrentlyReading(force: true)
    }

    /// Drops the record only; Goodreads isn't touched.
    func forgetAbandoned(_ book: AbandonedBook) async {
        await AbandonedBooks.remove(bookID: book.bookID)
        abandoned = await AbandonedBooks.all()
    }

    /// Reloads what a backup restore replaced.
    func reloadLocalData() async {
        progressHistory = await ReadingPace.all()
        abandoned = await AbandonedBooks.all()
    }

    /// Stars only — doesn't touch shelf membership. See `ShelfService.rate`.
    func rate(_ entry: ShelfEntry, stars: Int) async {
        busyBookID = entry.bookID
        status = nil
        defer { busyBookID = nil }

        do {
            try await ShelfService.rate(bookID: entry.bookID, stars: stars)
            if let index = shelfEntries.firstIndex(where: { $0.id == entry.id }) {
                shelfEntries[index].rating = stars
            }
            if let shelf = currentShelf { ShelfCache.write(shelfEntries, for: shelf) }
            status = Status(text: String(localized: "Rated “\(entry.title)” \(stars)★."), isError: false)
        } catch {
            status = Status(text: String(localized: "Couldn’t rate “\(entry.title)”: \(error.localizedDescription)"),
                            isError: true)
        }
    }

    // MARK: - Search results

    /// Search results are identified by ISBN (Google Books has no concept of
    /// a Goodreads id), so every action against Goodreads resolves one first.
    func shelve(_ book: Book, to shelf: Shelf) async {
        busyBookID = book.id
        status = nil
        defer { busyBookID = nil }

        do {
            let bookID = try await GoodreadsLookup.bookID(for: book)
            let verification = try await ShelfService.add(bookID: bookID, to: shelf)
            loggedIn = true
            bumpCountIfNew(bookID: bookID, shelf: shelf)
            status = Status(text: String(localized: "“\(book.title)” → \(shelf.title)\(caveat(verification))"), isError: false)
        } catch {
            if !WebSession.shared.isSignedIn {
                status = Status(text: String(localized: "Sign in first — click Log In below."), isError: true)
                activeSheet = .signIn
            } else {
                reportWriteFailure(String(localized: "Couldn’t shelve “\(book.title)”"), error: error)
            }
        }
    }

    /// The "Mark Read & Rate…" sheet for a search result — resolves to a
    /// Goodreads id, then posts through the same call `finish(bookID:...)` uses.
    func finishBook(_ book: Book, rating: Int?, dateRead: Date?, note: String) async {
        busyBookID = book.id
        status = nil
        defer { busyBookID = nil }

        do {
            let bookID = try await GoodreadsLookup.bookID(for: book)
            try await ShelfService.finish(bookID: bookID, rating: rating, dateRead: dateRead, note: note)
            bumpCountIfNew(bookID: bookID, shelf: .read)
            let stars = rating.map { String(localized: " at \($0)★") } ?? ""
            status = Status(text: String(localized: "Marked “\(book.title)” read\(stars)."), isError: false)
        } catch {
            status = Status(text: String(localized: "Couldn’t finish “\(book.title)”: \(error.localizedDescription)"),
                            isError: true)
        }
    }

    func openOnGoodreads(_ book: Book) async {
        do {
            let bookID = try await GoodreadsLookup.bookID(for: book)
            openOnGoodreads(bookID: bookID)
        } catch {
            status = Status(text: String(localized: "Couldn’t find “\(book.title)” on Goodreads."), isError: true)
        }
    }

    // MARK: - Export

    func exportCurrentShelf() {
        guard let shelf = currentShelf, !shelfEntries.isEmpty else {
            status = Status(text: String(localized: "Nothing to export."), isError: true)
            return
        }

        let entries = shelfEntries
        Task {
            let text = CSVExport.csv(for: entries, shelf: shelf, notes: await BookNotes.all())
            report(CSVExport.save(text, suggestedName: "goodreads-\(shelf.name).csv"),
                   successText: { String(localized: "Exported \(entries.count) books to \($0).") })
        }
    }

    /// Fetches every shelf and writes one combined file. This is the backup.
    func exportEverything() async {
        isExporting = true
        defer {
            isExporting = false
            exportProgress = nil
        }

        var rows: [(Shelf, [ShelfEntry])] = []
        // This is the backup — a shelf that silently drops out of it because
        // its fetch failed is worse than one the export just tells you about.
        var failedShelves: [String] = []
        for shelf in shelves {
            exportProgress = String(localized: "Reading \(shelf.title)…")
            do {
                let entries = try await ShelfLibrary.load(shelf)
                ShelfCache.write(entries, for: shelf)
                rows.append((shelf, entries))
            } catch {
                failedShelves.append(shelf.title)
            }
        }
        exportProgress = String(localized: "Writing file…")

        // Each shelf contributes data rows only — reusing `CSVExport.csv`
        // (header + rows) per shelf and stripping their headers by splitting
        // on "\n" broke on any quoted field that itself contained a newline,
        // and silently left a blank line for an empty shelf.
        var lines = [CSVExport.header]
        var total = 0
        let notes = await BookNotes.all()
        for (shelf, entries) in rows {
            total += entries.count
            lines.append(contentsOf: CSVExport.dataLines(for: entries, shelf: shelf, notes: notes))
        }
        let text = lines.joined(separator: "\n") + "\n"

        report(CSVExport.save(text, suggestedName: "goodreads-library.csv"), successText: { name in
            failedShelves.isEmpty
                ? String(localized: "Exported \(total) books to \(name).")
                : String(localized: "Exported \(total) books to \(name). Couldn’t read: \(failedShelves.joined(separator: ", ")).")
        }, hadPartialFailure: !failedShelves.isEmpty)
    }

    private func report(_ result: CSVExport.SaveResult, successText: (String) -> String,
                        hadPartialFailure: Bool = false) {
        switch result {
        case .saved(let name):
            status = Status(text: successText(name), isError: hadPartialFailure)
        case .cancelled:
            break
        case .failed(let message):
            status = Status(text: String(localized: "Couldn’t save the export: \(message)"), isError: true)
        }
    }

    func openOnGoodreads(bookID: String) {
        guard let url = Self.goodreadsURL(bookID: bookID) else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated static func goodreadsURL(bookID: String) -> URL? {
        URL(string: "https://www.goodreads.com/book/show/\(bookID)")
    }

    // MARK: - Drag and drop

    /// What a shelf row carries when dragged: its entry id, tagged so text
    /// dragged in from elsewhere isn't mistaken for a book.
    nonisolated static let dragPrefix = "goodreads-entry:"

    /// Books dropped on a sidebar shelf. Only rows of the shelf on screen can
    /// be dragged, so they're looked up there.
    func drop(_ payloads: [String], on shelf: Shelf) -> Bool {
        let ids = payloads.compactMap { payload -> String? in
            guard payload.hasPrefix(Self.dragPrefix) else { return nil }
            return String(payload.dropFirst(Self.dragPrefix.count))
        }
        let entries = ids.compactMap { id in shelfEntries.first { $0.id == id } }
        guard !entries.isEmpty, currentShelf?.name != shelf.name else { return false }
        Task {
            for entry in entries { await move(entry, to: shelf) }
        }
        return true
    }
}

/// What Home's suggestions cache stores between launches.
struct SavedSuggestions: Codable {
    let items: [Suggestion]
    let basis: [ShelfEntry]
}
