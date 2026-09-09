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
    @Published var showDiagnostics = false

    /// Sign-in and the debug browser both host the same shared `WKWebView`
    /// (`WebViewHost`), which can only be attached to one visible sheet at a
    /// time — so they're one optional, not two independent bools, which
    /// makes it impossible for both to be "showing" at once.
    enum WebSheet { case signIn, browser }
    @Published var webSheet: WebSheet?

    // Home
    @Published var suggestions: [Suggestion] = []
    @Published var suggestionBasis: [ShelfEntry] = []
    @Published var isBuildingSuggestions = false
    @Published var suggestionNote: String?
    @Published var progressTarget: ShelfEntry?
    @Published var finishTarget: ShelfEntry?
    @Published var finishBook: Book?
    @Published var detailBook: Book?

    @Published var currentlyReading: [ShelfEntry] = []
    @Published var isLoadingCurrentlyReading = false

    // Search filters
    @Published var searchLanguage: BookLanguage = .any
    @Published var searchSortNewest = false
    @Published var searchSubject = ""

    // Friends
    @Published var friends: [GoodreadsFriends.Friend] = []
    @Published var friendActivity: [GoodreadsFriends.Activity] = []
    @Published var isLoadingFriends = false
    @Published var friendsNote: String?

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
        case shelf(String)      // shelf slug
    }

    struct Status: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    private var searchTask: Task<Void, Never>?
    private var shelfTask: Task<Void, Never>?
    private let debounce = Duration.milliseconds(250)

    var isHome: Bool { selection == .home }

    var currentShelf: Shelf? {
        guard case .shelf(let slug) = selection else { return nil }
        return shelves.first { $0.name == slug } ?? Shelf.fromSlug(slug)
    }

    var visibleEntries: [ShelfEntry] {
        shelfEntries.filter { $0.matches(filter) }
    }

    // MARK: - Search

    /// Called on every keystroke. Waits for a pause before hitting the network,
    /// and cancels any request still in flight from the previous keystroke.
    func queryChanged() {
        searchTask?.cancel()
        status = nil

        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)

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
            let found = try await GoogleBooksClient.search(
                term, language: searchLanguage, sortNewest: searchSortNewest, subject: searchSubject
            )

            // A newer keystroke may have superseded this request while it was
            // in flight — drop the stale response rather than flashing it.
            guard !Task.isCancelled,
                  term == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

            results = found
            isSearching = false
            if found.isEmpty {
                status = Status(text: "No books matched “\(term)”.", isError: false)
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

    func startSignIn() { webSheet = .signIn }
    func startBrowser() { webSheet = .browser }

    func signInSheetClosed() async {
        loggedIn = await WebSession.shared.refreshSignInState()
        status = Status(text: loggedIn ? "Signed in." : "Still signed out.", isError: !loggedIn)
        if loggedIn {
            await refreshShelfList()
            if currentShelf != nil { await loadShelf(force: true) }
        }
    }

    func checkSession() async {
        loggedIn = await WebSession.shared.refreshSignInState()
        if loggedIn { await refreshShelfList() }
    }

    func signOut() async {
        await WebSession.shared.signOut()
        loggedIn = WebSession.shared.isSignedIn
        shelfEntries = []
        shelves = Shelf.builtIn
        ShelfCache.clear()
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
            status = Status(text: "Couldn’t read your shelf list: \(error.localizedDescription)",
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
        shelfEntries = []
        cacheNote = nil

        switch selection {
        case .shelf:
            await loadShelf()
        case .home:
            await buildSuggestions()
            await loadCurrentlyReading()
        case .suggestions:
            await buildSuggestions()
        case .friends:
            await loadFriends()
        case .search:
            break
        }
    }

    // MARK: - Home

    /// Suggestions come from the Read shelf, so make sure we have it. The cache
    /// covers the common case without a fetch.
    func buildSuggestions(force: Bool = false) async {
        guard !isBuildingSuggestions else { return }
        if !suggestions.isEmpty && !force { return }

        isBuildingSuggestions = true
        suggestionNote = "Looking at what you finished recently…"
        defer { isBuildingSuggestions = false }

        var readEntries = ShelfCache.read(.read)?.entries ?? []

        if readEntries.isEmpty || force {
            do {
                readEntries = try await ShelfLibrary.load(.read)
                ShelfCache.write(readEntries, for: .read)
                setCount(readEntries.count, for: .read)
            } catch {
                suggestionNote = "Couldn’t read your Read shelf: \(error.localizedDescription)"
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
            suggestionNote = "Finding books…"
            let result = try await Suggestions.build(
                from: readEntries,
                excludingTitles: shelvedTitles,
                windowDays: prefs.suggestionWindowDays,
                language: prefs.bookLanguage,
                includeUnknown: prefs.includeUnknownLanguage
            )

            suggestions = result.items
            suggestionBasis = result.basis

            if result.basis.isEmpty {
                suggestionNote = "Nothing finished in the last \(prefs.suggestionWindowDays) days — mark a book read and this fills in."
            } else if result.items.isEmpty {
                suggestionNote = prefs.bookLanguage == .any
                    ? "No new books found from those authors."
                    : "Nothing found in \(prefs.bookLanguage.label.lowercased()). Try widening the language in Settings."
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
        if let cached = ShelfCache.read(.currentlyReading) {
            currentlyReading = cached.entries
        }
        guard currentlyReading.isEmpty || force else { return }

        isLoadingCurrentlyReading = true
        defer { isLoadingCurrentlyReading = false }

        if var fetched = try? await ShelfLibrary.load(.currentlyReading) {
            await backfillProgress(into: &fetched)
            currentlyReading = fetched
            ShelfCache.write(fetched, for: .currentlyReading)
            setCount(fetched.count, for: .currentlyReading)
        }
    }

    /// The shelf listing itself carries no progress field — only the home
    /// feed's Currently Reading widget does. Best-effort: a failure here
    /// just leaves entries showing no progress, same as before this existed.
    private func backfillProgress(into entries: inout [ShelfEntry]) async {
        guard let progress = try? await ShelfService.currentProgress(), !progress.isEmpty else { return }
        for i in entries.indices {
            if let percent = progress[entries[i].bookID] {
                entries[i].progress = percent
            }
        }
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
        if !friends.isEmpty && !force { return }

        isLoadingFriends = true
        friendsNote = "Looking at your Goodreads friends…"

        do {
            friends = try await GoodreadsFriends.fetchFriends()
        } catch {
            friendsNote = error.localizedDescription
            isLoadingFriends = false
            return
        }
        isLoadingFriends = false

        if let fetched = try? await GoodreadsFriends.fetchActivity() {
            friendActivity = fetched
        }

        friendsNote = (friends.isEmpty && friendActivity.isEmpty)
            ? "Nothing found — Goodreads may have changed this page's layout."
            : nil
    }

    /// Avatar for a friend named in an activity row — update rows don't
    /// carry one, so it's looked up from the friend list by user id.
    func avatarURL(forFriendProfile url: URL?) -> URL? {
        guard let id = GoodreadsFriends.userID(from: url) else { return nil }
        return friends.first { $0.id == id }?.avatarURL
    }

    func openFriendProfile(_ url: URL) async {
        friendProfileURL = url
        friendProfile = nil
        friendProfileError = nil
        isLoadingFriendProfile = true
        closeFriendShelf()
        defer { isLoadingFriendProfile = false }

        do {
            friendProfile = try await GoodreadsFriends.fetchProfile(url: url)
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
            friendShelfEntries = try await ShelfLibrary.load(shelf, ofUser: userID)
        } catch {
            friendShelfError = error.localizedDescription
        }
    }

    func closeFriendShelf() {
        friendShelf = nil
        friendShelfEntries = []
        friendShelfError = nil
    }

    // MARK: - Author page

    func openAuthorPage(_ url: URL) async {
        authorPageURL = url
        authorPage = nil
        authorPageError = nil
        isLoadingAuthorPage = true
        defer { isLoadingAuthorPage = false }

        do {
            authorPage = try await GoodreadsAuthorPage.fetch(url: url)
        } catch {
            authorPageError = error.localizedDescription
        }
    }

    // MARK: - Sheet hand-off

    /// `detailBook`, `authorPageURL` and `friendProfileURL` each drive their
    /// own `.sheet` on `ContentView`. SwiftUI won't stack a second sheet on a
    /// view that's already presenting one from the same modifier chain — an
    /// author's book row opening a detail sheet, or a detail sheet's author
    /// link opening the author page, would otherwise silently do nothing
    /// because the presenting view (ContentView) already has a sheet up.
    /// This clears whatever's open, waits a beat for the dismiss, then opens
    /// the next — a no-op delay when nothing was open to begin with.
    private func handOffToNextSheet(_ present: @escaping () -> Void) {
        let closingSomething = detailBook != nil || authorPageURL != nil || friendProfileURL != nil
        detailBook = nil
        authorPageURL = nil
        authorPage = nil
        friendProfileURL = nil
        friendProfile = nil
        closeFriendShelf()

        Task { @MainActor [weak self] in
            if closingSomething { try? await Task.sleep(for: .milliseconds(350)) }
            guard self != nil else { return }
            present()
        }
    }

    func showBookDetail(_ book: Book) {
        handOffToNextSheet { [weak self] in self?.detailBook = book }
    }

    func showAuthorPage(_ url: URL) {
        handOffToNextSheet { [weak self] in
            Task { await self?.openAuthorPage(url) }
        }
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
        if let cached = ShelfCache.read(shelf) {
            shelfEntries = cached.entries
            cacheNote = "cached \(ShelfCache.age(cached.fetched))"
        } else {
            shelfEntries = []
            cacheNote = nil
        }

        isLoadingShelf = true
        loadProgress = shelfEntries.isEmpty ? "Loading…" : nil
        defer {
            isLoadingShelf = false
            loadProgress = nil
        }

        do {
            var fetched = try await ShelfLibrary.load(shelf) { [weak self] count, pages in
                guard let self else { return }
                self.loadProgress = pages > 1 ? "\(count) of ~\(pages * ShelfLibrary.perPage) so far…" : nil
            }
            if shelf.name == "currently-reading" { await backfillProgress(into: &fetched) }

            // The pane may have changed while we were paging.
            guard !Task.isCancelled, currentShelf?.name == shelf.name else { return }

            shelfEntries = fetched
            cacheNote = "updated just now"
            ShelfCache.write(fetched, for: shelf)
            setCount(fetched.count, for: shelf)

            if fetched.isEmpty {
                status = Status(text: "Nothing on \(shelf.label) yet.", isError: false)
            }
        } catch is CancellationError {
            // Superseded by another shelf — say nothing.
        } catch {
            guard !Task.isCancelled, currentShelf?.name == shelf.name else { return }
            status = Status(text: error.localizedDescription, isError: true)
            if !WebSession.shared.isSignedIn { webSheet = .signIn }
        }
    }

    func remove(_ entry: ShelfEntry) async {
        guard let shelf = currentShelf else { return }

        busyBookID = entry.bookID
        status = nil
        defer { busyBookID = nil }

        do {
            try await ShelfService.remove(bookID: entry.bookID, from: shelf)
            shelfEntries.removeAll { $0.id == entry.id }
            ShelfCache.write(shelfEntries, for: shelf)
            setCount(shelfEntries.count, for: shelf)
            status = Status(text: "Removed “\(entry.title)” from \(shelf.label).", isError: false)
        } catch {
            status = Status(text: "Couldn’t remove “\(entry.title)”: \(error.localizedDescription)",
                            isError: true)
        }
    }

    /// The three built-in shelves are exclusive, so adding to one moves it.
    /// Custom shelves stack instead, and the book stays where it was.
    func move(_ entry: ShelfEntry, to shelf: Shelf) async {
        busyBookID = entry.bookID
        status = nil
        defer { busyBookID = nil }

        do {
            try await ShelfService.add(bookID: entry.bookID, to: shelf)
            bumpCountIfNew(bookID: entry.bookID, shelf: shelf)
            if let current = currentShelf, current.isExclusive, shelf.isExclusive,
               current.name != shelf.name {
                shelfEntries.removeAll { $0.id == entry.id }
                ShelfCache.write(shelfEntries, for: current)
                setCount(shelfEntries.count, for: current)
            }
            let verb = shelf.isExclusive ? "→" : "also on"
            status = Status(text: "“\(entry.title)” \(verb) \(shelf.label)", isError: false)
        } catch {
            status = Status(text: "Couldn’t move “\(entry.title)”: \(error.localizedDescription)",
                            isError: true)
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

            if let index = shelfEntries.firstIndex(where: { $0.id == entry.id }) {
                shelfEntries[index].progress = resolvedPercent
            }
            if let index = currentlyReading.firstIndex(where: { $0.id == entry.id }) {
                currentlyReading[index].progress = resolvedPercent
                ShelfCache.write(currentlyReading, for: .currentlyReading)
            }
            let amount = resolvedPercent.map { "\($0)%" } ?? page.map { "page \($0)" } ?? "progress"
            status = Status(text: "Updated “\(entry.title)” to \(amount).", isError: false)
        } catch {
            status = Status(text: "Couldn’t update progress: \(error.localizedDescription)",
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

            let stars = rating.map { " at \($0)★" } ?? ""
            status = Status(text: "Marked “\(title)” read\(stars).", isError: false)
        } catch {
            status = Status(text: "Couldn’t finish “\(title)”: \(error.localizedDescription)",
                            isError: true)
        }
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
            status = Status(text: "Rated “\(entry.title)” \(stars)★.", isError: false)
        } catch {
            status = Status(text: "Couldn’t rate “\(entry.title)”: \(error.localizedDescription)",
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
            try await ShelfService.add(bookID: bookID, to: shelf)
            loggedIn = true
            bumpCountIfNew(bookID: bookID, shelf: shelf)
            status = Status(text: "“\(book.title)” → \(shelf.label)", isError: false)
        } catch {
            if !WebSession.shared.isSignedIn {
                status = Status(text: "Sign in first — click Log In below.", isError: true)
                webSheet = .signIn
            } else {
                status = Status(text: "Couldn’t shelve “\(book.title)”: \(error.localizedDescription)",
                                isError: true)
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
            let stars = rating.map { " at \($0)★" } ?? ""
            status = Status(text: "Marked “\(book.title)” read\(stars).", isError: false)
        } catch {
            status = Status(text: "Couldn’t finish “\(book.title)”: \(error.localizedDescription)",
                            isError: true)
        }
    }

    func openOnGoodreads(_ book: Book) async {
        do {
            let bookID = try await GoodreadsLookup.bookID(for: book)
            openOnGoodreads(bookID: bookID)
        } catch {
            status = Status(text: "Couldn’t find “\(book.title)” on Goodreads.", isError: true)
        }
    }

    // MARK: - Export

    func exportCurrentShelf() {
        guard let shelf = currentShelf, !shelfEntries.isEmpty else {
            status = Status(text: "Nothing to export.", isError: true)
            return
        }

        let text = CSVExport.csv(for: shelfEntries, shelf: shelf)
        report(CSVExport.save(text, suggestedName: "goodreads-\(shelf.name).csv"),
              successText: { "Exported \(self.shelfEntries.count) books to \($0)." })
    }

    /// Fetches every shelf and writes one combined file. This is the backup.
    func exportEverything() async {
        isExporting = true
        defer {
            isExporting = false
            exportProgress = nil
        }

        var rows: [(Shelf, [ShelfEntry])] = []
        for shelf in shelves {
            exportProgress = "Reading \(shelf.label)…"
            if let entries = try? await ShelfLibrary.load(shelf) {
                ShelfCache.write(entries, for: shelf)
                rows.append((shelf, entries))
            }
        }
        exportProgress = "Writing file…"

        // Each shelf contributes data rows only — reusing `CSVExport.csv`
        // (header + rows) per shelf and stripping their headers by splitting
        // on "\n" broke on any quoted field that itself contained a newline,
        // and silently left a blank line for an empty shelf.
        var lines = [CSVExport.header]
        var total = 0
        for (shelf, entries) in rows {
            total += entries.count
            lines.append(contentsOf: CSVExport.dataLines(for: entries, shelf: shelf))
        }
        let text = lines.joined(separator: "\n") + "\n"

        report(CSVExport.save(text, suggestedName: "goodreads-library.csv"),
              successText: { "Exported \(total) books to \($0)." })
    }

    private func report(_ result: CSVExport.SaveResult, successText: (String) -> String) {
        switch result {
        case .saved(let name):
            status = Status(text: successText(name), isError: false)
        case .cancelled:
            break
        case .failed(let message):
            status = Status(text: "Couldn’t save the export: \(message)", isError: true)
        }
    }

    func openOnGoodreads(bookID: String) {
        guard let url = URL(string: "https://www.goodreads.com/book/show/\(bookID)") else { return }
        NSWorkspace.shared.open(url)
    }
}
