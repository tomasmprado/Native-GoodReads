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

    /// The attached file for a book, if there is one.
    static func file(for bookID: String) -> URL? {
        let safe = safeName(bookID)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.deletingPathExtension().lastPathComponent == safe && extensions.contains($0.pathExtension.lowercased()) }
    }

    /// Every book with a file, by book id.
    static func all() -> [String: URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var result: [String: URL] = [:]
        for file in files where extensions.contains(file.pathExtension.lowercased()) {
            result[file.deletingPathExtension().lastPathComponent] = file
        }
        return result
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

    static func remove(for bookID: String) {
        if let file = file(for: bookID) { try? FileManager.default.removeItem(at: file) }
    }

    /// Opens the file in Apple Books, which adds it to its library.
    static func openInAppleBooks(_ file: URL) {
        let books = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iBooksX")
            ?? URL(fileURLWithPath: "/System/Applications/Books.app")
        NSWorkspace.shared.open([file], withApplicationAt: books, configuration: NSWorkspace.OpenConfiguration())
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
                    Text("\(file.pathExtension.uppercased()) · \(BookFiles.size(file))")
                        .appFont(size: 11).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        BookFiles.openInAppleBooks(file)
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
