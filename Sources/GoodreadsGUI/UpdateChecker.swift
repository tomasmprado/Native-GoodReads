import Foundation

/// A quiet, best-effort check against GitHub Releases.
///
/// This app breaks whenever Goodreads reorganizes a page, and — unlike an
/// App Store build — there's no other channel that tells someone running an
/// old `.dmg` that a fix already shipped. Failure here (offline, rate
/// limited, no releases yet) is never surfaced as an error; it's a nicety,
/// not something worth interrupting anyone over.
enum UpdateChecker {
    private static let repo = "tomasmprado/OpenShelf"

    struct Available: Equatable {
        let version: String
        let url: URL
        /// The release's `.dmg`, when it has one — what `SelfUpdater` installs.
        var dmgURL: URL?
        /// The release description (Markdown), shown before installing.
        var notes: String? = nil
    }

    static func checkForUpdate() async -> Available? {
        guard let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !current.isEmpty else {
            return nil
        }

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OpenShelf/\(current) (macOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let release = try? JSONDecoder().decode(Release.self, from: data) else {
            return nil
        }

        let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard isNewer(latest, than: current), let url = URL(string: release.htmlURL) else { return nil }
        let dmg = release.assets?
            .first { $0.name.lowercased().hasSuffix(".dmg") }
            .flatMap { URL(string: $0.browserDownloadURL) }
        let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Available(version: latest, url: url, dmgURL: dmg,
                         notes: notes?.isEmpty == false ? notes : nil)
    }

    /// Plain dot-separated numeric comparison — string comparison alone
    /// would sort "1.10.0" before "1.2.0". Internal so tests can pin this
    /// down without a real GitHub API round trip.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        guard !a.isEmpty else { return false }

        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        let assets: [Asset]?
        let body: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets, body
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}
