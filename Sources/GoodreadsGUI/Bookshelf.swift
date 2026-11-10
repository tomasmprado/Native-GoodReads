import SwiftUI

/// A shelf drawn as a bookcase: spines with the title and author, thicker
/// for longer books, on wooden planks. Clicking a spine pulls it out and
/// shows a little about it underneath, with a + for the full details.
/// The arrow keys move along the shelf, Return opens the book, Escape puts
/// it back. Spines take their colour from the cover.
struct BookshelfView<Actions: View>: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var spineColours = SpineColours.shared
    let items: [ShelfItem]
    /// "1/2" for a work's volumes.
    var badge: (ShelfItem) -> String? = { _ in nil }
    @ViewBuilder let actions: (ShelfItem) -> Actions

    @State private var selectedID: String?

    private var selected: ShelfItem? { items.first { $0.id == selectedID } }

    /// A work in volumes is as thick as all of them together.
    private func width(_ item: ShelfItem) -> CGFloat {
        let pages = item.volumes.compactMap { model.bookExtras[$0.bookID]?.pages }
        return Bookshelf.spineWidth(pages: pages.isEmpty ? (item.isSet ? 300 * item.volumes.count : nil) : pages.reduce(0, +))
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let widths = items.map(width)
                let rows = Bookshelf.rows(widths: widths, available: geo.size.width - 48, spacing: Bookshelf.gap)
                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(spacing: 26) {
                            ForEach(rows, id: \.lowerBound) { range in
                                shelfRow(Array(items[range]), widths: Array(widths[range]))
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                    }
                    .onChange(of: selectedID) { id in
                        if let id { withAnimation { scroller.scrollTo(id, anchor: .center) } }
                    }
                }
                .focusable()
                .noFocusRing()
                .onMoveCommand { direction in
                    let current = items.firstIndex { $0.id == selectedID }
                    if let next = Bookshelf.move(from: current, direction, rows: rows) {
                        selectedID = items[next].id
                    }
                }
                .onExitCommand { selectedID = nil }
            }
            .background {
                // Return opens the book pulled out.
                Button("") { if let item = selected { model.showBookDetail(item.volumes[0].asBook) } }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(selected == nil)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .task(id: items.count) { await spineColours.load(items.map(\.entry)) }

            if let item = selected {
                info(item)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selectedID)
    }

    private func shelfRow(_ row: [ShelfItem], widths: [CGFloat]) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: Bookshelf.gap) {
                ForEach(Array(row.enumerated()), id: \.element.id) { index, item in
                    spine(item, width: widths[index])
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            plank
        }
    }

    private var plank: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.38, blue: 0.24),
                                          Color(red: 0.38, green: 0.25, blue: 0.15)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(height: 10)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 3)
    }

    private func spine(_ item: ShelfItem, width: CGFloat) -> some View {
        let entry = item.entry
        let height = Bookshelf.spineHeight(entry.bookID)
        let style = Bookshelf.style(entry.bookID, cover: spineColours.colour(entry.bookID))
        let isSelected = entry.id == selectedID
        return ZStack {
            RoundedRectangle(cornerRadius: 2.5).fill(style.background)
            // A little roundness, like a real spine catching the light.
            LinearGradient(stops: [.init(color: .black.opacity(0.22), location: 0),
                                   .init(color: .white.opacity(0.10), location: 0.35),
                                   .init(color: .black.opacity(0.28), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .clipShape(RoundedRectangle(cornerRadius: 2.5))
            VStack {
                Rectangle().fill(style.foreground.opacity(0.45)).frame(height: 1.5).padding(.top, 9)
                Spacer()
                Rectangle().fill(style.foreground.opacity(0.45)).frame(height: 1.5).padding(.bottom, 9)
            }
            // Read top to bottom, as spines are printed here.
            HStack(spacing: 8) {
                Text(entry.title)
                    .font(.system(size: width < 28 ? 9.5 : 10.5, weight: .semibold, design: .serif))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Text(Bookshelf.surname(entry.author))
                    .font(.system(size: 9, weight: .regular))
                    .lineLimit(1)
                    .opacity(0.85)
            }
            .foregroundStyle(style.foreground)
            .padding(.horizontal, 16)
            .frame(width: height, height: width)
            .rotationEffect(.degrees(90))
            .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        .overlay(RoundedRectangle(cornerRadius: 2.5)
            .stroke(Color.accentColor, lineWidth: isSelected ? 2 : 0))
        .shadow(color: .black.opacity(isSelected ? 0.35 : 0.15), radius: isSelected ? 5 : 1, x: 1, y: 1)
        .offset(y: isSelected ? -12 : 0)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.showBookDetail(item.volumes[0].asBook) }
        .onTapGesture { selectedID = isSelected ? nil : entry.id }
        .contextMenu { actions(item) }
        .draggable(LibraryModel.dragPrefix + entry.id) {
            Label(entry.title, systemImage: "book.closed").padding(6)
        }
        .id(item.id)
        .help("\(entry.title) — \(entry.author)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(entry.title), \(entry.author)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// A small card about the book pulled out, with + for the full details.
    private func info(_ item: ShelfItem) -> some View {
        let entry = item.entry
        return HStack(spacing: 12) {
            CachedAsyncImage(url: entry.coverURL) { phase in
                if case .success(let image) = phase { image.resizable().aspectRatio(contentMode: .fill) }
                else { RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)) }
            }
            .frame(width: 34, height: 51)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).appFont(size: 13, weight: .semibold).lineLimit(1)
                Text(entry.author).appFont(size: 11).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    if let rating = entry.rating, rating > 0 {
                        Text(String(repeating: "★", count: rating)).foregroundStyle(.orange)
                    }
                    ForEach(details(item), id: \.self) { Text($0) }
                }
                .appFont(size: 10)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let badge = badge(item) {
                Text(badge)
                    .appFont(size: 13, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Volumes read, of the volumes on your shelves")
            }
            Button { model.showBookDetail(item.volumes[0].asBook) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassCircle(tint: .accentColor)
            .help("View Details")
            .accessibilityLabel(Text("View Details"))
        }
        .padding(10)
        .glassCard(cornerRadius: 14)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .padding(.top, 4)
        .frame(maxWidth: 560)
    }

    private func details(_ item: ShelfItem) -> [String] {
        let entry = item.entry
        var bits: [String] = []
        let pages = item.volumes.compactMap { model.bookExtras[$0.bookID]?.pages }
        if item.isSet { bits.append(String(localized: "\(item.volumes.count) volumes")) }
        if !pages.isEmpty { bits.append(String(localized: "\(pages.reduce(0, +)) pages")) }
        if let date = entry.dateRead, !date.isEmpty { bits.append(String(localized: "read \(date)")) }
        else if let date = entry.dateAdded, !date.isEmpty { bits.append(String(localized: "added \(date)")) }
        return bits
    }
}

/// The sums behind the bookcase.
enum Bookshelf {
    static let gap: CGFloat = 3

    /// Thicker for longer books; a middling width when the length isn't known.
    static func spineWidth(pages: Int?) -> CGFloat {
        let pages = CGFloat(pages ?? 300)
        return min(54, max(24, 16 + pages / 18))
    }

    /// Books aren't all the same height; each one keeps its own.
    static func spineHeight(_ bookID: String) -> CGFloat {
        150 + CGFloat(hash(bookID) % 36)
    }

    /// Spines split into rows that fit `available`, in order.
    static func rows(widths: [CGFloat], available: CGFloat, spacing: CGFloat) -> [Range<Int>] {
        var rows: [Range<Int>] = []
        var start = 0
        var used: CGFloat = 0
        for (index, width) in widths.enumerated() {
            let needed = index == start ? width : used + spacing + width
            if needed > max(available, width), index > start {
                rows.append(start..<index)
                start = index
                used = width
            } else {
                used = needed
            }
        }
        if start < widths.count { rows.append(start..<widths.count) }
        return rows
    }

    /// The last name, which is what fits on a spine.
    static func surname(_ author: String) -> String {
        let parts = author.split(separator: " ")
        guard parts.count > 1 else { return author }
        let particles: Set<String> = ["de", "da", "do", "dos", "das", "van", "von", "del", "di", "le", "la"]
        var name = [String(parts.last!)]
        var index = parts.count - 2
        while index > 0, particles.contains(parts[index].lowercased()) {
            name.insert(String(parts[index]), at: 0)
            index -= 1
        }
        return name.joined(separator: " ")
    }

    struct Style {
        let background: Color
        let foreground: Color
    }

    /// The cover's own colour when it's known, with lettering that reads on it.
    static func style(_ bookID: String, cover: RGB?) -> Style {
        guard let cover else { return style(bookID) }
        return Style(background: cover.color,
                     foreground: cover.luminance > 0.55 ? Color(white: 0.12) : Color(white: 0.96))
    }

    /// Where the arrow keys go: along the shelf for ← →, to the row above
    /// or below (nearest place in it) for ↑ ↓. Nothing chosen yet starts
    /// at the first book.
    static func move(from index: Int?, _ direction: MoveCommandDirection, rows: [Range<Int>]) -> Int? {
        guard let total = rows.last?.upperBound, total > 0 else { return nil }
        guard let index else { return 0 }
        switch direction {
        case .left:  return max(0, index - 1)
        case .right: return min(total - 1, index + 1)
        case .up, .down:
            guard let row = rows.firstIndex(where: { $0.contains(index) }) else { return index }
            let target = direction == .up ? row - 1 : row + 1
            guard rows.indices.contains(target) else { return index }
            let place = index - rows[row].lowerBound
            return min(rows[target].upperBound - 1, rows[target].lowerBound + place)
        @unknown default: return index
        }
    }

    /// Cloth and leather colours, one per book, the same every time.
    static func style(_ bookID: String) -> Style {
        let palette: [(Double, Double, Double, Bool)] = [   // r, g, b, light text
            (0.47, 0.13, 0.15, true), (0.13, 0.25, 0.42, true), (0.16, 0.35, 0.27, true),
            (0.85, 0.78, 0.62, false), (0.24, 0.22, 0.25, true), (0.62, 0.36, 0.18, true),
            (0.80, 0.65, 0.30, false), (0.36, 0.20, 0.38, true), (0.88, 0.86, 0.80, false),
            (0.20, 0.42, 0.48, true), (0.66, 0.24, 0.22, true), (0.45, 0.50, 0.32, true),
        ]
        let pick = palette[Int(hash(bookID + "colour") % UInt64(palette.count))]
        let background = Color(red: pick.0, green: pick.1, blue: pick.2)
        return Style(background: background,
                     foreground: pick.3 ? Color(white: 0.96) : Color(white: 0.15))
    }

    /// FNV-1a, so a book keeps its look across launches.
    static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
        return value
    }
}

private extension View {
    /// No blue ring around the whole bookcase when it has the keyboard.
    @ViewBuilder
    func noFocusRing() -> some View {
        if #available(macOS 14, *) { focusEffectDisabled() } else { self }
    }
}
