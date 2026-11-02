import AppKit

/// Installs a newer release in place: downloads its `.dmg`, copies the app
/// out of it, swaps it for the running one and relaunches. No Sparkle — the
/// app has no dependencies and this is all it needs.
///
/// The swap itself has to happen after this process exits (a running app
/// can't replace its own bundle cleanly), so a tiny shell script waits for
/// our PID to go away, moves the new copy into place and reopens it.
@MainActor
final class SelfUpdater: ObservableObject {
    static let shared = SelfUpdater()

    enum State: Equatable {
        case idle
        /// Fraction done, when the server says how big the file is.
        case downloading(Double?)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private init() { }

    /// Whether this copy can update itself. It can't when it's running
    /// straight from the disk image, from App Translocation (an app opened
    /// from Downloads before being moved), or from a folder it can't write.
    var canInstallInPlace: Bool {
        let app = Bundle.main.bundleURL
        let path = app.path
        guard app.pathExtension == "app",
              !path.hasPrefix("/Volumes/"),
              !path.contains("/AppTranslocation/") else { return false }
        return FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    func install(_ update: UpdateChecker.Available) {
        guard let dmgURL = update.dmgURL, canInstallInPlace else {
            NSWorkspace.shared.open(update.url)
            return
        }
        guard state == .idle || state.isFailure else { return }
        Task { await run(dmgURL: dmgURL, version: update.version) }
    }

    private func run(dmgURL: URL, version: String) async {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoodreadsUpdate-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            state = .downloading(nil)
            let dmg = try await download(dmgURL, to: work.appendingPathComponent("update.dmg"))

            state = .installing
            let staged = try await stageApp(from: dmg, in: work)
            try verify(staged, expectedVersion: version)
            await resignLikeCurrent(staged, in: work)
            try relaunch(replacingWith: staged, workDir: work)
        } catch {
            state = .failed(error.localizedDescription)
            try? FileManager.default.removeItem(at: work)
        }
    }

    private func download(_ url: URL, to destination: URL) async throws -> URL {
        let downloader = Downloader(destination: destination) { [weak self] fraction in
            Task { @MainActor in
                // A redraw per percent is plenty.
                guard let self, case .downloading(let shown) = self.state,
                      fraction - (shown ?? -1) >= 0.01 || fraction >= 1 else { return }
                self.state = .downloading(fraction)
            }
        }
        return try await downloader.run(url)
    }

    /// Mounts the image, copies the app out, unmounts.
    private func stageApp(from dmg: URL, in work: URL) async throws -> URL {
        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try await Self.shell("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly",
                                                  "-noautoopen", "-mountpoint", mount.path])
        defer { Task.detached { try? await Self.shell("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) } }

        guard let app = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw AppError("The update's disk image has no app in it.")
        }
        let staged = work.appendingPathComponent(app.lastPathComponent)
        try await Self.shell("/usr/bin/ditto", [app.path, staged.path])
        return staged
    }

    /// When this copy was signed on this Mac (install.sh, or a local build),
    /// the update is signed the same way, so the Keychain keeps trusting it
    /// and doesn't ask for the password again. Best-effort: an unsigned
    /// update still installs.
    private func resignLikeCurrent(_ staged: URL, in work: URL) async {
        guard let details = try? await Self.shell("/usr/bin/codesign", ["-dv", Bundle.main.bundlePath]),
              let authority = Self.signingAuthority(fromCodesignOutput: details) else { return }
        let entitlements = work.appendingPathComponent("widget.entitlements")
        let widget = staged.appendingPathComponent("Contents/PlugIns/GoodreadsWidget.appex")
        do {
            if FileManager.default.fileExists(atPath: widget.path) {
                try Self.widgetEntitlements.write(to: entitlements, atomically: true, encoding: .utf8)
                try await Self.shell("/usr/bin/codesign", ["--force", "--sign", authority,
                                                          "--entitlements", entitlements.path,
                                                          "--generate-entitlement-der", widget.path])
            }
            try await Self.shell("/usr/bin/codesign", ["--force", "--sign", authority, staged.path])
        } catch {
            Diagnostics.shared.log("update", "couldn’t sign the update like this copy: \(error.localizedDescription)", ok: false)
        }
    }

    /// The certificate name in `codesign -dv` output, or nil when ad hoc.
    nonisolated static func signingAuthority(fromCodesignOutput output: String) -> String? {
        output.split(separator: "\n")
            .first { $0.hasPrefix("Authority=") }
            .map { String($0.dropFirst("Authority=".count)) }
    }

    nonisolated static let widgetEntitlements = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>com.apple.security.app-sandbox</key><true/>
        <key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
        <array><string>/Library/Application Support/GoodreadsGUI/widget/</string></array>
    </dict>
    </plist>
    """

    /// Same app, and actually the version we went to get.
    private func verify(_ staged: URL, expectedVersion: String) throws {
        guard let info = Bundle(url: staged)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw AppError("The downloaded app isn't Goodreads.")
        }
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        guard !UpdateChecker.isNewer(expectedVersion, than: version) else {
            throw AppError("The downloaded app is version \(version), not \(expectedVersion).")
        }
    }

    private func relaunch(replacingWith staged: URL, workDir: URL) throws {
        let target = Bundle.main.bundleURL
        let script = workDir.appendingPathComponent("install.sh")
        try Self.installScript.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier),
                             staged.path, target.path, workDir.path]
        try process.run()
        NSApp.terminate(nil)
    }

    /// $1 pid to wait for, $2 new app, $3 where it goes, $4 folder to clean up.
    /// The old copy is kept until the new one is in place, and put back if
    /// the move fails, so a failed update never leaves no app at all.
    nonisolated static let installScript = """
    #!/bin/sh
    pid="$1"; new="$2"; target="$3"; work="$4"
    for i in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    backup="$target.old-$$"
    mv "$target" "$backup" || { open "$target"; exit 1; }
    if mv "$new" "$target"; then
        rm -rf "$backup"
        xattr -dr com.apple.quarantine "$target" 2>/dev/null
    else
        mv "$backup" "$target"
    fi
    open "$target"
    rm -rf "$work"
    """

    @discardableResult
    nonisolated private static func shell(_ tool: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { finished in
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let tool = URL(fileURLWithPath: tool).lastPathComponent
                    continuation.resume(throwing: AppError("\(tool) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

/// A download that reports how far along it is — `URLSession.download(from:)`
/// doesn't. Calls arrive on the session's own serial queue.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func run(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temporary file is gone once this returns, so move it now.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(AppError("Download failed (HTTP \(http.statusCode)).")))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        session.finishTasksAndInvalidate()
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

extension SelfUpdater.State {
    var isFailure: Bool { if case .failed = self { return true } else { return false } }
}
