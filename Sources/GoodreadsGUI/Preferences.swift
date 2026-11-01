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
        didSet { defaults.set(yearlyGoal, forKey: Keys.goal) }
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
                    .font(.system(size: 11))
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
                    .font(.system(size: 11))
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
                    .font(.system(size: 11))
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show my books in Spotlight", isOn: $prefs.indexInSpotlight)
            } header: {
                Text("Spotlight")
            } footer: {
                Text("Search your shelves from ⌘Space. Choosing a book opens its details here.")
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 720)
        .task { cacheBytes = DataCache.diskUsage() }
    }
}
