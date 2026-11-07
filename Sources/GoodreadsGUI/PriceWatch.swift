import Foundation
import UserNotifications

/// Watches the Apple Books price of the ebooks on Want to Read and sends a
/// notification when one gets cheaper or goes free. Uses Apple's free store
/// search; checked once a day while the app runs.
enum PriceWatch {

    struct Price: Codable, Equatable, Sendable {
        let amount: Double
        let formatted: String
        let currency: String
        let url: URL
    }

    private static let namespace = "prices"
    private static let key = "apple-books"

    static func saved() async -> [String: Price] {
        await DataCache.shared.read([String: Price].self, namespace, key, ttl: .infinity)?.value ?? [:]
    }

    /// The Apple Books price for a book in your store's country, if it's there.
    static func lookup(title: String, author: String,
                       region: String? = Locale.current.region?.identifier) async -> Price? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: [title, author].filter { !$0.isEmpty }.joined(separator: " ")),
            URLQueryItem(name: "media", value: "ebook"), URLQueryItem(name: "entity", value: "ebook"),
            URLQueryItem(name: "limit", value: "10"), URLQueryItem(name: "country", value: (region ?? "US").lowercased()),
        ]
        guard let url = components.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let result = try? JSONDecoder().decode(Search.self, from: data) else { return nil }
        let candidates = result.results.enumerated().map { offset, item in
            Book(id: String(offset), title: item.trackName ?? "", author: item.artistName ?? "", coverURL: nil, rating: nil)
        }
        guard let best = GoogleBooksClient.bestMatch(candidates, title: title), let index = Int(best.id) else { return nil }
        let item = result.results[index]
        guard let amount = item.price, let link = item.trackViewUrl else { return nil }
        return Price(amount: amount, formatted: item.formattedPrice ?? String(format: "%.2f", amount),
                     currency: item.currency ?? "", url: link)
    }

    /// Whether going from `old` to `new` is worth a notification.
    static func isDrop(from old: Price?, to new: Price) -> Bool {
        guard let old, old.currency == new.currency else { return false }
        return new.amount < old.amount - 0.009
    }

    /// Checks every Want to Read book and notifies about drops: Apple
    /// Books for all of them, and Wook (in Portugal) for up to 40 a day,
    /// taking turns so every book gets looked at.
    @MainActor
    static func check() async {
        guard Preferences.shared.notifyPriceDrops else { return }
        var prices = await saved()
        let wanted = ShelfCache.read(.wantToRead)?.entries ?? []
        for entry in wanted where !Task.isCancelled {
            guard let price = await lookup(title: entry.title, author: entry.author) else { continue }
            if isDrop(from: prices[entry.bookID], to: price) {
                await notifyDrop(entry, store: "Apple Books", price: price, was: prices[entry.bookID])
            }
            prices[entry.bookID] = price
            try? await Task.sleep(for: .milliseconds(400))   // gentle on Apple's search
        }
        await DataCache.shared.write(prices, namespace, key)

        guard Locale.current.region?.identifier == "PT", !wanted.isEmpty else { return }
        let page = HeadlessPage()
        let start = UserDefaults.standard.integer(forKey: wookTurnKey) % wanted.count
        let turn = (0..<min(40, wanted.count)).map { wanted[(start + $0) % wanted.count] }
        for entry in turn where !Task.isCancelled {
            let key = "wook:\(entry.bookID)"
            if let price = await WookPrices.lookup(entry, page: page) {
                if isDrop(from: prices[key], to: price) {
                    await notifyDrop(entry, store: "Wook", price: price, was: prices[key])
                }
                prices[key] = price
            }
            try? await Task.sleep(for: .seconds(2))   // one page at a time, like a person
        }
        UserDefaults.standard.set(start + turn.count, forKey: wookTurnKey)
        await DataCache.shared.write(prices, namespace, key)
    }

    private static let wookTurnKey = "wookPriceTurn"

    private static func notifyDrop(_ entry: ShelfEntry, store: String, price: Price, was old: Price?) async {
        let content = UNMutableNotificationContent()
        content.title = price.amount == 0
            ? String(localized: "\(entry.title) is free at \(store)")
            : String(localized: "\(entry.title) is cheaper at \(store)")
        content.body = String(localized: "Now \(price.formatted) (was \(old?.formatted ?? "")).")
        content.userInfo = ["url": price.url.absoluteString]
        content.sound = .default
        let request = UNNotificationRequest(identifier: "price-\(store)-\(entry.bookID)-\(price.amount)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// A first check a few minutes after launch, then daily.
    @MainActor
    static func start() {
        Task {
            try? await Task.sleep(for: .seconds(180))
            while !Task.isCancelled {
                await check()
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    private struct Search: Decodable {
        struct Item: Decodable {
            let trackName: String?
            let artistName: String?
            let trackViewUrl: URL?
            let price: Double?
            let formattedPrice: String?
            let currency: String?
        }
        let results: [Item]
    }
}
