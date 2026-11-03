import AppKit
import SwiftUI

/// Brings what you read in Apple Books and on a Kobo over to Goodreads:
/// progress, finished books and — when you turn it on — books that aren't on
/// your shelves yet. Runs by itself every few hours and when a Kobo is
/// plugged in, if Settings allow; the Reading Apps sheet shows and does the
/// same by hand.
@MainActor
final class ReadingAppsSync: ObservableObject {
    static let shared = ReadingAppsSync()

    @Published private(set) var suggestions: [ReaderSuggestion] = []
    @Published private(set) var counts: [ReaderSource: Int] = [:]
    @Published private(set) var errors: [ReaderSource: String] = [:]
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?
    @Published var busy: Set<String> = []

    /// A folder chosen by hand when macOS wouldn't let the app read Apple Books.
    var appleBooksFolder: URL?

    private static let appliedKey = "readerSyncApplied"
    /// What automatic sync already did, so a book you moved back isn't moved again.
    private var applied: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.appliedKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.appliedKey) }
    }

    private init() { }

    // MARK: Looking

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false; lastScan = Date() }

        var books: [ReaderBook] = []
        var newErrors: [ReaderSource: String] = [:]
        var newCounts: [ReaderSource: Int] = [:]
        let folder = appleBooksFolder ?? Highlights.appleBooksFolder
        do {
            let apple = try await Task.detached { try ReadingApps.appleBooks(folder: folder) }.value
            books += apple
            newCounts[.appleBooks] = apple.count
        } catch {
            newErrors[.appleBooks] = Self.describe(error)
        }
        if ReadingApps.koboDatabase != nil {
            do {
                let kobo = try await Task.detached { try ReadingApps.kobo() }.value
                books += kobo
                newCounts[.kobo] = kobo.count
            } catch {
                newErrors[.kobo] = error.localizedDescription
            }
        }

        let shelves = Shelf.builtIn.map { ($0, ShelfCache.read($0)?.entries ?? []) }
        let library = shelves.flatMap(\.1)
        var shelfByBook: [String: String] = [:]
        for (shelf, entries) in shelves {
            for entry in entries { shelfByBook[entry.bookID] = shelf.name }
        }
        let matches = ReadingApps.match(books, to: library)
        suggestions = ReaderSuggestion.plan(books: books, matches: matches) { shelfByBook[$0.bookID] }
            .sorted { ($0.book.lastOpened ?? .distantPast) > ($1.book.lastOpened ?? .distantPast) }
        errors = newErrors
        counts = newCounts
    }

    private static func describe(_ error: Error) -> String {
        let code = (error as NSError).code
        if (error as NSError).domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileReadUnknownError, NSFileReadNoSuchFileError].contains(code) {
            return String(localized: "macOS didn’t let the app read Apple Books. Choose its folder to allow it, or turn on Full Disk Access for Goodreads.")
        }
        return error.localizedDescription
    }

    // MARK: Doing

    func apply(_ suggestion: ReaderSuggestion) async {
        let model = LibraryModel.shared
        busy.insert(suggestion.id)
        defer { busy.remove(suggestion.id) }

        switch suggestion.kind {
        case .progress(let percent):
            guard let entry = suggestion.entry else { return }
            await model.updateProgress(entry, percent: percent, page: nil, note: "")
        case .start(let percent):
            guard let entry = suggestion.entry else { return }
            await model.move(entry, to: .currentlyReading)
            if let percent { await model.updateProgress(entry, percent: percent, page: nil, note: "") }
        case .finished:
            guard let entry = suggestion.entry else { return }
            await model.finish(bookID: entry.bookID, title: entry.title, rating: nil,
                               dateRead: suggestion.book.finishedOn ?? Date(), note: "")
        case .add(let shelf):
            let book = Book(id: suggestion.book.isbn ?? suggestion.book.id, title: suggestion.book.title,
                            author: suggestion.book.author, coverURL: nil, rating: nil, isbn: suggestion.book.isbn)
            if shelf == .read {
                await model.finishBook(book, rating: nil, dateRead: suggestion.book.finishedOn ?? Date(), note: "")
            } else {
                await model.shelve(book, to: shelf)
            }
        }
        if model.status?.isError != true {
            suggestions.removeAll { $0.id == suggestion.id }
            var done = applied
            done[suggestion.id] = Self.signature(suggestion)
            applied = done
        }
    }

    private static func signature(_ suggestion: ReaderSuggestion) -> String {
        switch suggestion.kind {
        case .progress(let percent): return "progress:\(percent)"
        case .start: return "start"
        case .finished: return "finished"
        case .add(let shelf): return "add:\(shelf.name)"
        }
    }

    // MARK: Automatically

    /// Does what Settings allow, skipping anything already done once.
    func runAutomatically() async {
        let prefs = Preferences.shared
        guard prefs.syncReadingApps || prefs.importReadingAppsLibrary, LibraryModel.shared.loggedIn else { return }
        await scan()
        let done = applied
        for suggestion in suggestions {
            guard done[suggestion.id] != Self.signature(suggestion) else { continue }
            let allowed = suggestion.isProgress ? prefs.syncReadingApps : prefs.importReadingAppsLibrary
            guard allowed, !Task.isCancelled else { continue }
            await apply(suggestion)
        }
    }

    /// A first check a minute after launch, then every six hours, and
    /// whenever a Kobo is plugged in.
    func start() {
        Task {
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                await runAutomatically()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification,
                                                          object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard ReadingApps.koboDatabase != nil else { return }
                await KoboSync.announce()
                await ReadingAppsSync.shared.runAutomatically()
            }
        }
    }
}

