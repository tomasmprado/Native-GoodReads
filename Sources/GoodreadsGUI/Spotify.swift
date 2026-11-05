import AppKit
import CryptoKit
import Network
import SwiftUI

/// The soundtrack on Spotify: each song opens there, and the whole mix
/// can become a private playlist in your account.
///
/// Making playlists needs Spotify's Web API, which since 2026 wants an app
/// of your own on developer.spotify.com (owned by a Premium account) — you
/// create it, paste its Client ID once, and sign in in the browser. The
/// sign-in comes back to a one-off listener on 127.0.0.1 (PKCE, no secret).
@MainActor
enum Spotify {
    static let clientIDKey = "spotifyClientID"
    private static let refreshAccount = "spotify-refresh-token"
    private static let scopes = "playlist-modify-private playlist-modify-public"

    static var clientID: String {
        (UserDefaults.standard.string(forKey: clientIDKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var isSignedIn: Bool { Keychain.read(refreshAccount) != nil }

    private static var accessToken: (value: String, expires: Date)?

    static func signOut() {
        accessToken = nil
        Keychain.write("", for: refreshAccount)
    }

    // MARK: Opening one song

    static var hasApp: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
    }

    /// The song in the Spotify app when it's installed, else on the web.
    static func searchURL(_ track: SoundtrackTrack) -> URL? {
        let query = "\(track.artist) \(cleanName(track.name))"
        if hasApp {
            return URL(string: "spotify:search:" + (query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query))
        }
        return URL(string: "https://open.spotify.com/search/" + (query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query))
    }

    /// "Verdes Anos (Instrumental) - Remastered 2003" → "Verdes Anos": the
    /// part of a title both stores agree on.
    nonisolated static func cleanName(_ name: String) -> String {
        var name = name.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        if let dash = name.range(of: " - ") { name = String(name[..<dash.lowerBound]) }
        return name.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Playlist

    struct Created: Sendable {
        let url: URL
        let found: Int
        let total: Int
    }

    /// A private playlist with the songs Spotify has; `progress` gets how
    /// many were looked for so far.
    static func makePlaylist(name: String, about: String, tracks: [SoundtrackTrack],
                             progress: @escaping @MainActor (Int) -> Void) async throws -> Created {
        var uris: [String] = []
        for (index, track) in tracks.enumerated() {
            if let uri = try await find(track) { uris.append(uri) }
            progress(index + 1)
        }
        guard !uris.isEmpty else { throw AppError("Spotify didn’t find any of these songs.") }
        let playlist = try await call("POST", "me/playlists",
                                      body: ["name": name, "description": about, "public": false])
        guard let id = playlist["id"] as? String else { throw AppError("Spotify didn’t make the playlist.") }
        for start in stride(from: 0, to: uris.count, by: 100) {
            _ = try await call("POST", "playlists/\(id)/items", body: ["uris": Array(uris[start..<min(start + 100, uris.count)])])
        }
        let web = (playlist["external_urls"] as? [String: Any])?["spotify"] as? String
        let url = hasApp ? URL(string: "spotify:playlist:\(id)") : web.flatMap(URL.init(string:))
        return Created(url: url ?? URL(string: "https://open.spotify.com/playlist/\(id)")!, found: uris.count, total: tracks.count)
    }

    /// The song on Spotify: by title and artist, then more loosely.
    private static func find(_ track: SoundtrackTrack) async throws -> String? {
        let name = cleanName(track.name)
        for query in ["track:\"\(name)\" artist:\"\(track.artist)\"", "\(track.artist) \(name)"] {
            let result = try await call("GET", "search", query: ["q": query, "type": "track", "limit": "3"])
            let items = ((result["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            let match = items.first { item in
                let artists = (item["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                return artists.contains { AuthorWikipedia.sameName($0, track.artist) }
            } ?? (query.hasPrefix("track:") ? items.first : nil)
            if let uri = match?["uri"] as? String { return uri }
        }
        return nil
    }

    // MARK: Web API

    private static func call(_ method: String, _ path: String, query: [String: String] = [:],
                             body: [String: Any]? = nil, retried: Bool = false) async throws -> [String: Any] {
        var components = URLComponents(string: "https://api.spotify.com/v1/" + path)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, !retried {
            accessToken = nil
            return try await call(method, path, query: query, body: body, retried: true)
        }
        if status == 429, !retried {
            let wait = Double((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
            try await Task.sleep(for: .seconds(min(wait, 10)))
            return try await call(method, path, query: query, body: body, retried: true)
        }
        guard (200..<300).contains(status) else {
            Diagnostics.shared.log("spotify", "\(method) \(path): HTTP \(status)", ok: false)
            if status == 403 {
                throw AppError("Spotify said no (403). Developer apps need the app’s owner to have Spotify Premium, and you must be the owner or one of its users.")
            }
            throw AppError("Spotify answered with an error (HTTP \(status)).")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Signing in

    private static func token() async throws -> String {
        if let token = accessToken, token.expires > Date().addingTimeInterval(60) { return token.value }
        let id = clientID
        guard !id.isEmpty else { throw AppError("Add your Spotify Client ID first.") }
        if let refresh = Keychain.read(refreshAccount),
           let fresh = try? await exchange(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": id]) {
            return fresh
        }
        return try await signIn(clientID: id)
    }

    private static func signIn(clientID: String) async throws -> String {
        let verifier = randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let state = randomString(16)
        let receiver = try LoopbackReceiver()
        let port = try await receiver.start()
        let redirect = "http://127.0.0.1:\(port)/callback"
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect), URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
        ]
        NSWorkspace.shared.open(components.url!)
        let callback = try await receiver.waitForCallback()
        NSApp.activate(ignoringOtherApps: true)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard item("state") == state else { throw AppError("The Spotify sign-in didn’t match. Try again.") }
        guard let code = item("code") else {
            throw AppError(verbatim: item("error") == "access_denied" ? String(localized: "You didn’t allow it on Spotify.")
                                                            : String(localized: "Spotify didn’t sign you in."))
        }
        return try await exchange(["grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
                                   "client_id": clientID, "code_verifier": verifier])
    }

    private static func exchange(_ form: [String: String]) async throws -> String {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            Diagnostics.shared.log("spotify", "token: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)", ok: false)
            if form["grant_type"] == "refresh_token" { Keychain.write("", for: refreshAccount) }
            throw AppError("Spotify didn’t sign you in. Check the Client ID and that the app’s Redirect URI is http://127.0.0.1/callback.")
        }
        if let refresh = json["refresh_token"] as? String { Keychain.write(refresh, for: refreshAccount) }
        let seconds = json["expires_in"] as? Double ?? 3600
        accessToken = (token, Date().addingTimeInterval(seconds))
        return token
    }

    private static func randomString(_ length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in characters.randomElement()! })
    }
}

/// Waits on 127.0.0.1 (a port the system picks) for the browser to come
/// back from Spotify's sign-in, answers it with a small page, then stops.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "spotify-sign-in")
    // Touched only on `queue`.
    private var started: CheckedContinuation<UInt16, Error>?
    private var waiting: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.started = continuation
                self.listener.stateUpdateHandler = { state in self.stateChanged(state) }
                self.listener.newConnectionHandler = { connection in self.handle(connection) }
                self.listener.start(queue: self.queue)
            }
        }
    }

    /// The URL the browser asked for, or an error after five minutes.
    func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let result = self.result { continuation.resume(with: result); return }
                self.waiting = continuation
                self.queue.asyncAfter(deadline: .now() + 300) {
                    self.finish(.failure(AppError("The Spotify sign-in took too long.")))
                }
            }
        }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            started?.resume(returning: listener.port?.rawValue ?? 0)
            started = nil
        case .failed(let error):
            started?.resume(throwing: error)
            started = nil
            finish(.failure(error))
        default: break
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let isCallback = path.hasPrefix("/callback")
            let page = isCallback ? String(localized: "Done — you can close this tab and go back to Goodreads.") : "Not found"
            let html = "<!doctype html><meta charset=utf-8><title>Goodreads</title>"
                + "<body style=\"font:16px -apple-system;margin:4em;text-align:center\">\(page)</body>"
            let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isCallback, let url = URL(string: "http://127.0.0.1" + path) { self.finish(.success(url)) }
        }
    }

    private func finish(_ outcome: Result<URL, Error>) {
        guard result == nil else { return }
        result = outcome
        waiting?.resume(with: outcome)
        waiting = nil
        listener.cancel()
        // Lets go of this receiver.
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
    }
}

// MARK: - Setting it up

/// How to get a Client ID, and the field to paste it in.
struct SpotifySetupSheet: View {
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Spotify.clientIDKey) private var clientID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playlists on Spotify").appFont(size: 15, weight: .semibold)
            Text("Spotify only lets apps make playlists through an app of your own. It takes two minutes, once:")
                .appFont(size: 12).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                step(1, String(localized: "Open developer.spotify.com/dashboard and sign in (the account needs Spotify Premium)."))
                step(2, String(localized: "Create app. Any name; for Redirect URI put http://127.0.0.1/callback and tick Web API."))
                step(3, String(localized: "Copy the app’s Client ID and paste it below."))
            }
            Button("Open the Spotify Dashboard") {
                NSWorkspace.shared.open(URL(string: "https://developer.spotify.com/dashboard")!)
            }
            TextField("Client ID", text: $clientID)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            Text("The first playlist opens Spotify in your browser to ask for permission.")
                .appFont(size: 11).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue") { dismiss(); onDone() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(clientID.trimmingCharacters(in: .whitespaces).count < 20)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)").appFont(size: 11, weight: .bold).foregroundStyle(Color.accentColor)
            Text(text).appFont(size: 12).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
