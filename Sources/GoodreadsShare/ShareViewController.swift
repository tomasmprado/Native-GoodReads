import AppKit
import UniformTypeIdentifiers

/// "Add to Goodreads" in the Share menu. It only reads the shared page's
/// address, title and any text, and passes them to the app with a
/// goodreads-gui:// link — the app finds the book and adds it.
@objc(ShareViewController)
final class ShareViewController: NSViewController {

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task { @MainActor in await self.hand() }
    }

    @MainActor
    private func hand() async {
        guard let context = extensionContext else { return }
        var url: URL?
        var title = ""
        var text: String?
        for item in context.inputItems.compactMap({ $0 as? NSExtensionItem }) {
            if title.isEmpty, let attributed = item.attributedContentText?.string { title = attributed }
            for provider in item.attachments ?? [] {
                if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL
                }
                if text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String
                }
            }
        }
        var components = URLComponents()
        components.scheme = "goodreads-gui"
        components.host = "add"
        components.queryItems = [
            URLQueryItem(name: "url", value: url?.absoluteString),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "text", value: text.map { String($0.prefix(2000)) }),
        ].filter { $0.value?.isEmpty == false }
        if let link = components.url { NSWorkspace.shared.open(link) }
        context.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
