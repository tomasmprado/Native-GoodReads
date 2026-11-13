import Foundation

/// The author's Wikipedia article — in the app's language when there is one,
/// otherwise in English. Only an article whose title is the author's name
/// and whose description says they write is taken, so a namesake isn't linked.
enum AuthorWikipedia {

    struct Article: Codable, Equatable, Sendable {
        let url: URL
        let language: String
        let description: String?
    }

    static func article(for name: String,
                        languages: [String] = [Bundle.main.preferredLocalizations.first ?? "en", "en"]) async -> Article? {
        let key = name.lowercased()
        if let hit = await DataCache.shared.read(Article?.self, "wikipedia", key, ttl: 30 * 24 * 3600), !hit.isStale {
            return hit.value
        }
        var found: Article?
        var seen = Set<String>()
        for language in languages where seen.insert(language).inserted {
            if let article = await search(name, language: language) { found = article; break }
        }
        await DataCache.shared.write(found, "wikipedia", key)
        return found
    }

    private static func search(_ name: String, language: String) async -> Article? {
        var components = URLComponents(string: "https://\(language).wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: name), URLQueryItem(name: "srlimit", value: "3"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url,
              let data = try? await get(url),
              let result = try? JSONDecoder().decode(SearchResult.self, from: data) else { return nil }
        for title in result.query.search.map(\.title) where sameName(title, name) {
            guard let summary = await summary(title, language: language),
                  summary.type == "standard", isWriter(summary.description) else { continue }
            return Article(url: summary.content_urls.desktop.page, language: language, description: summary.description)
        }
        return nil
    }

    private static func summary(_ title: String, language: String) async -> Summary? {
        let path = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? title
        guard let url = URL(string: "https://\(language).wikipedia.org/api/rest_v1/page/summary/\(path)"),
              let data = try? await get(url) else { return nil }
        return try? JSONDecoder().decode(Summary.self, from: data)
    }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("OpenShelf/1.0 (macOS; https://github.com/tomasmprado/OpenShelf)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// "J. R. R. Tolkien" and "J.R.R. Tolkien" are the same name; a title
    /// with a qualifier ("Paul Auster (writer)") still counts.
    static func sameName(_ title: String, _ name: String) -> Bool {
        func fold(_ text: String) -> String {
            text.replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .filter { $0.isLetter || $0.isNumber }
        }
        return !fold(name).isEmpty && fold(title) == fold(name)
    }

    static func isWriter(_ description: String?) -> Bool {
        guard let description = description?.lowercased() else { return false }
        let words = ["writer", "author", "novelist", "poet", "playwright", "essayist", "journalist", "historian",
                     "philosopher", "screenwriter", "illustrator", "cartoonist", "scientist", "professor", "translator",
                     "escritor", "escritora", "autor", "autora", "romancista", "poeta", "poetisa", "dramaturgo",
                     "ensaísta", "jornalista", "historiador", "filósofo", "argumentista", "ilustrador", "cientista",
                     "professor", "tradutor", "cronista", "contista", "filólogo"]
        return words.contains { description.contains($0) }
    }

    private struct SearchResult: Decodable {
        struct Query: Decodable { let search: [Hit] }
        struct Hit: Decodable { let title: String }
        let query: Query
    }

    private struct Summary: Decodable {
        struct URLs: Decodable { struct Page: Decodable { let page: URL }; let desktop: Page }
        let type: String
        let description: String?
        let content_urls: URLs
    }
}
