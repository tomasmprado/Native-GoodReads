import AppKit
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
                        ForEach(model.results) { book in
                            QuickRow(book: book, model: model)
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
            }
        }
        .frame(width: 560, height: 420)
        .background(.regularMaterial)
        .onExitCommand { onEscape() }
        .onAppear { focused = true }
        .onChange(of: panelFocus.trigger) { _ in focused = true }
    }
}

private struct QuickRow: View {
    let book: Book
    @ObservedObject var model: LibraryModel

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
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var cover: some View {
        if let url = book.coverURL {
            AsyncImage(url: url) { phase in
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
