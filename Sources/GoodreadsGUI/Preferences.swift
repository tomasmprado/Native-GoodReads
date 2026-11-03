import Foundation
import SwiftUI

enum BookLanguage: String, CaseIterable, Identifiable, Codable {
    case any, english, portuguese, spanish, french, german, italian

    var id: String { rawValue }

    var label: String {
        switch self {
        case .any:        return String(localized: "Any language")
        case .english:    return String(localized: "English")
        case .portuguese: return String(localized: "Portuguese")
        case .spanish:    return String(localized: "Spanish")
        case .french:     return String(localized: "French")
        case .german:     return String(localized: "German")
        case .italian:    return String(localized: "Italian")
        }
    }

    /// Goodreads' JSON-LD reports `inLanguage` inconsistently — sometimes a
    /// two-letter code, sometimes three, sometimes the name.
    var codes: [String] {
        switch self {
        case .any:        return []
        case .english:    return ["en", "eng", "english"]
        case .portuguese: return ["pt", "por", "portuguese", "português"]
        case .spanish:    return ["es", "spa", "spanish", "español"]
        case .french:     return ["fr", "fre", "fra", "french", "français"]
        case .german:     return ["de", "ger", "deu", "german", "deutsch"]
        case .italian:    return ["it", "ita", "italian", "italiano"]
        }
    }

    /// Goodreads reports some names as "Spanish; Castilian" — a code match
    /// anywhere in the string counts, not just an exact one.
    func matches(_ reported: String?) -> Bool {
        guard self != .any else { return true }
        guard let reported, !reported.isEmpty else { return false }
        let tokens = reported.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return codes.contains { tokens.contains($0) }
    }

    /// Google Books' `langRestrict` wants a single two-letter code.
    var restrictCode: String? { self == .any ? nil : codes.first }
}

/// This is about the books, not the interface — the app itself stays English.
@MainActor
final class Preferences: ObservableObject {

    static let shared = Preferences()

    @Published var bookLanguage: BookLanguage {
        didSet { defaults.set(bookLanguage.rawValue, forKey: Keys.language) }
    }

    /// How far back "recently read" reaches when building suggestions.
    @Published var suggestionWindowDays: Int {
        didSet { defaults.set(suggestionWindowDays, forKey: Keys.window) }
    }

    /// Books whose language can't be determined: include or hide.
    @Published var includeUnknownLanguage: Bool {
        didSet { defaults.set(includeUnknownLanguage, forKey: Keys.unknown) }
    }

    /// Google Books' free unauthenticated tier is shared across every caller
    /// on the internet and stays exhausted — search and suggestions need a
    /// personal key. Get one free at console.cloud.google.com (enable the
    /// "Books API", then Credentials → Create Credentials → API key).
    ///
    /// Kept in the Keychain, not `UserDefaults` — it's a bearer credential,
    /// not an ordinary preference, and `UserDefaults` is an unencrypted plist.
    @Published var googleBooksAPIKey: String {
        didSet { Keychain.write(googleBooksAPIKey, for: Keys.apiKey) }
    }

    /// Books you want to read this year, for the Stats goal.
    @Published var yearlyGoal: Int {
        didSet {
            defaults.set(yearlyGoal, forKey: Keys.goal)
            WidgetBridge.scheduleUpdate()
        }
    }

    /// Take the Stats goal from your Goodreads Reading Challenge when you've joined it.
    @Published var useGoodreadsChallenge: Bool {
        didSet { defaults.set(useGoodreadsChallenge, forKey: Keys.useChallenge) }
    }

    /// The status bar's Browser button, for troubleshooting. Off unless wanted.
    @Published var showBrowserButton: Bool {
        didSet { defaults.set(showBrowserButton, forKey: Keys.browserButton) }
    }

    /// Progress and finished books from Apple Books and Kobo go to Goodreads by themselves.
    @Published var syncReadingApps: Bool {
        didSet {
            defaults.set(syncReadingApps, forKey: Keys.syncReadingApps)
            if syncReadingApps { Task { await ReadingAppsSync.shared.runAutomatically() } }
        }
    }

