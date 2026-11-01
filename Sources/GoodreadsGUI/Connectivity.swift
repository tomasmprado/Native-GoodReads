import Foundation
import Network

/// Whether the Mac is online. Everything in the app still works offline from
/// the cache; this only lets the status bar say that what you see is saved
/// data, and refreshes the current pane once the connection comes back.
@MainActor
final class Connectivity: ObservableObject {
    static let shared = Connectivity()

    @Published private(set) var isOnline = true

    /// Runs on the main actor whenever the connection comes back.
    var onReconnect: (() -> Void)?

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.update(online) }
        }
        monitor.start(queue: DispatchQueue(label: "Connectivity"))
    }

    private func update(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        if online { onReconnect?() }
    }
}
