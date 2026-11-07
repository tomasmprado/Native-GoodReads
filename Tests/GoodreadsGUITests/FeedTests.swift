import XCTest
@testable import GoodreadsGUI

final class FeedTests: XCTestCase {
    private func item(_ title: String, author: String = "Someone", genres: [String], score: Double = 1,
                      sources: [String] = ["similar"]) -> Recommendation {
        Recommendation(book: Book(id: title, title: title, author: author, coverURL: nil, rating: nil),
                       score: score, reason: "", genres: genres, sources: sources)
    }

    func testLearnsFromSwipes() {
        var model = Feed.Model()
        let horror = item("H", author: "Stephen King", genres: ["Horror"]), poetry = item("P", author: "Sophia", genres: ["Poetry"])
        for _ in 0..<6 {
            model.learn(Feed.features(of: poetry), label: 1)
            model.learn(Feed.features(of: horror), label: 0, strength: 1.4)
        }
        XCTAssertGreaterThan(model.likelihood(Feed.features(of: item("P2", author: "Ana", genres: ["Poetry"]))), 0.6)
        XCTAssertLessThan(model.likelihood(Feed.features(of: item("H2", author: "Rui", genres: ["Horror"]))), 0.4)
    }

    func testQuickPassesTeachMore() {
        XCTAssertGreaterThan(Feed.Signal.pass(seconds: 0.8).strength, Feed.Signal.pass(seconds: 4).strength)
        XCTAssertGreaterThan(Feed.Signal.pass(seconds: 4).strength, Feed.Signal.pass(seconds: 20).strength)
        XCTAssertLessThan(Feed.Signal.openedDetails.strength, Feed.Signal.want.strength)
    }

    func testRankingFollowsWhatItLearnt() {
        var model = Feed.Model()
        let liked = item("Liked", author: "A", genres: ["Poetry"], score: 0.5)
        let disliked = item("Disliked", author: "B", genres: ["Horror"], score: 1)
        for _ in 0..<30 {
            model.learn(Feed.features(of: liked), label: 1)
            model.learn(Feed.features(of: disliked), label: 0)
        }
        let ranked = Feed.rank([disliked, liked], model: model, explore: 0)
        XCTAssertEqual(ranked.first?.item.book.title, "Liked", "learnt taste beats the suggestions' own score")
    }

    func testVarietyKeepsTheSameAuthorApart() {
        let books = [item("A1", author: "Ana", genres: ["Poetry"], score: 1),
                     item("A2", author: "Ana", genres: ["Poetry"], score: 0.99),
                     item("B1", author: "Rui", genres: ["History"], score: 0.9)]
        for seed in 1...20 {
            let order = Feed.rank(books, model: Feed.Model(), seed: UInt64(seed), explore: 0).map(\.item.book.title)
            XCTAssertEqual(order[1], "B1", "Ana's two books aren't shown one after the other")
        }
    }

    func testExplorationFavoursTheUnknown() {
        var model = Feed.Model()
        let known = item("Known", author: "A", genres: ["Poetry"], score: 1)
        for _ in 0..<40 { model.learn(Feed.features(of: known), label: 0.6) }
        let fresh = item("Fresh", author: "Z", genres: ["Science"], score: 0.85)
        XCTAssertGreaterThan(model.novelty(Feed.features(of: fresh)), model.novelty(Feed.features(of: known)))
        let ranked = Feed.rank([known, fresh], model: model, explore: 1.2)
        XCTAssertEqual(ranked.first?.item.book.title, "Fresh")
        XCTAssertTrue(ranked.first?.isExploration ?? false)
    }

    func testWarmStartFromPastSwipes() {
        let swipes = (0..<10).map { SwipeDecision(key: "k\($0)", title: "T\($0)", author: "X", genres: ["Fantasy"],
                                                  verdict: .want, date: Date()) }
        let model = Feed.warmStart(swipes)
        XCTAssertEqual(model.updates, 10)
        XCTAssertGreaterThan(model.weights["genre:fantasy"] ?? 0, 0)
    }
}

final class OutboxTests: XCTestCase {
    func testNewerChangesReplaceOlderOnes() {
        var queue = Outbox.adding(.rate(bookID: "1", title: "A", stars: 3), to: [])
        queue = Outbox.adding(.add(bookID: "1", title: "A", shelf: "read"), to: queue)
        queue = Outbox.adding(.rate(bookID: "1", title: "A", stars: 5), to: queue)
        XCTAssertEqual(queue.map(\.change), [.add(bookID: "1", title: "A", shelf: "read"), .rate(bookID: "1", title: "A", stars: 5)])
        queue = Outbox.adding(.progress(bookID: "2", title: "B", percent: 10, page: nil, note: ""), to: queue)
        queue = Outbox.adding(.finish(bookID: "2", title: "B", rating: 4, dateRead: nil, note: ""), to: queue)
        XCTAssertEqual(queue.count, 3, "finishing replaces the progress update")
    }

    func testOfflineErrors() {
        XCTAssertTrue(Outbox.isOffline(URLError(.notConnectedToInternet)))
        XCTAssertTrue(Outbox.isOffline(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        XCTAssertFalse(Outbox.isOffline(URLError(.badServerResponse)))
        XCTAssertFalse(Outbox.isOffline(NSError(domain: "Goodreads", code: 404)))
    }
}
