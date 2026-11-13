import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One year of reading, summed up — for the "Your Year in Books" card.
struct YearSummary: Equatable {
    let year: Int
    let books: Int
    /// Pages of the books whose page count is known.
    let pages: Int
    let averageRating: Double?
    let topGenre: String?
    let topAuthor: String?
    /// Index 0 = January.
    let busiestMonth: Int?
    let longest: ShelfEntry?
    let longestPages: Int?
    /// Your highest-rated books that year, up to six.
    let favourites: [ShelfEntry]

    static func compute(read: [ShelfEntry], extras: [String: BookExtras], year: Int,
                        calendar: Calendar = .current) -> YearSummary {
        let entries = read.filter { entry in
            Suggestions.parseDate(entry.dateRead ?? "").map { calendar.component(.year, from: $0) } == year
        }

        var pages = 0
        var longest: (ShelfEntry, Int)?
        var genres: [String: Int] = [:]
        var authors: [String: Int] = [:]
        var months = Array(repeating: 0, count: 12)
        for entry in entries {
            if let count = extras[entry.bookID]?.pages {
                pages += count
                if count > (longest?.1 ?? 0) { longest = (entry, count) }
            }
            for genre in (extras[entry.bookID]?.genres ?? []).filter({ !ReadingStats.ignoredGenres.contains($0) }).prefix(3) {
                genres[genre, default: 0] += 1
            }
            if !entry.author.isEmpty { authors[entry.author, default: 0] += 1 }
            if let date = Suggestions.parseDate(entry.dateRead ?? "") {
                months[calendar.component(.month, from: date) - 1] += 1
            }
        }

        let ratings = entries.compactMap(\.rating).filter { $0 > 0 }
        func top(_ tally: [String: Int]) -> String? {
            tally.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        }
        let busiest = months.max() ?? 0

        return YearSummary(
            year: year,
            books: entries.count,
            pages: pages,
            averageRating: ratings.isEmpty ? nil : Double(ratings.reduce(0, +)) / Double(ratings.count),
            topGenre: top(genres),
            topAuthor: authors.values.max() ?? 0 >= 2 ? top(authors) : nil,
            busiestMonth: busiest > 0 ? months.firstIndex(of: busiest) : nil,
            longest: longest?.0,
            longestPages: longest?.1,
            favourites: Array(entries.filter { ($0.rating ?? 0) >= 4 }
                .sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
                .prefix(6))
        )
    }

    /// Years with at least one book read, newest first.
    static func years(in read: [ShelfEntry], calendar: Calendar = .current) -> [Int] {
        ShelfFilters.years(in: read, calendar: calendar)
    }
}

/// The sheet: pick a year, see the card, save it as an image.
struct YearInReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var read: [ShelfEntry] = []
    @State private var extras: [String: BookExtras] = [:]
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var covers: [URL: NSImage] = [:]
    @State private var savedMessage: String?

    private var summary: YearSummary {
        YearSummary.compute(read: read, extras: extras, year: year)
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassHeader {
                Text("Your Year in Books")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                let years = YearSummary.years(in: read)
                if !years.isEmpty {
                    Picker("Year", selection: $year) {
                        ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .glassButton()
            }

            ScrollView {
                YearCard(summary: summary, covers: covers)
                    .padding(20)
            }

            HStack {
                if let savedMessage {
                    Text(savedMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save Image…", action: saveImage)
                    .keyboardShortcut(.defaultAction)
                    .glassProminentButton()
                    .disabled(summary.books == 0)
            }
            .padding(12)
        }
        .frame(width: 600, height: 720)
        .task {
            read = ShelfCache.read(.read)?.entries ?? []
            extras = await BookExtras.all()
            if let latest = YearSummary.years(in: read).first, latest < year,
               summary.books == 0 { year = latest }
        }
        .task(id: year) {
            // The saved image can't wait for covers to stream in, so they're
            // all loaded up front.
            for entry in summary.favourites {
                guard let url = entry.coverURL, covers[url] == nil else { continue }
                if let image = await ImageMemoryCache.shared.load(url) { covers[url] = image }
            }
        }
    }

    private func saveImage() {
        let renderer = ImageRenderer(content: YearCard(summary: summary, covers: covers).frame(width: 560))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            savedMessage = String(localized: "Couldn’t make the image.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "my-\(summary.year)-in-books.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
            savedMessage = String(localized: "Saved \(url.lastPathComponent).")
        } catch {
            savedMessage = error.localizedDescription
        }
    }
}

/// The card itself — fixed colours, so the saved image looks the same in
/// light and dark mode.
struct YearCard: View {
    let summary: YearSummary
    let covers: [URL: NSImage]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: String(summary.year))
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                Text("My Year in Books")
                    .font(.system(size: 16, weight: .medium))
                    .opacity(0.8)
            }

            if summary.books == 0 {
                Text("No books marked read this year yet.")
                    .opacity(0.8)
            } else {
                HStack(spacing: 12) {
                    big("\(summary.books)", String(localized: "books"))
                    if summary.pages > 0 { big(summary.pages.formatted(), String(localized: "pages")) }
                    if let average = summary.averageRating {
                        big(String(format: "%.1f★", average), String(localized: "average"))
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let genre = summary.topGenre { fact("sparkles", String(localized: "Most read genre: \(GenreNames.display(genre))")) }
                    if let author = summary.topAuthor { fact("person", String(localized: "Favourite author: \(author)")) }
                    if let month = summary.busiestMonth {
                        fact("calendar", String(localized: "Busiest month: \(Calendar.current.monthSymbols[month])"))
                    }
                    if let longest = summary.longest, let pages = summary.longestPages {
                        fact("text.book.closed", String(localized: "Longest: \(longest.title) (\(pages) pages)"))
                    }
                }

                if !summary.favourites.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Favourites")
                            .font(.system(size: 13, weight: .semibold))
                            .opacity(0.8)
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(summary.favourites) { entry in
                                cover(entry)
                            }
                        }
                    }
                }
            }

            Text("OpenShelf for Mac")
                .font(.system(size: 10))
                .opacity(0.5)
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 0.36, green: 0.22, blue: 0.13),
                                    Color(red: 0.62, green: 0.39, blue: 0.20)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private func big(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 28, weight: .bold, design: .rounded))
            Text(label).font(.system(size: 11)).opacity(0.75)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.12)))
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 13))
            .lineLimit(1)
    }

    private func cover(_ entry: ShelfEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
                if let url = entry.coverURL, let image = covers[url] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.15))
                        .overlay(Image(systemName: "book.closed").opacity(0.6))
                }
            }
            .frame(width: 70, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(String(repeating: "★", count: entry.rating ?? 0))
                .font(.system(size: 9))
                .foregroundStyle(.yellow)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(entry.title))
    }
}
