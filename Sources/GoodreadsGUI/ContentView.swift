import SwiftUI

struct ContentView: View {
    @StateObject private var model = LibraryModel()
    @ObservedObject private var session = WebSession.shared

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                switch model.selection {
                case .search:        SearchPane(model: model)
                case .shelf:         ShelfPane(model: model)
                }
                Divider()
                StatusBar(model: model, session: session)
            }
            .frame(minWidth: 460, minHeight: 420)
        }
        .task { await model.checkSession() }
        .onChange(of: model.selection) { _ in Task { await model.paneChanged() } }
        .sheet(isPresented: $model.showSignIn, onDismiss: {
            Task { await model.signInSheetClosed() }
        }) {
            SignInSheet()
        }
        .sheet(isPresented: $model.showBrowser) {
            BrowserSheet(isPresented: $model.showBrowser)
        }
        .sheet(item: $model.progressTarget) { entry in
            ProgressSheet(entry: entry) { percent, page, note in
                Task { await model.updateProgress(entry, percent: percent, page: page, note: note) }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $model.selection) {
            Label("Search", systemImage: "magnifyingglass")
                .tag(LibraryModel.Pane.search)

            Section("My Books") {
                ForEach(Shelf.allCases) { shelf in
                    Label(shelf.label, systemImage: shelf.symbol)
                        .tag(LibraryModel.Pane.shelf(shelf))
                }
            }
        }
        .frame(minWidth: 170)
    }
}

// MARK: - Search

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

            Divider()

            if model.results.isEmpty {
                EmptyPane(symbol: "books.vertical", text: "Search for a book, then add it to a shelf.")
            } else {
                List(model.results) { book in
                    BookRow(
                        title: book.title,
                        author: book.author,
                        cover: book.coverURL,
                        detail: book.rating.map { "★ \($0)" },
                        isBusy: model.busyBookID == book.id
                    ) {
                        ForEach(Shelf.allCases) { shelf in
                            Button {
                                Task { await model.shelve(book, to: shelf) }
                            } label: {
                                Label(shelf.label, systemImage: shelf.symbol)
                            }
                        }
                        Divider()
                        Button("Open on Goodreads") { model.openOnGoodreads(bookID: book.id) }
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
            HStack {
                Text(model.currentShelf?.label ?? "")
                    .font(.system(size: 13, weight: .semibold))
                if !model.shelfEntries.isEmpty {
                    Text("\(model.shelfEntries.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isLoadingShelf {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await model.loadShelf() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Reload this shelf")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if model.shelfEntries.isEmpty {
                EmptyPane(
                    symbol: model.isLoadingShelf ? "hourglass" : "tray",
                    text: model.isLoadingShelf ? "Loading your shelf…" : "Nothing here yet."
                )
            } else {
                List(model.shelfEntries) { entry in
                    BookRow(
                        title: entry.title,
                        author: entry.author,
                        cover: entry.coverURL,
                        detail: entry.progress.map { "\($0)%" },
                        isBusy: model.busyBookID == entry.bookID
                    ) {
                        if model.currentShelf == .currentlyReading {
                            Button {
                                model.progressTarget = entry
                            } label: {
                                Label("Update Progress…", systemImage: "chart.bar")
                            }
                            Divider()
                        }

                        ForEach(Shelf.allCases.filter { $0 != model.currentShelf }) { shelf in
                            Button {
                                Task { await model.move(entry, to: shelf) }
                            } label: {
                                Label("Move to \(shelf.label)", systemImage: shelf.symbol)
                            }
                        }

                        Divider()
                        Button("Open on Goodreads") { model.openOnGoodreads(bookID: entry.bookID) }
                        Button("Remove from Shelf", role: .destructive) {
                            Task { await model.remove(entry) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
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
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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

            Button("Browser") { model.showBrowser = true }
                .controlSize(.small)
                .help("Watch what the app is doing in the page — for troubleshooting.")

            Button(model.loggedIn ? "Sign Out" : "Log In") {
                if model.loggedIn {
                    Task {
                        await session.signOut()
                        model.loggedIn = false
                        model.shelfEntries = []
                    }
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