    /// Books in Apple Books or on a Kobo that aren't on a shelf get added by themselves.
    @Published var importReadingAppsLibrary: Bool {
        didSet {
            defaults.set(importReadingAppsLibrary, forKey: Keys.importReadingApps)
            if importReadingAppsLibrary { Task { await ReadingAppsSync.shared.runAutomatically() } }
        }
    }

    /// Post a notification when a friend starts or finishes a book.
    @Published var notifyFriendActivity: Bool {
        didSet { defaults.set(notifyFriendActivity, forKey: Keys.notify) }
    }

    /// A notification when an author you've read twice or more has a new book.
    @Published var notifyNewReleases: Bool {
        didSet { defaults.set(notifyNewReleases, forKey: Keys.newReleases) }
    }

    /// A daily notification asking how far you've got.
    @Published var readingReminder: Bool {
        didSet {
            defaults.set(readingReminder, forKey: Keys.reminder)
            ReadingReminder.reschedule()
        }
    }

    /// When the reminder fires, in minutes after midnight.
    @Published var reminderMinutes: Int {
        didSet {
            defaults.set(reminderMinutes, forKey: Keys.reminderTime)
            ReadingReminder.reschedule()
        }
    }

    /// Books on your shelves show up in Spotlight.
    @Published var indexInSpotlight: Bool {
        didSet {
            defaults.set(indexInSpotlight, forKey: SpotlightIndex.enabledKey)
            if indexInSpotlight {
                LibraryModel.shared.indexCachedShelves()
            } else {
                SpotlightIndex.removeAll()
            }
        }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let language = "bookLanguage"
        static let window   = "suggestionWindowDays"
        static let unknown  = "includeUnknownLanguage"
        static let apiKey   = "googleBooksAPIKey"
        static let goal     = "yearlyGoal"
        static let useChallenge = "useGoodreadsChallenge"
        static let browserButton = "showBrowserButton"
        static let syncReadingApps = "syncReadingApps"
        static let importReadingApps = "importReadingAppsLibrary"
        static let notify   = "notifyFriendActivity"
        static let reminder = "readingReminder"
        static let newReleases = "notifyNewReleases"
        static let reminderTime = "reminderMinutes"
    }

    private init() {
        let raw = defaults.string(forKey: Keys.language) ?? BookLanguage.any.rawValue
        bookLanguage = BookLanguage(rawValue: raw) ?? .any

        let days = defaults.integer(forKey: Keys.window)
        suggestionWindowDays = days > 0 ? days : 90

        includeUnknownLanguage = defaults.object(forKey: Keys.unknown) as? Bool ?? true

        let goal = defaults.integer(forKey: Keys.goal)
        yearlyGoal = goal > 0 ? goal : 24
        useGoodreadsChallenge = defaults.object(forKey: Keys.useChallenge) as? Bool ?? true
        showBrowserButton = defaults.bool(forKey: Keys.browserButton)
        syncReadingApps = defaults.bool(forKey: Keys.syncReadingApps)
        importReadingAppsLibrary = defaults.bool(forKey: Keys.importReadingApps)
        notifyFriendActivity = defaults.bool(forKey: Keys.notify)
        indexInSpotlight = SpotlightIndex.isEnabled
        readingReminder = defaults.bool(forKey: Keys.reminder)
        notifyNewReleases = defaults.bool(forKey: Keys.newReleases)
        reminderMinutes = defaults.object(forKey: Keys.reminderTime) as? Int ?? 21 * 60

        // One-time migration: earlier builds kept the key in UserDefaults.
        if let legacy = defaults.string(forKey: Keys.apiKey), !legacy.isEmpty,
           Keychain.read(Keys.apiKey) == nil {
            Keychain.write(legacy, for: Keys.apiKey)
            defaults.removeObject(forKey: Keys.apiKey)
        }

        googleBooksAPIKey = Keychain.read(Keys.apiKey) ?? ""
    }
}

