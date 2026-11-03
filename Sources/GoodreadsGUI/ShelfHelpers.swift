import SwiftUI

/// "Pick for Me" on Want to Read: one book at a time from what's showing
/// (so filters and smart lists narrow it), to start or skip.
struct PickForMeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: LibraryModel
    let candidates: [ShelfEntry]
    @State private var pick: ShelfEntry?
    @State private var seen: Set<String> = []

    var body: some View {
        VStack(spacing: 16) {
            Text("Pick for Me").appFont(size: 15, weight: .semibold)
            if let pick {
                CachedAsyncImage(url: pick.coverURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                            .overlay(Image(systemName: "book.closed").foregroundStyle(.tertiary))
                    }
                }
                .frame(width: 130, height: 196)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(radius: 8, y: 4)
                .id(pick.id)
                .transition(.scale.combined(with: .opacity))
                VStack(spacing: 3) {
                    Text(pick.title).appFont(size: 15, weight: .semibold).multilineTextAlignment(.center)
                    Text(pick.author).appFont(size: 12).foregroundStyle(.secondary)
                    Text(detail(pick)).appFont(size: 11).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Another") { next() }
                        .keyboardShortcut(.space, modifiers: [])
                        .disabled(candidates.count < 2)
                    Button("Details") { model.showBookDetail(pick.asBook) }
                    Button("Start Reading") {
                        Task { await model.move(pick, to: .currentlyReading) }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Nothing on this shelf to pick from.").foregroundStyle(.secondary)
            }
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.link)
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { next() }
    }

    private func detail(_ entry: ShelfEntry) -> String {
        var bits: [String] = []
        if let pages = model.bookExtras[entry.bookID]?.pages { bits.append(String(localized: "\(pages) pages")) }
        if let rating = model.bookExtras[entry.bookID]?.rating { bits.append(String(format: "%.2f ★", rating)) }
        if let added = entry.dateAdded, !added.isEmpty { bits.append(String(localized: "added \(added)")) }
        return bits.joined(separator: " · ")
    }

    private func next() {
        var pool = candidates.filter { !seen.contains($0.id) }
        if pool.isEmpty { seen = []; pool = candidates }
        guard let choice = pool.randomElement() else { return }
        seen.insert(choice.id)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { pick = choice }
    }
}

/// "Rate Unrated" on Read: your unrated books one at a time — 1 to 5 to
/// rate, S to skip.
struct QuickRateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: LibraryModel
    @State private var queue: [ShelfEntry]
    @State private var rated = 0

    init(model: LibraryModel, unrated: [ShelfEntry]) {
        self.model = model
        _queue = State(initialValue: unrated)
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Rate Unrated Books").appFont(size: 15, weight: .semibold)
                Spacer()
                Text("\(queue.count) left").appFont(size: 11).foregroundStyle(.secondary)
            }
            if let entry = queue.first {
                CachedAsyncImage(url: entry.coverURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                    }
                }
                .frame(width: 120, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .id(entry.id)
                .transition(.push(from: .trailing))
                VStack(spacing: 2) {
                    Text(entry.title).appFont(size: 14, weight: .semibold).multilineTextAlignment(.center).lineLimit(2)
                    Text(entry.author).appFont(size: 12).foregroundStyle(.secondary)
                    if let date = entry.dateRead, !date.isEmpty {
                        Text(String(localized: "read \(date)")).appFont(size: 11).foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 8) {
                    ForEach(1...5, id: \.self) { stars in
                        Button {
                            rate(entry, stars)
                        } label: {
                            Text(String(repeating: "★", count: stars)).appFont(size: 12)
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(stars)")), modifiers: [])
                        .help(StarPicker.phrase(stars))
                    }
                }
                HStack {
                    Button("Skip") { skip() }.keyboardShortcut("s", modifiers: [])
                    Text("Press 1–5 to rate, S to skip.").appFont(size: 10).foregroundStyle(.tertiary)
                }
            } else {
                Image(systemName: "checkmark.seal.fill").appFont(size: 40).foregroundStyle(.green)
                Text(rated > 0 ? String(localized: "Rated \(rated) books. All done!") : String(localized: "Every book on Read has a rating."))
                    .foregroundStyle(.secondary)
            }
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.link)
        }
        .padding(22)
        .frame(width: 400)
    }

    private func rate(_ entry: ShelfEntry, _ stars: Int) {
        Task { await model.rate(entry, stars: stars) }
        rated += 1
        withAnimation(.easeInOut(duration: 0.25)) { _ = queue.removeFirst() }
    }

    private func skip() {
        guard !queue.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.25)) { queue.append(queue.removeFirst()) }
    }
}
