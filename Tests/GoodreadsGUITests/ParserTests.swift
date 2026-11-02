import XCTest
@testable import GoodreadsGUI

/// The app reads Goodreads pages it doesn't control, so these pin down the
/// shapes it depends on. When Goodreads changes one, the matching test here
/// is what should be updated first.

/// A cut-down book page with the same structure as a real one (checked
/// against /book/show/5907 on 2026-11-01): a JSON-LD block, and Next.js'
/// `__NEXT_DATA__` holding the Apollo cache.
private let bookPageFixture = #"""
<!DOCTYPE html><html><head>
<script type="application/ld+json">{"@context":"https://schema.org","@type":"Book","name":"The Hobbit","author":[{"@type":"Person","name":"J.R.R. Tolkien","url":"https://www.goodreads.com/author/show/656983.J_R_R_Tolkien"}]}</script>
</head><body>
<script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"apolloState":{
"ROOT_QUERY":{"__typename":"Query","getReviews({\"filters\":{\"resourceType\":\"WORK\"}})":{"__typename":"BookReviewsConnection","edges":[{"__typename":"BookReviewsEdge","node":{"__ref":"Review:kca://review/1"}},{"__typename":"BookReviewsEdge","node":{"__ref":"Review:kca://review/2"}}]}},
"Book:kca://book/main":{"__typename":"Book","legacyId":5907,"title":"The Hobbit","titleComplete":"The Hobbit, or There and Back Again","description":"In a hole in the ground there lived a hobbit.<br /><br />Written for <i>his</i> children &amp; others.","primaryContributorEdge":{"__typename":"BookContributorEdge","node":{"__ref":"Contributor:kca://author/1"},"role":"Author"},"secondaryContributorEdges":[{"__typename":"BookContributorEdge","node":{"__ref":"Contributor:kca://author/2"},"role":"Illustrator"},{"__typename":"BookContributorEdge","node":{"__ref":"Contributor:kca://author/3"},"role":"Illustrator"}],"work":{"__ref":"Work:kca://work/1"},"details":{"__typename":"BookDetails","format":"Paperback","numPages":366,"publicationTime":1029394800000,"publisher":"Houghton Mifflin","isbn":null,"isbn13":"9780618260300","language":{"__typename":"Language","name":"English"}},"bookGenres":[{"__typename":"BookGenre","genre":{"__typename":"Genre","name":"Fantasy"}},{"__typename":"BookGenre","genre":{"__typename":"Genre","name":"Classics"}},{"__typename":"BookGenre","genre":{"__typename":"Genre","name":"Fiction"}}]},
"Contributor:kca://author/1":{"__typename":"Contributor","name":"J.R.R. Tolkien"},
"Contributor:kca://author/2":{"__typename":"Contributor","name":"Michael Hague"},
"Contributor:kca://author/3":{"__typename":"Contributor","name":"Jemima Catlin"},
"Work:kca://work/1":{"__typename":"Work","details":{"__typename":"WorkDetails","publicationTime":-1018627200000,"originalTitle":"The Hobbit, or There and Back Again","awardsWon":[{"__typename":"Award","name":"Keith Barker Millennium Book Award","awardedAt":946713600000,"designation":"WINNER"},{"__typename":"Award","name":"Some Prize","awardedAt":null,"designation":"NOMINEE"}],"places":[{"__typename":"Places","name":"Middle Earth"}],"characters":[{"__typename":"Character","name":"Gandalf"},{"__typename":"Character","name":"Bilbo Baggins"}]},"stats":{"__typename":"BookOrWorkStats","averageRating":4.3,"ratingsCount":4662271,"ratingsCountDist":[94991,146539,547627,1344330,2528784],"textReviewsCount":96202}},
"Book:kca://book/other":{"__typename":"Book","legacyId":99,"details":{"numPages":10,"language":{"name":"French"}},"bookGenres":[]},
"User:kca://user/1":{"__typename":"User","name":"Ana","imageUrlSquare":"https://images.example.com/ana.jpg"},
"Review:kca://review/1":{"__typename":"Review","id":"kca://review/1","creator":{"__ref":"User:kca://user/1"},"rating":5,"text":"Loved it.<br />Truly &amp; fully.","likeCount":3},
"Review:kca://review/2":{"__typename":"Review","id":"kca://review/2","rating":0,"text":"<b>Hmm</b>"}
}}}}</script>
</body></html>
"""#

final class BookPageParserTests: XCTestCase {

    func testReadsWhatBookDetailsShows() throws {
        let about = try XCTUnwrap(GoodreadsBookPage.parse(html: bookPageFixture, bookID: "5907").about)
        XCTAssertEqual(about.title, "The Hobbit, or There and Back Again")
        XCTAssertEqual(about.authorName, "J.R.R. Tolkien")
        XCTAssertEqual(about.synopsis, "In a hole in the ground there lived a hobbit.\n\nWritten for his children & others.")
        XCTAssertEqual(about.publisher, "Houghton Mifflin")
        XCTAssertEqual(about.format, "Paperback")
        XCTAssertEqual(about.isbn13, "9780618260300")
        XCTAssertNil(about.isbn)
        XCTAssertEqual(about.published.map { Calendar(identifier: .gregorian).component(.year, from: $0) }, 2002)
        XCTAssertEqual(about.firstPublished.map { Calendar(identifier: .gregorian).component(.year, from: $0) }, 1937)
        XCTAssertNil(about.originalTitle, "the same as the title, so not repeated")
        XCTAssertEqual(about.averageRating, 4.3)
        XCTAssertEqual(about.ratingsCount, 4662271)
        XCTAssertEqual(about.ratingsByStars?.last, 2528784)
        XCTAssertEqual(about.reviewsCount, 96202)
        XCTAssertEqual(about.contributors, [.init(name: "Michael Hague", role: "Illustrator"),
                                            .init(name: "Jemima Catlin", role: "Illustrator")])
        XCTAssertEqual(about.awards, [.init(name: "Keith Barker Millennium Book Award", year: 2000, won: true),
                                      .init(name: "Some Prize", year: nil, won: false)])
        XCTAssertEqual(about.characters, ["Gandalf", "Bilbo Baggins"])
        XCTAssertEqual(about.places, ["Middle Earth"])
    }

    func testReadsTheBooksOwnDetails() throws {
        let detail = try GoodreadsBookPage.parse(html: bookPageFixture, bookID: "5907")
        XCTAssertEqual(detail.language, "english")
        XCTAssertEqual(detail.pageCount, 366)
        XCTAssertEqual(detail.genres, ["Fantasy", "Classics", "Fiction"])
        XCTAssertEqual(detail.authorURL?.absoluteString,
                       "https://www.goodreads.com/author/show/656983.J_R_R_Tolkien")
    }

    func testPicksTheRightBookOutOfSeveral() throws {
        let other = try GoodreadsBookPage.parse(html: bookPageFixture, bookID: "99")
        XCTAssertEqual(other.language, "french")
        XCTAssertEqual(other.pageCount, 10)
        XCTAssertEqual(other.genres, [])
    }

    func testReadsReviewsInOrder() throws {
        let reviews = try GoodreadsBookPage.parse(html: bookPageFixture, bookID: "5907").reviews
        XCTAssertEqual(reviews.map(\.id), ["kca://review/1", "kca://review/2"])
        XCTAssertEqual(reviews[0].reviewerName, "Ana")
        XCTAssertEqual(reviews[0].rating, 5)
        XCTAssertEqual(reviews[0].likeCount, 3)
        XCTAssertEqual(reviews[0].text, "Loved it.\nTruly & fully.")
        XCTAssertNil(reviews[1].rating, "0 means unrated")
        XCTAssertEqual(reviews[1].text, "Hmm")
    }

    func testPageWithoutNextDataThrows() {
        XCTAssertThrowsError(try GoodreadsBookPage.parse(html: "<html><body>Sign in</body></html>", bookID: "1"))
    }

    func testUnknownBookStillReturnsReviews() throws {
        let detail = try GoodreadsBookPage.parse(html: bookPageFixture, bookID: "12345")
        XCTAssertNil(detail.pageCount)
        XCTAssertNil(detail.language)
        XCTAssertEqual(detail.reviews.count, 2)
    }
}

final class ShelfEnvelopeTests: XCTestCase {

    func testDecodesRowsAndDropsDuplicates() throws {
        let raw = """
        {"ok":true,"pages":3,"rows":[
          {"bookId":"1","reviewId":"r1","title":"A","author":"X","cover":"https://c/1.jpg","rating":4,
           "dateRead":"Mar 3, 2025","dateAdded":"","isbn":"","isbn13":"9780000000001"},
          {"bookId":"1","reviewId":"r1","title":"A","author":"X"},
          {"bookId":"","title":"broken","author":""},
          {"bookId":"2","title":"B","author":"Y"}
        ]}
        """
        let envelope = try ShelfLibrary.decodeEnvelope(raw)
        XCTAssertTrue(envelope.ok)
        XCTAssertEqual(envelope.pages, 3)

        let entries = ShelfLibrary.entries(from: envelope.rows ?? [])
        XCTAssertEqual(entries.map(\.bookID), ["1", "2"])
        XCTAssertEqual(entries[0].id, "r1")
        XCTAssertEqual(entries[0].dateRead, "Mar 3, 2025")
        XCTAssertNil(entries[0].dateAdded, "empty strings become nil")
        XCTAssertNil(entries[0].isbn)
        XCTAssertEqual(entries[0].isbn13, "9780000000001")
        XCTAssertEqual(entries[1].id, "2", "no review id falls back to the book id")
    }

    func testBrokenPageFlag() throws {
        let envelope = try ShelfLibrary.decodeEnvelope(#"{"ok":true,"rows":[],"broken":true}"#)
        XCTAssertEqual(envelope.broken, true)
        XCTAssertEqual(envelope.rows?.count, 0)
    }

    func testErrorEnvelope() throws {
        let envelope = try ShelfLibrary.decodeEnvelope(#"{"ok":false,"error":"signed out"}"#)
        XCTAssertFalse(envelope.ok)
        XCTAssertEqual(envelope.error, "signed out")
    }

    func testNotJSONThrows() {
        XCTAssertThrowsError(try ShelfLibrary.decodeEnvelope("<html>"))
    }
}

final class FriendsDecodingTests: XCTestCase {

    func testFriends() {
        let raw = """
        {"ok":true,"friends":[
          {"id":"7","name":"Rui","avatar":"https://a/7.jpg","url":"https://www.goodreads.com/user/show/7-rui",
           "statusLabel":"Currently reading","statusBookTitle":"Dune","statusBookURL":"https://www.goodreads.com/book/show/1",
           "statusCover":"https://c/1.jpg"},
          {"id":"8","name":"Eva","statusLabel":"","statusBookTitle":""},
          {"id":"","name":"nobody"}
        ]}
        """
        let friends = GoodreadsFriends.decodeFriends(raw)
        XCTAssertEqual(friends.map(\.id), ["7", "8"])
        XCTAssertEqual(friends[0].statusBookTitle, "Dune")
        XCTAssertTrue(friends[0].hasStatus)
        XCTAssertFalse(friends[1].hasStatus, "empty status strings mean no status")
    }

    func testFriendsNotOK() {
        XCTAssertEqual(GoodreadsFriends.decodeFriends(#"{"ok":false}"#).count, 0)
        XCTAssertEqual(GoodreadsFriends.decodeFriends("garbage").count, 0)
    }

    func testActivity() {
        let raw = """
        {"ok":true,"activity":[
          {"id":"a1","friendName":"Rui","profileURL":"https://www.goodreads.com/user/show/7-rui","action":"rated a book",
           "rating":4,"bookTitle":"Dune","bookURL":"https://www.goodreads.com/book/show/1","cover":null,"comment":""},
          {"id":"a2","friendName":"Eva","action":"wants to read","rating":0},
          {"id":"a3","friendName":"","action":"x"}
        ]}
        """
        let activity = GoodreadsFriends.decodeActivity(raw)
        XCTAssertEqual(activity.map(\.id), ["a1", "a2"])
        XCTAssertEqual(activity[0].rating, 4)
        XCTAssertNil(activity[0].comment)
        XCTAssertNil(activity[1].rating, "0 stars means unrated")
        XCTAssertEqual(GoodreadsFriends.userID(from: activity[0].friendProfileURL), "7")
    }
}

final class ReleaseNotesTests: XCTestCase {

    func testHeadingsBulletsAndWrappedLines() {
        let notes = """
        ### Added

        - **Stats** — a new pane with
          a reading goal.
        - Friends.

        Some closing words
        on two lines.
        """
        XCTAssertEqual(ReleaseNotes.blocks(from: notes), [
            .heading("Added"),
            .bullet("**Stats** — a new pane with a reading goal."),
            .bullet("Friends."),
            .paragraph("Some closing words on two lines."),
        ])
    }
}

final class SpotlightIdentifierTests: XCTestCase {

    func testBookIDFromIdentifier() {
        XCTAssertEqual(SpotlightIndex.bookID(fromIdentifier: "book:5907@read"), "5907")
        XCTAssertEqual(SpotlightIndex.bookID(fromIdentifier: "book:5907"), "5907")
        XCTAssertNil(SpotlightIndex.bookID(fromIdentifier: "author:1"))
    }
}

final class ReadingStatsExtrasTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)

    func testPagesAndGenres() {
        let entries = [
            makeEntry(id: "1", dateRead: "Jan 9, 2026"),
            makeEntry(id: "2", dateRead: "Feb 1, 2026"),
            makeEntry(id: "3", dateRead: "Feb 1, 2025"),
            makeEntry(id: "4", dateRead: "Mar 1, 2026"),
        ]
        let extras: [String: BookExtras] = [
            "1": BookExtras(pages: 300, genres: ["Fiction", "Fantasy", "Classics", "Adventure", "Young Adult"]),
            "2": BookExtras(pages: 200, genres: ["Fantasy"]),
            "3": BookExtras(pages: nil, genres: ["History"]),
        ]
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let stats = ReadingStats.compute(from: entries, extras: extras, now: now, calendar: calendar)

        XCTAssertEqual(stats.pagesThisYear, 500)
        XCTAssertEqual(stats.pagesByYear.map(\.count), [0, 500])
        XCTAssertEqual(stats.booksWithExtras, 3)
        // "Fiction" is ignored; only each book's top three count.
        XCTAssertEqual(stats.topGenres.first, .init(genre: "Fantasy", count: 2))
        XCTAssertFalse(stats.topGenres.contains { $0.genre == "Young Adult" })
        XCTAssertFalse(stats.topGenres.contains { $0.genre == "Fiction" })
    }
}