struct PreferencesView: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var cacheBytes: Int?
    @State private var isClearing = false
    @State private var backupMessage: LibraryModel.Status?
    @State private var autoBackup = AutoBackup.isEnabled
    @State private var autoFolder = AutoBackup.folderDescription
    @State private var lastBackup = AutoBackup.lastBackup
    @State private var isBackingUp = false

    var body: some View {
        Form {
            Section {
                Picker("Book language", selection: $prefs.bookLanguage) {
                    ForEach(BookLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }

                Toggle("Include books with unknown language", isOn: $prefs.includeUnknownLanguage)
                    .disabled(prefs.bookLanguage == .any)
            } header: {
                Text("Suggestions")
            } footer: {
                Text("Filters suggested books by edition language.")
                    .appFont(size: 11)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Look back", selection: $prefs.suggestionWindowDays) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                    Text("A year").tag(365)
                }
            }

            Section {
                SecureField("API key", text: $prefs.googleBooksAPIKey)
            } header: {
                Text("Google Books")
            } footer: {
                Text("Search and suggestions use Google Books, whose free shared tier is usually out of quota. Get a free key at console.cloud.google.com — enable the “Books API”, then Credentials → Create Credentials → API key.")
                    .appFont(size: 11)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Notify me when friends start or finish a book", isOn: Binding(
                    get: { prefs.notifyFriendActivity },
                    set: { wanted in
                        guard wanted else { prefs.notifyFriendActivity = false; return }
                        Task { prefs.notifyFriendActivity = await FriendNotifier.requestPermission() }
                    }
                ))
                Toggle("Notify me about new books from authors I read", isOn: Binding(
                    get: { prefs.notifyNewReleases },
                    set: { wanted in
                        guard wanted else { prefs.notifyNewReleases = false; return }
                        Task { prefs.notifyNewReleases = await FriendNotifier.requestPermission() }
                    }
                ))
            } header: {
                Text("Notifications")
            } footer: {
                Text("Friends are checked every hour and new books once a day, while the app is open (it keeps running in the menu bar).")
                    .appFont(size: 11)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Remind me to read every day", isOn: Binding(
                    get: { prefs.readingReminder },
                    set: { wanted in
                        guard wanted else { prefs.readingReminder = false; return }
                        Task { prefs.readingReminder = await FriendNotifier.requestPermission() }
                    }
                ))
                DatePicker("At", selection: Binding(
                    get: {
                        Calendar.current.date(bySettingHour: prefs.reminderMinutes / 60,
                                              minute: prefs.reminderMinutes % 60, second: 0, of: Date()) ?? Date()
                    },
                    set: { date in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                        prefs.reminderMinutes = (parts.hour ?? 21) * 60 + (parts.minute ?? 0)
                    }
                ), displayedComponents: .hourAndMinute)
                .disabled(!prefs.readingReminder)
            } header: {
                Text("Reading Reminder")
            } footer: {
                Text("About the first book on Currently Reading. Type a percentage right in the notification to update it.")
                    .appFont(size: 11)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Sync progress and finished books", isOn: $prefs.syncReadingApps)
                Toggle("Add books that aren’t on my shelves", isOn: $prefs.importReadingAppsLibrary)
                Button("Review Reading Apps…") {
                    WindowManager.shared.openMain?()
                    NSApp.activate(ignoringOtherApps: true)
                    LibraryModel.shared.activeSheet = .readingApps
                }
            } header: {
                Text("Apple Books and Kobo")
            } footer: {
                Text("Reads Apple Books on this Mac and a Kobo plugged in by USB. Progress only ever goes forward, and anything you change back on Goodreads stays changed. Books added automatically go to Read, Currently Reading or Want to Read, depending on how far you got.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Use my Goodreads Reading Challenge goal", isOn: Binding(
                    get: { prefs.useGoodreadsChallenge },
                    set: { wanted in
                        prefs.useGoodreadsChallenge = wanted
                        if wanted { Task { await LibraryModel.shared.loadChallenge(force: true) } }
                    }
                ))
            } header: {
                Text("Reading Goal")
            } footer: {
                Text("When you’ve joined this year’s Reading Challenge on Goodreads, Stats uses its goal. Otherwise you set the goal in Stats.")
                    .appFont(size: 11)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show my books in Spotlight", isOn: $prefs.indexInSpotlight)
            } header: {
                Text("Spotlight")
            } footer: {
                Text("Search your shelves from ⌘Space. Choosing a book opens its details here.")
                    .appFont(size: 11)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Back Up…") {
                        Task { backupMessage = await Backup.export() }
                    }
                    Button("Restore…") {
                        Task {
                            backupMessage = await Backup.restore()
                            await LibraryModel.shared.reloadLocalData()
                        }
                    }
                }
                Toggle("Back up automatically every week", isOn: Binding(
                    get: { autoBackup },
                    set: { wanted in
                        autoBackup = wanted
                        AutoBackup.isEnabled = wanted
                        if wanted {
                            Task {
                                try? await Task.sleep(for: .seconds(1))
                                lastBackup = AutoBackup.lastBackup
                            }
                        }
                    }
                ))
                if autoBackup {
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Text(autoFolder)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Change…") { chooseBackupFolder() }
                        }
                    }
                    LabeledContent("Last backup") {
                        HStack(spacing: 8) {
                            Text(lastBackup.map { $0.formatted(date: .abbreviated, time: .shortened) }
                                 ?? String(localized: "Not yet"))
                                .foregroundStyle(.secondary)
                            Button(isBackingUp ? String(localized: "Backing Up…") : String(localized: "Back Up Now")) {
                                isBackingUp = true
                                Task {
                                    if let error = await AutoBackup.backUpNow() {
                                        backupMessage = .init(text: String(localized: "Couldn’t save the backup: \(error)"), isError: true)
                                    }
                                    lastBackup = AutoBackup.lastBackup
                                    isBackingUp = false
                                }
                            }
                            .disabled(isBackingUp)
                        }
                    }
                }
                if let backupMessage {
                    Text(backupMessage.text)
                        .appFont(size: 11)
                        .foregroundStyle(backupMessage.isError ? Color.red : Color.secondary)
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("Your notes and quotes, your progress history and the books you stopped reading exist only on this Mac. Save them to a file you keep elsewhere, like iCloud Drive. Automatic backups keep the last eight.")
                    .appFont(size: 11)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Show Log…") {
                    WindowManager.shared.openMain?()
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.canBecomeMain && window.identifier?.rawValue.contains("main") == true {
                        window.makeKeyAndOrderFront(nil)
                    }
                    LibraryModel.shared.activeSheet = .diagnostics
                }
                Toggle("Show the Browser button in the status bar", isOn: $prefs.showBrowserButton)
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("The log lists every request the app makes — copy it into a report when something breaks. The browser shows the Goodreads page the app works in.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Saved data") {
                    Text(cacheBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "…")
                        .foregroundStyle(.secondary)
                }
                Button(isClearing ? String(localized: "Clearing…") : String(localized: "Clear Cache")) {
                    isClearing = true
                    Task {
                        await DataCache.clearEverything()
                        cacheBytes = DataCache.diskUsage()
                        isClearing = false
                    }
                }
                .disabled(isClearing)
            } header: {
                Text("Cache")
            } footer: {
                Text("Shelves, book pages, friends and covers are saved so the app opens instantly. Clearing it is safe: everything is fetched again the next time you open it.")
                    .appFont(size: 11)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 860)
        .task { cacheBytes = DataCache.diskUsage() }
    }

    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = AutoBackup.folder.deletingLastPathComponent()
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AutoBackup.folder = url
        autoFolder = AutoBackup.folderDescription
    }
}