// MARK: - Sheet

struct ReadingAppsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sync = ReadingAppsSync.shared
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        VStack(spacing: 0) {
            GlassHeader {
                Text("Reading Apps").appFont(size: 13, weight: .semibold)
                Spacer()
                if sync.isScanning { ProgressView().controlSize(.small) }
                Button("Check Again") { Task { await sync.scan() } }
                    .glassButton()
                    .disabled(sync.isScanning)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .glassButton()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 16) {
                    source(.appleBooks)
                    source(.kobo)
                }
                Toggle("Sync progress and finished books automatically", isOn: $prefs.syncReadingApps)
                    .checkboxStyle()
                Toggle("Add books that aren’t on my shelves automatically", isOn: $prefs.importReadingAppsLibrary)
                    .checkboxStyle()
            }
            .padding(14)

            Divider()

            if sync.suggestions.isEmpty {
                Spacer()
                Text(sync.isScanning ? String(localized: "Looking at your reading apps…")
                                     : String(localized: "Goodreads is up to date with your reading apps."))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    group(String(localized: "Further along"), { if case .progress = $0.kind { return true }; return false })
                    group(String(localized: "Started"), { if case .start = $0.kind { return true }; return false })
                    group(String(localized: "Finished"), { $0.kind == .finished })
                    group(String(localized: "Not on your shelves"), { if case .add = $0.kind { return true }; return false })
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("Apple Books is read from this Mac; a Kobo when it’s plugged in by USB.")
                    .appFont(size: 11).foregroundStyle(.secondary)
                Spacer()
                Button("Do All") {
                    Task { for suggestion in sync.suggestions { await sync.apply(suggestion) } }
                }
                .glassProminentButton()
                .disabled(sync.suggestions.isEmpty || !sync.busy.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 600, height: 600)
        .fixedSheetWindow()
        .task { if sync.lastScan == nil || sync.suggestions.isEmpty { await sync.scan() } }
    }

    @ViewBuilder
    private func source(_ source: ReaderSource) -> some View {
        HStack(spacing: 6) {
            Image(systemName: source.symbol).foregroundStyle(.secondary)
            if let error = sync.errors[source] {
                Text(error).appFont(size: 11).foregroundStyle(.orange).lineLimit(2)
                if source == .appleBooks {
                    Button("Choose Folder…") { chooseAppleBooksFolder() }.controlSize(.small)
                }
            } else if let count = sync.counts[source] {
                Text("\(source.title): \(count) books").appFont(size: 11)
            } else {
                Text(source == .kobo ? String(localized: "Kobo: not connected") : source.title)
                    .appFont(size: 11).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ include: @escaping (ReaderSuggestion) -> Bool) -> some View {
        let items = sync.suggestions.filter(include)
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { row($0) }
            }
        }
    }

    private func row(_ suggestion: ReaderSuggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: suggestion.book.source.symbol)
                .foregroundStyle(.secondary)
                .help(suggestion.book.source.title)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.entry?.title ?? suggestion.book.title).appFont(size: 12, weight: .medium).lineLimit(1)
                Text(detail(suggestion)).appFont(size: 10).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if sync.busy.contains(suggestion.id) {
                ProgressView().controlSize(.small)
            } else {
                Button(action: { Task { await sync.apply(suggestion) } }) {
                    Text(actionTitle(suggestion))
                }
                .controlSize(.small)
            }
        }
    }

    private func detail(_ suggestion: ReaderSuggestion) -> String {
        var bits = [suggestion.book.author].filter { !$0.isEmpty }
        switch suggestion.kind {
        case .progress(let percent):
            bits.append(String(localized: "\(suggestion.entry?.progress ?? 0)% on Goodreads → \(percent)%"))
        case .start(let percent):
            bits.append(percent.map { String(localized: "\($0)% in \(suggestion.book.source.title)") }
                        ?? String(localized: "Started in \(suggestion.book.source.title)"))
        case .finished:
            if let date = suggestion.book.finishedOn {
                bits.append(String(localized: "Finished \(date.formatted(date: .abbreviated, time: .omitted))"))
            }
        case .add:
            if let percent = suggestion.book.percent, percent > 0, !suggestion.book.finished { bits.append("\(percent)%") }
        }
        return bits.joined(separator: " · ")
    }

    private func actionTitle(_ suggestion: ReaderSuggestion) -> String {
        switch suggestion.kind {
        case .progress(let percent): return String(localized: "Update to \(percent)%")
        case .start: return String(localized: "Move to Currently Reading")
        case .finished: return String(localized: "Mark as Read")
        case .add(let shelf): return String(localized: "Add to \(shelf.title)")
        }
    }

    private func chooseAppleBooksFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = Highlights.appleBooksFolder
        panel.message = String(localized: "Apple Books’ folder is hidden: press ⌘⇧G, paste ~/Library/Containers/com.apple.iBooksX/Data/Documents, then click Open.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sync.appleBooksFolder = url
        Task { await sync.scan() }
    }
}

private extension View {
    func checkboxStyle() -> some View { toggleStyle(.checkbox).appFont(size: 12) }
}
