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
            } header: {
                Text("Friends")
            } footer: {
                Text("Checked every hour while the app is open (it keeps running in the menu bar).")
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
        .frame(width: 460, height: 660)
        .task { cacheBytes = DataCache.diskUsage() }
    }
}
