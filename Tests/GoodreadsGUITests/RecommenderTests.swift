import XCTest
@testable import GoodreadsGUI

final class RecommenderTests: XCTestCase {
    private func read(_ id: String, _ title: String, _ author: String, _ rating: Int, _ date: String = "Oct 1, 2026") -> ShelfEntry {
        var entry = ShelfEntry(id: id, bookID: id, reviewID: nil, title: title, author: author, coverURLString: nil)
        entry.rating = rating
        entry.dateRead = date
        return entry
    }

    private func book(_ title: String, _ author: String) -> Book {
        Book(id: title, title: title, author: author, coverURL: nil, rating: nil)
    }

    func testTasteWeighsRatingsAgainstYourAverageAndRecency() {
        let shelf = [read("1", "Dune", "Frank Herbert", 5), read("2", "Emma", "Jane Austen", 2),
                     read("3", "Old", "Old Author", 5, "Jan 1, 2005")]
        let extras = ["1": BookExtras(pages: nil, genres: ["Science Fiction"]), "2": BookExtras(pages: nil, genres: ["Romance"])]
        let profile = TasteProfile.build(read: shelf, extras: extras, now: Suggestions.parseDate("Nov 1, 2026")!)
        XCTAssertGreaterThan(profile.authorAffinity("Frank Herbert"), 0)
        XCTAssertLessThan(profile.authorAffinity("Jane Austen"), 0, "below your average counts against")
        XCTAssertGreaterThan(profile.authorAffinity("Frank Herbert"), profile.authorAffinity("Old Author"), "recent counts more")
        XCTAssertEqual(profile.topGenres.first, "science fiction")
        XCTAssertEqual(profile.seeds.first?.entry.title, "Dune")
    }

    func testSwipesAndAbandonedBooksTeachIt() {
        let shelf = [read("1", "Dune", "Frank Herbert", 4)]
        let passed = SwipeDecision(key: "x", title: "X", author: "Frank Herbert", genres: [], verdict: .pass, date: Date())
        let base = TasteProfile.build(read: shelf, extras: [:])
        let after = TasteProfile.build(read: shelf, extras: [:], swipes: [passed, passed])
        XCTAssertLessThan(after.authorAffinity("Frank Herbert"), base.authorAffinity("Frank Herbert"))
    }

    func testBooksPointedToByManyFavouritesRankFirst() {
        let profile = TasteProfile()
        let a = Candidate(book: book("Hyperion", "Dan Simmons"), sources: [.similar(seed: "Dune", weight: 1)], communityRating: 4.2)
        let a2 = Candidate(book: book("Hyperion (Hyperion Cantos, #1)", "Dan Simmons"), sources: [.similar(seed: "Foundation", weight: 1)])
        let b = Candidate(book: book("Solaris", "Stanisław Lem"), sources: [.similar(seed: "Dune", weight: 1)], communityRating: 4.0)
        let ranked = Recommender.rank([b, a, a2], profile: profile, excluded: [])
        XCTAssertEqual(ranked.map(\.book.title).first, "Hyperion")
        XCTAssertEqual(ranked.count, 2, "two editions of one book are one suggestion")
        XCTAssertTrue(ranked[0].reason.contains("Dune") || ranked[0].reason.contains("Foundation"))
    }

    func testShelvedAndSwipedAreLeftOutAndAuthorsAreCapped() {
        let profile = TasteProfile()
        let many = (1...4).map { Candidate(book: book("Book \($0)", "Same Author"), sources: [.author("Same Author")]) }
        let shelved = Candidate(book: book("Dune", "Frank Herbert"), sources: [.series("Dune")])
        let ranked = Recommender.rank(many + [shelved], profile: profile, excluded: ["dune"])
        XCTAssertEqual(ranked.count, 2)
        XCTAssertFalse(ranked.contains { $0.book.title == "Dune" })
    }

    func testRatingsAndTasteMoveTheScore() {
        var profile = TasteProfile()
        profile.genres = ["fantasy": 3, "horror": -2]
        let loved = Candidate(book: book("A", "X"), sources: [.genre("fantasy")], genres: ["Fantasy"], communityRating: 4.4)
        let disliked = Candidate(book: book("B", "Y"), sources: [.genre("fantasy")], genres: ["Horror"], communityRating: 4.4)
        let ranked = Recommender.rank([disliked, loved], profile: profile, excluded: [])
        XCTAssertEqual(ranked.map(\.book.title), ["A", "B"])
    }
}

final class ReadingLanguagesTests: XCTestCase {
    func testLanguagesYouReadIn() {
        let codes = ReadingLanguages.codes(of: Array(repeating: "portuguese", count: 21) + ["english", "english", "russian", "spanish; castilian"])
        XCTAssertEqual(codes, ["pt", "en"])
    }

    func testBooksInOtherLanguagesAreLeftOut() {
        let allowed: Set<String> = ["pt", "en"]
        XCTAssertFalse(ReadingLanguages.fits(title: "Унесенные ветром. Том 1", blurb: nil, allowed: allowed))
        XCTAssertFalse(ReadingLanguages.fits(title: "La Guerre et la Paix", blurb:
            "Le roman retrace l'histoire de plusieurs familles aristocratiques russes pendant les guerres napoléoniennes, entre la paix et la guerre.", allowed: allowed))
        XCTAssertTrue(ReadingLanguages.fits(title: "O Filho de Mil Homens", blurb:
            "Um pescador solitário decide que quer ter um filho e começa a construir uma família com pessoas que encontra pelo caminho.", allowed: allowed))
        XCTAssertTrue(ReadingLanguages.fits(title: "Sótão", blurb: nil, allowed: allowed), "unknown counts as yes")
    }
}
