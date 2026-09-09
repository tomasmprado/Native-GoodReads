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

    private struct PendingLoad {
        let id = UUID()
        let navigation: WKNavigation?
        let continuation: CheckedContinuation<Void, Error>
    }

    private var pendingLoad: PendingLoad?

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

    // MARK: - Exclusive access

    // One web view, several callers. Without a gate, switching shelves lets
    // the second load's script run against the first page — which shows up as
    // the wrong books under the right shelf name. Every caller that reads or
    // drives the *live* `document` (as opposed to fetching a URL independently
    // via `WebScripts.dom`) must hold this across both the load and the
    // evaluate that depends on it, or another task's navigation can land in
    // between.
    private var locked = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Runs a load-then-evaluate sequence with nobody else touching the web
    /// view in between.
    func exclusive<T>(_ body: () async throws -> T) async rethrows -> T {
        while locked {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiting.append(continuation)
            }
        }
        locked = true
        defer {
            locked = false
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        return try await body()
    }

    // MARK: - Navigation

    /// `timeout` only shortens the network-level wait (Foundation's default
    /// is 60s) — worth doing for pages that are a nice-to-have, not the
    /// critical path, so a slow load fails fast with a clear message instead
    /// of hanging the caller for a minute.
    ///
    /// Every continuation is matched to the specific `WKNavigation` that
    /// created it and backed by its own wall-clock timeout — WebKit doesn't
    /// always call a navigation delegate method back (a load that turns into
    /// a file download, or is cancelled in a way that skips the callback),
    /// and without this a hung navigation would leave `exclusive` locked
    /// forever, silently freezing every shelf read and write in the app.
    func load(_ url: URL, timeout: TimeInterval? = nil) async throws {
        if let pending = pendingLoad {
            pendingLoad = nil
            pending.continuation.resume(throwing: AppError("Navigation superseded."))
        }

        var request = URLRequest(url: url)
        let netTimeout = timeout ?? 60
        request.timeoutInterval = netTimeout

        let navigation = webView.load(request)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pending = PendingLoad(navigation: navigation, continuation: continuation)
            pendingLoad = pending

            let bound = netTimeout + 20
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(bound))
                self?.timeoutIfStillPending(pending.id)
            }
        }
    }

    private func timeoutIfStillPending(_ id: UUID) {
        guard pendingLoad?.id == id else { return }
        let pending = pendingLoad
        pendingLoad = nil
        pending?.continuation.resume(throwing: AppError("Navigation timed out."))
    }

    /// Resolves the pending continuation only if it's still waiting on
    /// *this* navigation — without this, a delegate callback for a
    /// just-superseded load could resume the load that superseded it.
    private func resolvePendingLoad(for navigation: WKNavigation!, result: Result<Void, Error>) {
        guard let pending = pendingLoad, pending.navigation === navigation else { return }
        pendingLoad = nil
        switch result {
        case .success:              pending.continuation.resume()
        case .failure(let error):   pending.continuation.resume(throwing: error)
        }
    }

    /// Runs JS in the page's own world, so `fetch` inherits the session cookies.
    ///
    /// WebKit reports every script failure as the same opaque
    /// "A JavaScript exception occurred", so on failure this retries with the
    /// arguments dictionary inlined as JSON literals instead of passed
    /// through `callAsyncJavaScript`'s bridging — argument bridging is a
    /// plausible cause of a failure that then vanishes on retry, and the
    /// retry's own `try`/`catch` surfaces the real message either way.
    func evaluate(_ script: String,
                  arguments: [String: Any] = [:],
                  label: String = "script") async throws -> String {
        let started = Date()
        do {
            let value = try await webView.callAsyncJavaScript(
                script,
                arguments: arguments,
                in: nil,
                contentWorld: .page
            )
            let text = (value as? String) ?? ""
            Diagnostics.shared.log(label, summarise(text, since: started))
            return text
        } catch {
            Diagnostics.shared.log(label, "first attempt failed: \(error.localizedDescription)", ok: false)
            return try await evaluateFallback(script, arguments: arguments, original: error, label: label)
        }
    }

    /// Logs shape, not content — enough to tell a parse failure from an empty
    /// shelf without dumping a page of JSON into the log. Different scripts
    /// return their list under different keys (`rows` for shelf-style
    /// results, `activity`/`friends`/`books` for the DOM-scraping ones) —
    /// checking only `rows` silently collapsed every one of those to a bare
    /// "ok", hiding a script that ran fine but found zero matches.
    private func summarise(_ text: String, since started: Date) -> String {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let listKeys = ["rows", "activity", "friends", "books"]

        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let ok = object["ok"] as? Bool, !ok {
                return "\(ms)ms — error: \(object["error"] as? String ?? "unknown")"
            }
            if let key = listKeys.first(where: { object[$0] is [Any] }),
               let list = object[key] as? [Any] {
                let pages = object["pages"] as? Int
                return "\(ms)ms — \(list.count) \(key)" + (pages.map { ", \($0) pages" } ?? "")
            }
            return "\(ms)ms — ok"
        }
        return "\(ms)ms — \(text.count) bytes"
    }

    private func evaluateFallback(_ script: String,
                                  arguments: [String: Any],
                                  original: Error,
                                  label: String = "script") async throws -> String {
        // Rebuild the argument bindings as JSON literals, since
        // evaluateJavaScript-style inlining has no arguments parameter.
        var preamble = ""
        for (key, value) in arguments {
            preamble += "const \(key) = \(jsLiteral(for: value));\n"
        }

        // Retry through the same async API, but with the arguments inlined and
        // the dictionary empty — argument bridging is itself a likely cause of
        // the failure we're recovering from.
        let wrapped = """
        try {
        \(preamble)
        \(script)
        } catch (e) {
            return JSON.stringify({ ok: false, error: String(e && e.message ? e.message : e) });
        }
        """

        do {
            let value = try await webView.callAsyncJavaScript(
                wrapped,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            let text = (value as? String) ?? ""
            Diagnostics.shared.log(label, "recovered on retry")
            return text
        } catch {
            Diagnostics.shared.log(label, "retry failed: \(error.localizedDescription)", ok: false)
            throw AppError("Script failed: \(error.localizedDescription) (first attempt: \(original.localizedDescription))")
        }
    }

    /// Renders a Swift value as a JSON literal for inlining into a JS retry.
    /// Valid JSON is valid JS for every shape callers actually pass (strings,
    /// numbers, bools, arrays, dictionaries), and `JSONSerialization` handles
    /// the escaping — control characters, U+2028/2029 — that a hand-rolled
    /// replace chain would miss.
    private func jsLiteral(for value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value]),
           let text = String(data: data, encoding: .utf8),
           text.hasPrefix("["), text.hasSuffix("]") {
            return String(text.dropFirst().dropLast())
        }
        switch value {
        case let number as Int:    return String(number)
        case let number as Double: return String(number)
        case let flag as Bool:     return flag ? "true" : "false"
        default:
            let text = String(describing: value)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(text)\""
        }
    }

    /// Same-origin requests need a Goodreads page loaded first. Only touches
    /// the live document as a side effect of navigating — safe to call
    /// without `exclusive` from a caller whose own script only uses `fetch` +
    /// `DOMParser` (see `WebScripts.dom`), since those don't depend on
    /// whatever page happens to be loaded when they run.
    func ensureOnGoodreads() async throws {
        if webView.url?.host?.hasSuffix("goodreads.com") == true { return }
        try await load(URL(string: "https://www.goodreads.com/")!)
    }

    /// Since work now happens through `fetch` rather than navigation, one
    /// lightweight page stays loaded and everything runs against it. Locking
    /// variant of `ensureOnGoodreads`, for callers not already inside their
    /// own `exclusive` block.
    func ensureResident() async throws {
        try await exclusive { try await self.ensureOnGoodreads() }
    }

    // MARK: - Session state

    /// Loads a page that only exists for signed-in users. A redirect to the
    /// sign-in form is the tell.
    @discardableResult
    func refreshSignInState() async -> Bool {
        isBusy = true
        defer { isBusy = false }

        do {
            try await exclusive {
                try await load(URL(string: "https://www.goodreads.com/review/list")!)
            }
            let path = webView.url?.absoluteString ?? ""
            isSignedIn = !path.contains("sign_in") && !path.contains("/user/new")
        } catch {
            isSignedIn = false
        }
        return isSignedIn
    }

    func beginSignIn() async {
        try? await exclusive {
            try await load(URL(string: "https://www.goodreads.com/user/sign_in")!)
        }
    }

    /// `/user/sign_out` clears the server-side session, but the request can
    /// fail silently the same way any of these legacy endpoints can, and even
    /// when it succeeds the cookie can linger in the persistent
    /// `WKWebsiteDataStore` regardless. Clear it directly, then verify with
    /// the same redirect check sign-in uses, rather than just assuming.
    func signOut() async {
        isBusy = true
        defer { isBusy = false }

        try? await exclusive {
            try await load(URL(string: "https://www.goodreads.com/user/sign_out")!)
        }
        await clearGoodreadsCookies()
        await refreshSignInState()
    }

    private func clearGoodreadsCookies() async {
        let store = webView.configuration.websiteDataStore
        let records = await store.dataRecords(ofTypes: [WKWebsiteDataTypeCookies])
        let goodreadsRecords = records.filter { $0.displayName.contains("goodreads.com") }
        guard !goodreadsRecords.isEmpty else { return }
        await store.removeData(ofTypes: [WKWebsiteDataTypeCookies], for: goodreadsRecords)
    }
}

// MARK: - WKNavigationDelegate

extension WebSession: WKNavigationDelegate {

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.resolvePendingLoad(for: navigation, result: .success(()))
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFail navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.resolvePendingLoad(for: navigation, result: .failure(error))
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            // Cancelled navigations are routine (redirects, our own reloads).
            if (error as? URLError)?.code == .cancelled {
                self.resolvePendingLoad(for: navigation, result: .success(()))
            } else {
                self.resolvePendingLoad(for: navigation, result: .failure(error))
            }
        }
    }
}
