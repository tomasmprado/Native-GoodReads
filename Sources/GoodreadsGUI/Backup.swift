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

    static func make() async -> BackupFile {
        BackupFile(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                   files: await DataCache.shared.keptFiles())
    }

    /// Asks where to save, then writes the backup. Returns a status line.
    static func export() async -> LibraryModel.Status? {
        let backup = await make()
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

/// A copy of the backup made on its own, once a week, into a folder you
/// choose (iCloud Drive by default), keeping the last eight.
@MainActor
enum AutoBackup {
    private static let enabledKey = "autoBackup"
    private static let folderKey = "autoBackupFolder"
    private static let lastKey = "autoBackupLast"
    static let interval: TimeInterval = 7 * 24 * 3600
    static let kept = 8

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue { Task { await runIfDue() } }
        }
    }

    static var folder: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: folderKey) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return defaultFolder
        }
        set { UserDefaults.standard.set(newValue.path, forKey: folderKey) }
    }

    static var lastBackup: Date? { UserDefaults.standard.object(forKey: lastKey) as? Date }

    /// iCloud Drive when it's on, otherwise Documents.
    static var defaultFolder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let base = FileManager.default.fileExists(atPath: iCloud.path)
            ? iCloud : home.appendingPathComponent("Documents", isDirectory: true)
        return base.appendingPathComponent("Goodreads Backups", isDirectory: true)
    }

    /// A readable place name, e.g. "iCloud Drive › Goodreads Backups".
    static var folderDescription: String {
        let path = folder.path
        let iCloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path
        if path.hasPrefix(iCloud) {
            let rest = path.dropFirst(iCloud.count).split(separator: "/").joined(separator: " › ")
            return rest.isEmpty ? "iCloud Drive" : "iCloud Drive › \(rest)"
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    static func runIfDue(now: Date = Date()) async {
        guard isEnabled else { return }
        if let last = lastBackup, now.timeIntervalSince(last) < interval { return }
        _ = await backUpNow()
    }

    /// Writes one backup and trims old ones. Returns an error message, or nil.
    @discardableResult
    static func backUpNow() async -> String? {
        let backup = await Backup.make()
        let folder = self.folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = Date().formatted(.iso8601.year().month().day())
            let file = folder.appendingPathComponent("Goodreads backup \(stamp).\(BackupFile.fileExtension)")
            try backup.encoded().write(to: file, options: .atomic)
            UserDefaults.standard.set(Date(), forKey: lastKey)
            trim(folder)
            return nil
        } catch {
            Diagnostics.shared.log("backup", "automatic backup failed: \(error.localizedDescription)", ok: false)
            return error.localizedDescription
        }
    }

    /// Keeps the newest `kept` automatic backups (they sort by date in their names).
    private static func trim(_ folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let backups = files.filter { $0.hasPrefix("Goodreads backup ") && $0.hasSuffix(".\(BackupFile.fileExtension)") }
            .sorted(by: >)
        for old in backups.dropFirst(kept) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
        }
    }

    /// Checks at launch and then twice a day while the app runs.
    static func start() {
        Task {
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                await runIfDue()
                try? await Task.sleep(for: .seconds(12 * 3600))
            }
        }
    }
}
