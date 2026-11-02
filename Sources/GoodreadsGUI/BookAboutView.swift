import SwiftUI

/// Book Details' "About" part: Goodreads' rating, the synopsis, genres, and
/// the edition's facts — publisher, dates, pages, ISBN, awards.
struct BookAboutView: View {
    let about: GoodreadsBookPage.About?
    let genres: [String]
    /// Google Books' copy, for books whose Goodreads page has none.
    let book: Book
    let pages: Int?
    let language: String?

    @State private var synopsisExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let about, let average = about.averageRating, average > 0 {
                ratingSummary(average: average, about: about)
            }
            if let synopsis {
                synopsisBlock(synopsis)
            }
            if !genres.isEmpty {
                genreChips
            }
            if !facts.isEmpty {
                factsGrid
            }
            if let awards = about?.awards, !awards.isEmpty {
                listBlock(String(localized: "Awards"), awards.prefix(8).map(awardLine))
            }
            if let characters = about?.characters, !characters.isEmpty {
                listBlock(String(localized: "Characters"), [characters.prefix(12).joined(separator: ", ")])
            }
            if let places = about?.places, !places.isEmpty {
                listBlock(String(localized: "Setting"), [places.prefix(8).joined(separator: ", ")])
            }
        }
    }

    // MARK: Rating

    private func ratingSummary(average: Double, about: GoodreadsBookPage.About) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.2f", average))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("★").font(.system(size: 18)).foregroundStyle(.orange)
                }
                Text(countsLine(about))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            if let byStars = about.ratingsByStars, let most = byStars.max(), most > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach((0..<5).reversed(), id: \.self) { index in
                        HStack(spacing: 6) {
                            Text("\(index + 1)★")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .trailing)
                            GeometryReader { proxy in
                                Capsule().fill(Color.secondary.opacity(0.15))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Color.orange)
                                            .frame(width: proxy.size.width * CGFloat(byStars[index]) / CGFloat(most))
                                    }
                            }
                            .frame(height: 5)
                        }
                    }
                }
                .frame(maxWidth: 220)
                .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
    }

    private func countsLine(_ about: GoodreadsBookPage.About) -> String {
        var bits: [String] = []
        if let ratings = about.ratingsCount { bits.append(String(localized: "\(ratings) ratings")) }
        if let reviews = about.reviewsCount { bits.append(String(localized: "\(reviews) reviews")) }
        return bits.isEmpty ? String(localized: "Goodreads average") : bits.joined(separator: " · ")
    }

    // MARK: Synopsis

    private var synopsis: String? {
        if let text = about?.synopsis, !text.isEmpty { return text }
        guard let description = book.description, !description.isEmpty else { return nil }
        return GoodreadsBookPage.plainText(fromHTML: description)
    }

    private func synopsisBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Synopsis")
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(synopsisExpanded ? nil : 6)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if text.count > 420 {
                Button(synopsisExpanded ? String(localized: "Show Less") : String(localized: "Show More")) {
                    withAnimation(.easeInOut(duration: 0.15)) { synopsisExpanded.toggle() }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
    }

    // MARK: Genres

    private var genreChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(genres.prefix(10), id: \.self) { genre in
                    Text(genre)
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Genres: \(genres.prefix(10).joined(separator: ", "))"))
    }

    // MARK: Facts

    private var facts: [(String, String)] {
        var rows: [(String, String)] = []
        let publisher = about?.publisher ?? book.publisher
        if let publisher { rows.append((String(localized: "Publisher"), publisher)) }
        if let published = about?.published {
            rows.append((String(localized: "Published"), published.formatted(date: .long, time: .omitted)))
        } else if let date = book.publishedDate {
            rows.append((String(localized: "Published"), date))
        }
        if let first = about?.firstPublished {
            rows.append((String(localized: "First published"), first.formatted(.dateTime.year())))
        }
        if let pages = pages ?? book.pageCount {
            rows.append((String(localized: "Pages"), "\(pages)"))
        }
        if let format = about?.format { rows.append((String(localized: "Format"), format)) }
        if let language = language ?? book.language { rows.append((String(localized: "Language"), language.capitalized)) }
        if let isbn = about?.isbn13 ?? about?.isbn ?? book.isbn { rows.append((String(localized: "ISBN"), isbn)) }
        if let original = about?.originalTitle { rows.append((String(localized: "Original title"), original)) }
        for (role, people) in contributorsByRole {
            rows.append((role, people.joined(separator: ", ")))
        }
        return rows
    }

    /// "Illustrator: A, B" — Goodreads lists one edge per person.
    private var contributorsByRole: [(String, [String])] {
        var order: [String] = []
        var byRole: [String: [String]] = [:]
        for contributor in about?.contributors ?? [] {
            // Goodreads' role names are English; the common ones are translated.
            let role = contributor.role.isEmpty
                ? String(localized: "Contributor")
                : Bundle.main.localizedString(forKey: contributor.role, value: contributor.role, table: nil)
            if byRole[role] == nil { order.append(role) }
            byRole[role, default: []].append(contributor.name)
        }
        return order.map { ($0, byRole[$0] ?? []) }
    }

    private var factsGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Details")
                .font(.system(size: 12, weight: .semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(facts, id: \.0) { label, value in
                    GridRow {
                        Text(label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(value)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Lists

    private func awardLine(_ award: GoodreadsBookPage.Award) -> String {
        var line = award.name
        if let year = award.year { line += " (\(year))" }
        if !award.won { line += String(localized: " — nominee") }
        return line
    }

    private func listBlock(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
