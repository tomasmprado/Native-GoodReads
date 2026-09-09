import SwiftUI

/// Google Books' metadata plus Goodreads' community reviews for one book, with
/// the ability to post your own rating and review — which, like every other
/// rating action in this app, also moves the book to your Read shelf.
struct BookDetailView: View {
    let book: Book

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = LibraryModel.shared

    @State private var goodreadsID: String?
    @State private var resolveError: String?

    @State private var reviews: [GoodreadsBookPage.Review] = []
    @State private var pageLanguage: String?
    @State private var authorURL: URL?
    @State private var isLoadingReviews = false
    @State private var reviewsError: String?

    @State private var rating = 0
    @State private var reviewText = ""
    @State private var isPosting = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Book Details")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let description = book.description, !description.isEmpty {
                        Text(plainDescription(description))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    composeBox
                    Divider()
                    reviewsSection
                }
                .padding(16)
            }
        }
        .frame(width: 700, height: 680)
        .task { await resolveAndLoad() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let url = book.coverURL {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fit)
                        } else {
                            coverPlaceholder
                        }
                    }
                } else {
                    coverPlaceholder
                }
            }
            .frame(width: 110, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.system(size: 17, weight: .semibold))
                if let authorURL {
                    Button(book.author) { model.showAuthorPage(authorURL) }
                        .font(.system(size: 13))
                        .buttonStyle(.link)
                } else {
                    Text(book.author)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    ForEach(metaBits, id: \.self) { bit in
                        Text(bit)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)

                if let rating = book.rating {
                    Text("Google rating: ★ \(rating)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if let resolveError {
                    Text(resolveError)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else if goodreadsID == nil {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Finding this book on Goodreads…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
    }

    private var metaBits: [String] {
        var bits: [String] = []
        if let publisher = book.publisher { bits.append(publisher) }
        if let date = book.publishedDate { bits.append(date) }
        if let pages = book.pageCount { bits.append("\(pages) pages") }
        if let language = pageLanguage ?? book.language { bits.append(language.capitalized) }
        return bits
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.secondary.opacity(0.15))
            .overlay(Image(systemName: "book.closed").font(.system(size: 24)).foregroundStyle(.tertiary))
    }

    // MARK: - Compose

    private var composeBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your rating")
                .font(.system(size: 12, weight: .semibold))

            StarPicker(rating: $rating)

            TextField("Review (optional)", text: $reviewText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            HStack {
                Spacer()
                if isPosting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Post") { Task { await post() } }
                        .disabled(rating == 0 || goodreadsID == nil)
                }
            }
        }
    }

    private func post() async {
        guard let goodreadsID else { return }
        isPosting = true
        defer { isPosting = false }

        await model.finish(bookID: goodreadsID, title: book.title,
                           rating: rating, dateRead: Date(), note: reviewText)
        reviewText = ""
        await loadReviews(bookID: goodreadsID)
    }

    // MARK: - Reviews

    private var reviewsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Goodreads Reviews")
                    .font(.system(size: 12, weight: .semibold))
                if isLoadingReviews {
                    ProgressView().controlSize(.small)
                }
            }

            if let reviewsError {
                Text(reviewsError)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if reviews.isEmpty && !isLoadingReviews {
                Text("No reviews to show yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(reviews) { review in
                        ReviewRow(review: review)
                    }
                }
            }
        }
    }

    // MARK: - Loading

    private func resolveAndLoad() async {
        do {
            let id = try await GoodreadsLookup.bookID(for: book)
            goodreadsID = id
            await loadReviews(bookID: id)
        } catch {
            resolveError = "Couldn't find this book on Goodreads."
        }
    }

    private func loadReviews(bookID: String) async {
        isLoadingReviews = true
        defer { isLoadingReviews = false }

        do {
            let detail = try await GoodreadsBookPage.fetch(bookID: bookID)
            reviews = detail.reviews
            pageLanguage = detail.language
            authorURL = detail.authorURL
            reviewsError = nil
        } catch {
            reviewsError = "Couldn't load reviews: \(error.localizedDescription)"
        }
    }

    private func plainDescription(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}

private struct ReviewRow: View {
    let review: GoodreadsBookPage.Review

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: review.reviewerAvatarURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Circle().fill(Color.secondary.opacity(0.2))
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(review.reviewerName)
                        .font(.system(size: 12, weight: .medium))
                    if let rating = review.rating {
                        Text(String(repeating: "★", count: rating))
                            .font(.system(size: 11))
                            .foregroundStyle(.yellow)
                    }
                }
                Text(review.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
                if let likes = review.likeCount, likes > 0 {
                    Text("\(likes) like\(likes == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
