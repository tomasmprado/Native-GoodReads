import AppKit
import SwiftUI
import UserNotifications

/// Plugging in a Kobo brings up a notification; choosing it opens a sync
/// that sends the files you attached to books you're reading or want to
/// read, removes the ones the app sent that you've since finished, brings
/// progress and finished books over to Goodreads, and imports highlights.
/// Nothing changes on the Kobo until you press Sync.
enum KoboSync {
    nonisolated static let category = "kobo-connected"
    nonisolated static let syncAction = "kobo-sync"
    private static let uploadsKey = "koboUploads"
    static let folderName = "Goodreads"

    static var categoryObject: UNNotificationCategory {
        let sync = UNNotificationAction(identifier: syncAction, title: String(localized: "Sync with Goodreads"),
                                        options: [.foreground])
        return UNNotificationCategory(identifier: category, actions: [sync], intentIdentifiers: [], options: [])
    }

    /// The Kobo's root folder, when one is plugged in.
    static var volume: URL? {
        ReadingApps.koboDatabase?.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Files this app put on the Kobo: book id → path on the device, relative to its root.
    static var uploads: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: uploadsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: uploadsKey) }
    }

    @MainActor
    static func announce() async {
        guard Preferences.shared.notifyKoboConnected else { return }
        _ = await FriendNotifier.requestPermission()
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Kobo connected")
        content.body = String(localized: "Sync it with Goodreads: send new books, remove finished ones, bring over progress and notes.")
        content.categoryIdentifier = category
        content.sound = .default
        try? await UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: "kobo-connected", content: content, trigger: nil))
    }

    /// A file name the Kobo shows nicely: "Title - Author.epub".
    static func deviceName(title: String, author: String, ext: String) -> String {
        let raw = author.isEmpty ? title : "\(title) - \(author)"
        let safe = raw.replacingOccurrences(of: "[/:\\\\?%*|\"<>]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return "\(String(safe.prefix(120))).\(ext)"
    }

    // MARK: Plan

    struct Plan: Equatable {
        struct Send: Identifiable, Equatable { let entry: ShelfEntry; let file: URL; var id: String { entry.bookID } }
        struct Remove: Identifiable, Equatable { let bookID: String; let title: String; let path: String; var id: String { bookID } }
        var send: [Send] = []
        var remove: [Remove] = []
        var highlights: [(book: ImportedBook, entry: ShelfEntry)] = []

        static func == (a: Plan, b: Plan) -> Bool {
            a.send == b.send && a.remove == b.remove && a.highlights.map(\.book.id) == b.highlights.map(\.book.id)
        }
    }

    /// What a sync would do, given your shelves, your attached files and what's on the Kobo.
    static func plan(volume: URL, files: [String: URL], shelves: [String: [ShelfEntry]], uploads: [String: String],
                     onDevice: Set<String>) -> Plan {
        var plan = Plan()
        let wanted = (shelves[Shelf.currentlyReading.name] ?? []) + (shelves[Shelf.wantToRead.name] ?? [])
        for entry in wanted {
            guard let file = files[BookFiles.safeName(entry.bookID)] else { continue }
            let name = deviceName(title: entry.title, author: entry.author, ext: file.pathExtension.lowercased())
            if uploads[entry.bookID] == nil && !onDevice.contains(name) {
                plan.send.append(.init(entry: entry, file: file))
            }
        }
        let read = Set((shelves[Shelf.read.name] ?? []).map(\.bookID))
        let titles = Dictionary((shelves.values.flatMap { $0 }).map { ($0.bookID, $0.title) }, uniquingKeysWith: { a, _ in a })
        for (bookID, path) in uploads where read.contains(bookID) {
            plan.remove.append(.init(bookID: bookID, title: titles[bookID] ?? path, path: path))
        }
        return plan
    }
}

// MARK: - Sheet

