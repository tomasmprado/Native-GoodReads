import Foundation
import SwiftUI

@MainActor
final class LibraryModel: ObservableObject {

    // Search
    @Published var query = ""
    @Published var results: [Book] = []
    @Published var isSearching = false

    // Shelves
    @Published var selection: Pane = .search
    @Published var shelfEntries: [ShelfEntry] = []
    @Published var isLoadingShelf = false

    // Chrome
    @Published var busyBookID: String?
    @Published var status: Status?
    @Published var loggedIn = false
    @Published var showSignIn = false
    @Published var showBrowser = false
    @Published var progressTarget: ShelfEntry?

    enum Pane: Hashable {
        case search
        case shelf(Shelf)
    }

    struct Status: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    private var searchTask: Task<Void, Never>?
    private let debounce = Duration.milliseconds(250)

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

    private func performSearch(_ term: String) async {
        do {
            let found = try await SearchClient.search(term)

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

    func startSignIn() { showSignIn = true }

    func signInSheetClosed() async {
        loggedIn = await WebSession.shared.refreshSignInState()
        status = Status(text: loggedIn ? "Signed in." : "Still signed out.", isError: !loggedIn)
        if loggedIn, case .shelf = selection { await loadShelf() }
    }

    func checkSession() async {
        loggedIn = await WebSession.shared.refreshSignInState()
    }

    // MARK: - Shelves

    var currentShelf: Shelf? {
        if case .shelf(let shelf) = selection { return shelf }
        return nil
    }

    func paneChanged() async {
        status = nil
        if currentShelf != nil { await loadShelf() }
    }

    func loadShelf() async {
        guard let shelf = currentShelf else { return }

        isLoadingShelf = true
        defer { isLoadingShelf = false }

        do {
            shelfEntries = try await ShelfLibrary.load(shelf)
            if shelfEntries.isEmpty {
                status = Status(text: "Nothing on \(shelf.label) yet.", isError: false)
            }
        } catch {
            shelfEntries = []
            status = Status(text: error.localizedDescription, isError: true)
            if !WebSession.shared.isSignedIn { showSignIn = true }
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
            status = Status(text: "Removed “\(entry.title)” from \(shelf.label).", isError: false)
        } catch {
            status = Status(text: "Couldn’t remove “\(entry.title)”: \(error.localizedDescription)",
                            isError: true)
        }
    }

    /// Goodreads' three main shelves are exclusive, so adding to one moves it.
    func move(_ entry: ShelfEntry, to shelf: Shelf) async {
        busyBookID = entry.bookID
        status = nil
        defer { busyBookID = nil }

        do {
            try await ShelfService.add(bookID: entry.bookID, to: shelf)
            if currentShelf != nil, currentShelf != shelf {
                shelfEntries.removeAll { $0.id == entry.id }
            }
            status = Status(text: "“\(entry.title)” → \(shelf.label)", isError: false)
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
            try await ShelfService.updateProgress(
                bookID: entry.bookID, percent: percent, page: page, note: note
            )
            let amount = percent.map { "\($0)%" } ?? page.map { "page \($0)" } ?? "progress"
            status = Status(text: "Updated “\(entry.title)” to \(amount).", isError: false)
        } catch {
            status = Status(text: "Couldn’t update progress: \(error.localizedDescription)",
                            isError: true)
        }
    }

    // MARK: - Search results

    func shelve(_ book: Book, to shelf: Shelf) async {
        busyBookID = book.id
        status = nil
        defer { busyBookID = nil }

        do {
            try await ShelfService.add(bookID: book.id, to: shelf)
            loggedIn = true
            status = Status(text: "“\(book.title)” → \(shelf.label)", isError: false)
        } catch {
            if !WebSession.shared.isSignedIn {
                status = Status(text: "Sign in first — click Log In below.", isError: true)
                showSignIn = true
            } else {
                status = Status(text: "Couldn’t shelve “\(book.title)”: \(error.localizedDescription)",
                                isError: true)
            }
        }
    }

    func openOnGoodreads(bookID: String) {
        guard let url = URL(string: "https://www.goodreads.com/book/show/\(bookID)") else { return }
        NSWorkspace.shared.open(url)
    }
}
