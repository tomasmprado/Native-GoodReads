import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Your own copy of a book — an EPUB or PDF you attach — kept with the app
/// and opened in Apple Books (or sent to a Kobo). One file per book.
enum BookFiles {

    static let allowedTypes: [UTType] = [UTType(filenameExtension: "epub") ?? .data, .pdf]
    static let extensions = ["epub", "pdf", "kepub"]

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoodreadsGUI/books", isDirectory: true)
    }

    /// The file for a book: a copy you added, else one linked from Calibre.
    static func file(for bookID: String) -> URL? {
        let safe = safeName(bookID)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        if let own = files.first(where: { $0.deletingPathExtension().lastPathComponent == safe && extensions.contains($0.pathExtension.lowercased()) }) {
            return own
        }
        return linked[bookID].map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Every book with a file, by its file-safe book id.
    static func all() -> [String: URL] {
        var result: [String: URL] = [:]
        for (bookID, path) in linked where FileManager.default.fileExists(atPath: path) {
            result[safeName(bookID)] = URL(fileURLWithPath: path)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where extensions.contains(file.pathExtension.lowercased()) {
            result[file.deletingPathExtension().lastPathComponent] = file
        }
        return result
    }

    // MARK: Linked files (Calibre)

    private static let linkedKey = "linkedBookFiles"

    /// Files that stay where they are — in your Calibre library — by book id.
    static var linked: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: linkedKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: linkedKey) }
    }

    /// Whether the book's file is a link (to Calibre) rather than a copy.
    static func isLinked(_ bookID: String) -> Bool {
        guard let file = file(for: bookID) else { return false }
        return !file.path.hasPrefix(folder.path)
    }

    static func link(_ file: URL, to bookID: String) {
        var all = linked
        all[bookID] = file.path
        linked = all
    }

    /// Copies `source` in as this book's file, replacing any earlier one.
    @discardableResult
    static func attach(_ source: URL, to bookID: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let old = file(for: bookID) { try? fm.removeItem(at: old) }
        let ext = source.pathExtension.lowercased()
        guard extensions.contains(ext) else {
            throw AppError(verbatim: String(localized: "Only EPUB and PDF files can be added."))
        }
        let target = folder.appendingPathComponent("\(safeName(bookID)).\(ext)")
        try fm.copyItem(at: source, to: target)
        return target
    }

    /// Deletes a copy you added; a Calibre link is only unlinked, never deleted.
    static func remove(for bookID: String) {
        if isLinked(bookID) {
            var all = linked
            all[bookID] = nil
            linked = all
        } else if let file = file(for: bookID) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Apple Books

    private static let assetsKey = "appleBooksAssets"

    /// Which Apple Books book is your copy: book id → Apple Books asset id.
    static var appleBooksAssets: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: assetsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: assetsKey) }
    }

    /// Opens your copy in Apple Books where you left off. Opening the file
    /// itself would import it again — a fresh copy, back at page one — so
    /// the book already in Apple Books' library is opened instead
    /// (ibooks://assetid/…), and the file is only imported the first time.
    @MainActor
    static func openInAppleBooks(_ file: URL, bookID: String? = nil, title: String = "", author: String = "") {
        if let bookID, let asset = appleBooksAssets[bookID] ?? findInAppleBooks(title: title, author: author) {
            remember(asset, for: bookID)
            if let link = URL(string: "ibooks://assetid/\(asset)") { NSWorkspace.shared.open(link) }
            return
        }
        let books = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iBooksX")
            ?? URL(fileURLWithPath: "/System/Applications/Books.app")
        NSWorkspace.shared.open([file], withApplicationAt: books, configuration: NSWorkspace.OpenConfiguration())
        // Once Books has taken it in, remember which book it became.
        guard let bookID else { return }
        Task { @MainActor in
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(5))
                if let asset = findInAppleBooks(title: title, author: author) {
                    remember(asset, for: bookID)
                    return
                }
            }
        }
    }

    private static func remember(_ asset: String, for bookID: String) {
        var assets = appleBooksAssets
        assets[bookID] = asset
        appleBooksAssets = assets
    }

    /// The Apple Books book matching a title and author, if macOS lets the
    /// app read Apple Books' library.
    static func findInAppleBooks(title: String, author: String) -> String? {
        guard !title.isEmpty,
              let library = try? ReadingApps.appleBooks(folder: ReadingAppsSync.chosenAppleBooksFolder ?? Highlights.appleBooksFolder)
        else { return nil }
        let entry = ShelfEntry(id: "x", bookID: "x", reviewID: nil, title: title, author: author, coverURLString: nil)
        let matches = ReadingApps.match(library, to: [entry])
        // Earlier imports may have left several copies: the one read last has your place.
        return library.filter { matches[$0.id] != nil }
            .max { ($0.lastOpened ?? .distantPast, $0.percent ?? 0) < ($1.lastOpened ?? .distantPast, $1.percent ?? 0) }?
            .sourceID
    }

    /// Book ids can be "gr:123"; keep file names plain.
    static func safeName(_ bookID: String) -> String {
        bookID.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
    }

    static func size(_ file: URL) -> String {
        let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Book Details' "Your Copy": attach a file, open it in Apple Books.
struct BookFileSection: View {
    let bookID: String
    var title = ""
    var author = ""
    @State private var file: URL?
    @State private var message: String?
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your Copy").appFont(size: 12, weight: .semibold)
            if let file {
                HStack(spacing: 8) {
                    Image(systemName: file.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "book.closed")
                        .foregroundStyle(.secondary)
                    Text("\(file.pathExtension.uppercased()) · \(BookFiles.size(file))"
                         + (BookFiles.isLinked(bookID) ? " · " + String(localized: "from Calibre") : ""))
                        .appFont(size: 11).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        BookFiles.openInAppleBooks(file, bookID: bookID, title: title, author: author)
                    } label: {
                        Label("Open in Apple Books", systemImage: "book")
                    }
                    .glassProminentButton()
                    .controlSize(.small)
                    Menu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        Button("Replace…") { choose() }
                        Divider()
                        Button("Remove", role: .destructive) {
                            BookFiles.remove(for: bookID)
                            self.file = nil
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            } else {
                HStack(spacing: 8) {
                    Button("Add EPUB or PDF…") { choose() }
                        .controlSize(.small)
                    Text("or drop a file here, then open it in Apple Books or send it to your Kobo.")
                        .appFont(size: 11).foregroundStyle(.secondary)
                }
            }
            if let message {
                Text(message).appFont(size: 11).foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 2))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in attach(url) }
            }
            return true
        }
        .task(id: bookID) { file = BookFiles.file(for: bookID) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = BookFiles.allowedTypes
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attach(url)
    }

    private func attach(_ url: URL) {
        do {
            file = try BookFiles.attach(url, to: bookID)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}