struct KoboSyncSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: LibraryModel
    @ObservedObject private var sync = ReadingAppsSync.shared

    @State private var plan = KoboSync.Plan()
    @State private var sendOn: Set<String> = []
    @State private var removeOn: Set<String> = []
    @State private var doProgress = true
    @State private var doNotes = true
    @State private var working = false
    @State private var report: String?
    @State private var noKobo = false

    private var koboSuggestions: [ReaderSuggestion] {
        sync.suggestions.filter { $0.book.source == .kobo && $0.isProgress }
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassHeader {
                Text("Sync Kobo").appFont(size: 13, weight: .semibold)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).glassButton()
            }
            if noKobo {
                Spacer()
                Text("Connect your Kobo by USB, then open this again.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    Section("Send to Kobo") {
                        if plan.send.isEmpty {
                            Text("Nothing new to send. Add an EPUB or PDF to a book on Currently Reading or Want to Read, in its details.")
                                .appFont(size: 11).foregroundStyle(.secondary)
                        }
                        ForEach(plan.send) { item in
                            toggleRow(item.entry.title, detail: "\(item.file.pathExtension.uppercased()) · \(BookFiles.size(item.file))",
                                      on: binding(item.id, in: $sendOn))
                        }
                    }
                    Section("Remove from Kobo (finished)") {
                        if plan.remove.isEmpty {
                            Text("Nothing to remove. Only books this app sent are ever removed.")
                                .appFont(size: 11).foregroundStyle(.secondary)
                        }
                        ForEach(plan.remove) { item in
                            toggleRow(item.title, detail: item.path, on: binding(item.id, in: $removeOn))
                        }
                    }
                    Section("Bring over to Goodreads") {
                        Toggle(isOn: $doProgress) {
                            Text("Progress and finished books (\(koboSuggestions.count))").appFont(size: 12)
                        }
                        .toggleStyle(.checkbox)
                        Toggle(isOn: $doNotes) {
                            Text("Highlights and notes (\(plan.highlights.reduce(0) { $0 + $1.book.highlights.count + $1.book.notes.count }))")
                                .appFont(size: 12)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                if let report { Text(report).appFont(size: 11).foregroundStyle(.secondary).lineLimit(2) }
                Spacer()
                Button("Eject Kobo") { eject() }.disabled(noKobo || working)
                Button("Sync") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .glassProminentButton()
                    .disabled(noKobo || working)
            }
            .padding(12)
        }
        .frame(width: 560, height: 560)
        .fixedSheetWindow()
        .task { await prepare() }
    }

    private func binding(_ id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) },
                set: { if $0 { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } })
    }

    private func toggleRow(_ title: String, detail: String, on: Binding<Bool>) -> some View {
        Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).appFont(size: 12, weight: .medium).lineLimit(1)
                Text(detail).appFont(size: 10).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func prepare() async {
        guard let volume = KoboSync.volume else { noKobo = true; return }
        noKobo = false
        let folder = volume.appendingPathComponent(KoboSync.folderName, isDirectory: true)
        let onDevice = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        var shelves: [String: [ShelfEntry]] = [:]
        for shelf in Shelf.builtIn { shelves[shelf.name] = ShelfCache.read(shelf)?.entries ?? [] }
        var next = KoboSync.plan(volume: volume, files: BookFiles.all(), shelves: shelves,
                                 uploads: KoboSync.uploads, onDevice: onDevice)
        if let imported = try? await Task.detached(operation: { try ReadingApps.koboHighlights() }).value {
            let library = shelves.values.flatMap { $0 }
            let matches = Highlights.match(imported, to: library)
            next.highlights = imported.compactMap { book in matches[book.id].map { (book: book, entry: $0) } }
        }
        plan = next
        sendOn = Set(next.send.map(\.id))
        removeOn = Set(next.remove.map(\.id))
        await sync.scan()
    }

    private func run() async {
        guard let volume = KoboSync.volume else { noKobo = true; return }
        working = true
        defer { working = false }
        let fm = FileManager.default
        let folder = volume.appendingPathComponent(KoboSync.folderName, isDirectory: true)
        var uploads = KoboSync.uploads
        var sent = 0, removed = 0, notes = 0, progress = 0

        for item in plan.send where sendOn.contains(item.id) {
            let name = KoboSync.deviceName(title: item.entry.title, author: item.entry.author,
                                           ext: item.file.pathExtension.lowercased())
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent(name)
                if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: item.file, to: target) }
                uploads[item.entry.bookID] = "\(KoboSync.folderName)/\(name)"
                sent += 1
            } catch {
                report = error.localizedDescription
            }
        }
        for item in plan.remove where removeOn.contains(item.id) {
            let target = volume.appendingPathComponent(item.path)
            // Only ever inside the folder this app writes to.
            guard target.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else { continue }
            try? fm.removeItem(at: target)
            uploads[item.bookID] = nil
            removed += 1
        }
        KoboSync.uploads = uploads

        if doProgress {
            for suggestion in koboSuggestions {
                await sync.apply(suggestion)
                progress += 1
            }
        }
        if doNotes {
            for (book, entry) in plan.highlights {
                let (note, added) = Highlights.merge(book, into: await BookNotes.note(for: entry.bookID))
                if added > 0 { await BookNotes.save(note, for: entry.bookID); notes += added }
            }
        }
        report = String(localized: "Sent \(sent), removed \(removed), \(progress) updates on Goodreads, \(notes) new highlights and notes.")
        model.status = .init(text: report ?? "", isError: false)
        await prepare()
    }

    private func eject() {
        guard let volume = KoboSync.volume else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            report = String(localized: "You can unplug your Kobo.")
            noKobo = true
        } catch {
            report = error.localizedDescription
        }
    }
}
