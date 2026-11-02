import AppKit
import UniformTypeIdentifiers

/// A backup of what lives only on this Mac — notes and quotes, progress
/// history, abandoned books — as one file you can keep elsewhere and
/// restore from. Shelves and ratings live on Goodreads and aren't included.
struct BackupFile: Codable {
    static let currentFormat = 1

    var format = currentFormat
    var created = Date()
    var appVersion: String?
    /// Namespace → file name → that file's bytes, exactly as the cache keeps them.
    var files: [String: [String: Data]]

    static let fileExtension = "goodreadsbackup"

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> BackupFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(BackupFile.self, from: data)
        guard file.format <= currentFormat else { throw BackupError.newerFormat }
        return file
    }

    /// How many notes, books with progress and abandoned books it holds, for the confirmation.
    func summary() -> (notes: Int, progress: Int, abandoned: Int) {
        func count<T: Decodable>(_ type: T.Type, _ namespace: String, _ size: (T) -> Int) -> Int {
            (files[namespace] ?? [:]).values.reduce(0) { total, data in
                total + (DataCache.decodeStored(type, from: data).map(size) ?? 0)
            }
        }
        return (count([String: BookNote].self, "notes") { $0.count },
                count([String: [ProgressPoint]].self, "progress-history") { $0.count },
                count([String: AbandonedBook].self, "abandoned") { $0.count })
    }
}

enum BackupError: LocalizedError {
    case newerFormat

    var errorDescription: String? {
        String(localized: "This backup was made by a newer version of the app.")
    }
}

@MainActor
enum Backup {
    static var contentType: UTType {
        UTType(filenameExtension: BackupFile.fileExtension, conformingTo: .json) ?? .json
    }

    /// Asks where to save, then writes the backup. Returns a status line.
    static func export() async -> LibraryModel.Status? {
        let files = await DataCache.shared.keptFiles()
        let backup = BackupFile(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            files: files
        )
        let panel = NSSavePanel()
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Goodreads backup \(day).\(BackupFile.fileExtension)"
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try backup.encoded().write(to: url, options: .atomic)
            let summary = backup.summary()
            return .init(text: String(localized: "Backed up \(summary.notes) notes and the progress of \(summary.progress) books to \(url.lastPathComponent)."),
                         isError: false)
        } catch {
            return .init(text: String(localized: "Couldn’t save the backup: \(error.localizedDescription)"), isError: true)
        }
    }

    /// Asks for a backup file, confirms, then replaces what's on this Mac with it.
    static func restore() async -> LibraryModel.Status? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [contentType, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let backup: BackupFile
        do {
            backup = try BackupFile.decode(Data(contentsOf: url))
        } catch {
            return .init(text: String(localized: "Couldn’t read the backup: \(error.localizedDescription)"), isError: true)
        }

        let summary = backup.summary()
        let alert = NSAlert()
        alert.messageText = String(localized: "Restore this backup?")
        alert.informativeText = String(localized: "From \(backup.created.formatted(date: .long, time: .shortened)): \(summary.notes) notes, the progress of \(summary.progress) books and \(summary.abandoned) abandoned books. They replace what’s on this Mac now.")
        alert.addButton(withTitle: String(localized: "Restore"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        await DataCache.shared.restoreKept(backup.files)
        return .init(text: String(localized: "Restored \(summary.notes) notes and the progress of \(summary.progress) books."),
                     isError: false)
    }
}
