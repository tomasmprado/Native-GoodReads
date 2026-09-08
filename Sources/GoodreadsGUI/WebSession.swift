import Foundation
import WebKit

/// Replaces the CLI's rod automation with WebKit, which ships with macOS.
///
/// Cookies live in the app's persistent `WKWebsiteDataStore`, so a session
/// survives quits exactly like `~/.goodreads-cli-session` did — except it's
/// stored in the app container instead of your home folder, and there's no
/// password on disk anywhere.
@MainActor
final class WebSession: NSObject, ObservableObject {

    static let shared = WebSession()

    @Published private(set) var isSignedIn = false
    @Published private(set) var isBusy = false

    let webView: WKWebView

    private var pendingLoad: CheckedContinuation<Void, Error>?

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1100, height: 800),
            configuration: config
        )
        super.init()

        // Goodreads serves a degraded page to unrecognised agents.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.navigationDelegate = self
    }

    // MARK: - Navigation

    func load(_ url: URL) async throws {
        if let pendingLoad {
            self.pendingLoad = nil
            pendingLoad.resume(throwing: AppError("Navigation superseded."))
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingLoad = continuation
            webView.load(URLRequest(url: url))
        }
    }

    /// Runs JS in the page's own world, so `fetch` inherits the session cookies.
    func evaluate(_ script: String, arguments: [String: Any] = [:]) async throws -> String {
        let value = try await webView.callAsyncJavaScript(
            script,
            arguments: arguments,
            in: nil,
            contentWorld: .page
        )
        return (value as? String) ?? ""
    }

    var currentURL: URL? { webView.url }

    /// Same-origin requests need a Goodreads page loaded first.
    func ensureOnGoodreads() async throws {
        if webView.url?.host?.hasSuffix("goodreads.com") == true { return }
        try await load(URL(string: "https://www.goodreads.com/")!)
    }

    // MARK: - Session state

    /// Loads a page that only exists for signed-in users. A redirect to the
    /// sign-in form is the tell.
    @discardableResult
    func refreshSignInState() async -> Bool {
        isBusy = true
        defer { isBusy = false }

        do {
            try await load(URL(string: "https://www.goodreads.com/review/list")!)
            let path = webView.url?.absoluteString ?? ""
            isSignedIn = !path.contains("sign_in") && !path.contains("/user/new")
        } catch {
            isSignedIn = false
        }
        return isSignedIn
    }

    func beginSignIn() async {
        try? await load(URL(string: "https://www.goodreads.com/user/sign_in")!)
    }

    func signOut() async {
        try? await load(URL(string: "https://www.goodreads.com/user/sign_out")!)
        isSignedIn = false
    }
}

// MARK: - WKNavigationDelegate

extension WebSession: WKNavigationDelegate {

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let continuation = self.pendingLoad
            self.pendingLoad = nil
            continuation?.resume()
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFail navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            let continuation = self.pendingLoad
            self.pendingLoad = nil
            continuation?.resume(throwing: error)
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            let continuation = self.pendingLoad
            self.pendingLoad = nil
            // Cancelled navigations are routine (redirects, our own reloads).
            if (error as? URLError)?.code == .cancelled {
                continuation?.resume()
            } else {
                continuation?.resume(throwing: error)
            }
        }
    }
}
