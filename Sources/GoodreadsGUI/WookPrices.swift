import Foundation
import WebKit

/// Reads a page in an off-screen web view and runs a script on it — for
/// shops that turn away plain requests but serve a normal browser.
@MainActor
final class HeadlessPage: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Bool, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: configuration)
        super.init()
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.navigationDelegate = self
    }

    /// Loads `url`, waits a moment for scripts to fill the page, then runs `script`.
    func evaluate(_ url: URL, script: String, settle: Duration = .milliseconds(1500)) async -> Any? {
        let loaded = await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url, timeoutInterval: 20))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                self?.finish(false)
            }
        }
        guard loaded else { return nil }
        try? await Task.sleep(for: settle)
        return try? await webView.evaluateJavaScript(script)
    }

    private func finish(_ ok: Bool) {
        continuation?.resume(returning: ok)
        continuation = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finish(true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(false) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(false) }
    }
}

/// Wook's price for a book: its search, by ISBN when there is one.
enum WookPrices {
    struct Item: Equatable {
        let title: String
        let url: URL
        let price: Double
    }

    private static let script = """
    (() => [...document.querySelectorAll('li.product, div.product')].slice(0, 12).map(p => {
        const link = p.querySelector('.title a') || p.querySelector('a[href*="/livro/"], a[href*="/ebook/"]');
        const price = p.querySelector('.pvp-discount .pvp, .pvp') || p;
        return { title: (link && link.textContent || '').trim(), href: link ? link.href : '',
                 price: (price.textContent || '').replace(/\\s+/g, ' ').trim() };
    }))()
    """

    /// "8,80€", "1 234,50 €" → 8.8, 1234.5 — the first price in the text.
    static func amount(_ text: String) -> Double? {
        guard let range = text.range(of: #"\d[\d\. ]*,\d{2}\s?€"#, options: .regularExpression) else { return nil }
        let number = text[range].replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Double(number)
    }

    static func items(from value: Any?) -> [Item] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let title = row["title"] as? String, !title.isEmpty,
                  let href = row["href"] as? String, let url = URL(string: href),
                  let price = (row["price"] as? String).flatMap(amount) else { return nil }
            return Item(title: title, url: url, price: price)
        }
    }

    @MainActor
    static func lookup(_ entry: ShelfEntry, page: HeadlessPage) async -> PriceWatch.Price? {
        let isbn = entry.isbn13 ?? entry.isbn
        let query = isbn ?? [entry.title, entry.author].filter { !$0.isEmpty }.joined(separator: " ")
        var components = URLComponents(string: "https://www.wook.pt/pesquisa")!
        components.queryItems = [URLQueryItem(name: "keyword", value: query)]
        guard let url = components.url else { return nil }
        let items = items(from: await page.evaluate(url, script: script))
        guard !items.isEmpty else { return nil }
        // An ISBN search finds that edition; a title search needs the best match.
        let item: Item?
        if isbn != nil, items.count == 1 {
            item = items.first
        } else {
            let candidates = items.enumerated().map { Book(id: String($0.offset), title: $0.element.title, author: "", coverURL: nil, rating: nil) }
            item = GoogleBooksClient.bestMatch(candidates, title: entry.title).flatMap { Int($0.id) }.map { items[$0] }
        }
        guard let item else { return nil }
        return PriceWatch.Price(amount: item.price, formatted: String(format: "%.2f €", item.price).replacingOccurrences(of: ".", with: ","),
                                currency: "EUR", url: item.url)
    }
}
