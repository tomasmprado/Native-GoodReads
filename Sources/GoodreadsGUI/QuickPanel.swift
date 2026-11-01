import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Bumped each time the panel is shown, so `QuickSearchView` — whose content
/// view is created once and persists across hide/show — can refocus its
/// search field on reopen. `.onAppear` alone won't refire for that, since
/// ordering a hidden panel back in doesn't recreate its SwiftUI content.
@MainActor
final class QuickPanelFocus: ObservableObject {
    static let shared = QuickPanelFocus()
    @Published var trigger = 0
}

/// Floating search panel: hit ⌥Space anywhere, type, shelve, gone.
final class QuickPanel: NSPanel {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    convenience init(content: some View) {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if hasLiquidGlass {
            // Let the SwiftUI glass be the panel's whole surface.
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
        }
        contentView = NSHostingView(rootView: AnyView(content))
    }

    func toggle() {
        if isVisible {
            orderOut(nil)
        } else {
            centerNearTop()
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
            QuickPanelFocus.shared.trigger += 1
        }
    }

    /// Spotlight-style: horizontally centred, a third of the way down.
    private func centerNearTop() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.maxY - frame.height - visible.height * 0.18
        ))
    }
}

/// Compact search view for the panel — results, one shelf menu, nothing else.
struct QuickSearchView: View {
    @ObservedObject var model = LibraryModel.shared
    @ObservedObject private var panelFocus = QuickPanelFocus.shared
    @FocusState private var focused: Bool

    /// The highlighted result — ↑/↓ move it, ⌘1/⌘2/⌘3 shelve it. `nil` when
    /// there's nothing to highlight.
    @State private var selectedIndex: Int?
    @State private var keyMonitor: Any?

    var onEscape: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)

                TextField("Search Goodreads", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onChange(of: model.query) { _ in model.queryChanged() }
                    .onSubmit { model.searchNow() }

                if model.isSearching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if model.results.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Text("Type to search")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("⌥Space closes this too")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, book in
                            QuickRow(book: book, model: model, isSelected: index == selectedIndex)
                            Divider()
                        }
                    }
                }
            }

            if let status = model.status {
                Divider()
                Text(status.text)
                    .font(.system(size: 11))
                    .foregroundStyle(status.isError ? .orange : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else if !model.results.isEmpty {
                Divider()
                Text("↑↓ to pick · ⌘1 Want to Read · ⌘2 Currently Reading · ⌘3 Read")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
        }
        .frame(width: 560, height: 420)
        .glassPanel()
        .onExitCommand { onEscape() }
        .onAppear {
            focused = true
            installKeyMonitorIfNeeded()
        }
        .onChange(of: panelFocus.trigger) { _ in focused = true }
        .onChange(of: model.results.map(\.id)) { _ in
            selectedIndex = model.results.isEmpty ? nil : 0
        }
    }

    /// A local monitor, not `.keyboardShortcut` — the search field holds
    /// first responder the whole time this panel is open, and a plain
    /// (unmodified) arrow-key `keyboardShortcut` is not reliably delivered
    /// ahead of a focused `NSTextField`'s own arrow-key handling. A local
    /// monitor sees every key event for this app before that responder
    /// chain does, regardless of what has focus. Installed once — the
    /// panel's content view is created once and persists across hide/show
    /// (see `QuickPanelFocus`), so `onAppear` only fires the first time.
    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.keyWindow is QuickPanel else { return event }
            return handle(event) ? nil : event
        }
    }

    /// Returns `true` if this event was ours to consume.
    private func handle(_ event: NSEvent) -> Bool {
        guard !model.results.isEmpty else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch Int(event.keyCode) {
        case kVK_DownArrow where flags.isEmpty:
            let next = (selectedIndex ?? -1) + 1
            selectedIndex = min(next, model.results.count - 1)
            return true
        case kVK_UpArrow where flags.isEmpty:
            let next = (selectedIndex ?? model.results.count) - 1
            selectedIndex = max(next, 0)
            return true
        case kVK_ANSI_1 where flags == .command,
             kVK_ANSI_2 where flags == .command,
             kVK_ANSI_3 where flags == .command:
            guard let selectedIndex, model.results.indices.contains(selectedIndex) else { return false }
            let shelfIndex = Int(event.keyCode) - kVK_ANSI_1
            guard Shelf.builtIn.indices.contains(shelfIndex) else { return false }
            let book = model.results[selectedIndex]
            Task { await model.shelve(book, to: Shelf.builtIn[shelfIndex]) }
            return true
        default:
            return false
        }
    }
}

private struct QuickRow: View {
    let book: Book
    @ObservedObject var model: LibraryModel
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            cover

            VStack(alignment: .leading, spacing: 1) {
                Text(book.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(book.author)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let publisher = book.publisher {
                    Text(publisher)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if model.busyBookID == book.id {
                ProgressView().controlSize(.small)
            } else {
                ForEach(Shelf.builtIn) { shelf in
                    Button {
                        Task { await model.shelve(book, to: shelf) }
                    } label: {
                        Image(systemName: shelf.symbol)
                    }
                    .buttonStyle(.borderless)
                    .help(shelf.label)
                    .accessibilityLabel(shelf.label)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var cover: some View {
        if let url = book.coverURL {
            CachedAsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    coverPlaceholder
                }
            }
            .frame(width: 28, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            coverPlaceholder.frame(width: 28, height: 40)
        }
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.secondary.opacity(0.15))
            .overlay(Image(systemName: "book.closed").font(.system(size: 11)).foregroundStyle(.tertiary))
    }
}
