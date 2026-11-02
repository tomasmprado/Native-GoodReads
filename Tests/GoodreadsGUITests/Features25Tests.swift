import XCTest
@testable import GoodreadsGUI

final class KindleClippingsTests: XCTestCase {

    private let clippings = """
    \u{FEFF}Dune (Herbert, Frank)
    - Your Highlight on page 12 | Location 170-172 | Added on Monday, 3 January 2022 10:00:00

    Fear is the mind-killer.
    ==========
    Dune (Herbert, Frank)
    - Your Highlight on page 12 | Location 170-174 | Added on Monday, 3 January 2022 10:01:00

    I must not fear. Fear is the mind-killer.
    ==========
    Dune (Herbert, Frank)
    - Your Bookmark on page 40 | Location 600 | Added on Monday, 3 January 2022 10:02:00


    ==========
    Dune (Herbert, Frank)
    - Your Note on page 12 | Location 172 | Added on Monday, 3 January 2022 10:03:00

    The litany!
    ==========
    O Ensaio sobre a Cegueira (José Saramago)
    - O seu destaque na página 3 | posição 40-41 | Adicionado: segunda-feira, 3 de janeiro de 2022 11:00:00

    Se podes olhar, vê.
    ==========
    """

    func testParsesHighlightsNotesAndSkipsBookmarks() {
        let books = Highlights.parseKindle(clippings)
        XCTAssertEqual(books.count, 2)
        XCTAssertEqual(books[0].title, "Dune")
        XCTAssertEqual(books[0].author, "Frank Herbert")
        XCTAssertEqual(books[0].highlights, ["I must not fear. Fear is the mind-killer."],
                       "the shorter highlight was extended later, so only the longer one counts")
        XCTAssertEqual(books[0].notes, ["The litany!"])
        XCTAssertEqual(books[1].author, "José Saramago")
        XCTAssertEqual(books[1].highlights, ["Se podes olhar, vê."])
    }

    func testHeaderWithParenthesesInTitle() {
        let (title, author) = Highlights.splitKindleHeader("The Hobbit (Illustrated) (J.R.R. Tolkien)")
        XCTAssertEqual(title, "The Hobbit (Illustrated)")
        XCTAssertEqual(author, "J.R.R. Tolkien")
    }

    func testMatchesShelfEntriesByTitleAndAuthor() {
        let library = [
            makeEntry(id: "1", title: "Dune (Dune, #1)", author: "Frank Herbert"),
            makeEntry(id: "2", title: "Ensaio sobre a Cegueira", author: "José Saramago"),
            makeEntry(id: "3", title: "Dune", author: "Someone Else"),
        ]
        let imported = [
            ImportedBook(title: "Dune", author: "Frank Herbert", highlights: ["x"], notes: []),
            ImportedBook(title: "ensaio sobre a cegueira: romance", author: "Jose Saramago", highlights: ["y"], notes: []),
            ImportedBook(title: "Unknown Book", author: "Nobody", highlights: ["z"], notes: []),
        ]
        let matches = Highlights.match(imported, to: library)
        XCTAssertEqual(matches[imported[0].id]?.bookID, "1")
        XCTAssertEqual(matches[imported[1].id]?.bookID, "2", "accents and subtitles don't stop a match")
        XCTAssertNil(matches[imported[2].id])
    }

    func testMergeAddsOnlyWhatsNew() {
        var note = BookNote()
        note.quotes = ["old"]
        note.text = "Mine"
        let book = ImportedBook(title: "T", author: "A", highlights: ["old", "new"], notes: ["thought"])
        let (merged, added) = Highlights.merge(book, into: note)
        XCTAssertEqual(merged.quotes, ["old", "new"])
        XCTAssertEqual(merged.text, "Mine\nthought")
        XCTAssertEqual(added, 2)
        XCTAssertEqual(Highlights.merge(book, into: merged).added, 0, "importing twice adds nothing")
    }
}

private struct StoredForTest<V: Encodable>: Encodable {
    let value: V
    let fetched: Date
}

final class BackupTests: XCTestCase {

    func testRoundTripsAndCounts() throws {
        func stored<T: Encodable>(_ value: T) throws -> Data {
            try JSONEncoder().encode(StoredForTest(value: value, fetched: Date()))
        }
        let notes: [String: BookNote] = ["1": BookNote(text: "a"), "2": BookNote(quotes: ["q"])]
        let history: [String: [ProgressPoint]] = ["1": []]
        let backup = BackupFile(appVersion: "2.5.0", files: [
            "notes": ["x.json": try stored(notes)],
            "progress-history": ["y.json": try stored(history)],
        ])
        let decoded = try BackupFile.decode(backup.encoded())
        XCTAssertEqual(decoded.files, backup.files)
        let summary = decoded.summary()
        XCTAssertEqual(summary.notes, 2)
        XCTAssertEqual(summary.progress, 1)
        XCTAssertEqual(summary.abandoned, 0)
    }

    func testRejectsNewerFormat() throws {
        var backup = BackupFile(files: [:])
        backup.format = BackupFile.currentFormat + 1
        XCTAssertThrowsError(try BackupFile.decode(backup.encoded()))
    }
}

final class ChallengeTests: XCTestCase {

    func testParsesGoalFromText() {
        XCTAssertEqual(GoodreadsChallenge.parse(text: "You have read 12 of 40 books.")?.goal, 40)
        XCTAssertEqual(GoodreadsChallenge.parse(text: "You have read 12 of 40 books.")?.read, 12)
        XCTAssertEqual(GoodreadsChallenge.parse(text: "1,024/2,000 books")?.goal, 2000)
        XCTAssertEqual(GoodreadsChallenge.parse(text: "Leu 3 de 24 livros")?.goal, 24)
        XCTAssertNil(GoodreadsChallenge.parse(text: "Join the 2026 Reading Challenge"))
    }
}

final class FriendsBooksTests: XCTestCase {

    private func friend(_ id: String, _ name: String) -> GoodreadsFriends.Friend {
        GoodreadsFriends.Friend(id: id, name: name, avatarURL: nil, profileURL: nil)
    }

    func testReadersFirstThenByRating() {
        let index = [
            "a": FriendsBooks.library(for: friend("a", "Ana"), read: [], reading: [makeEntry(id: "9")]),
            "b": FriendsBooks.library(for: friend("b", "Bruno"), read: [makeEntry(id: "9", rating: 3)], reading: []),
            "c": FriendsBooks.library(for: friend("c", "Carla"), read: [makeEntry(id: "9", rating: 5)], reading: []),
            "d": FriendsBooks.library(for: friend("d", "Duarte"), read: [makeEntry(id: "1")], reading: []),
        ]
        let readers = FriendsBooks.friends(with: "9", in: index)
        XCTAssertEqual(readers.map(\.name), ["Carla", "Bruno", "Ana"])
        XCTAssertEqual(readers.last?.book.state, .reading)
    }

    func testUnratedIsNil() {
        let library = FriendsBooks.library(for: friend("a", "Ana"), read: [makeEntry(id: "1", rating: 0)], reading: [])
        XCTAssertNil(library.books["1"]?.rating)
    }

    func testStaleness() {
        let old = FriendsBooks.library(for: friend("a", "Ana"), read: [], reading: [],
                                       fetched: Date().addingTimeInterval(-4 * 24 * 3600))
        XCTAssertTrue(FriendsBooks.isStale(["a": old]))
        XCTAssertTrue(FriendsBooks.isStale([:]))
        let fresh = FriendsBooks.library(for: friend("a", "Ana"), read: [], reading: [])
        XCTAssertFalse(FriendsBooks.isStale(["a": fresh]))
    }
}

final class AbandonedTests: XCTestCase {

    func testFindsDNFShelf() {
        let shelves = Shelf.builtIn + [Shelf(name: "favourites", label: "Favourites"),
                                       Shelf(name: "dnf", label: "DNF")]
        XCTAssertEqual(AbandonedBooks.dnfShelf(in: shelves)?.name, "dnf")
        XCTAssertNil(AbandonedBooks.dnfShelf(in: Shelf.builtIn))
    }

    func testSortedNewestFirstAndByYear() {
        let calendar = Calendar(identifier: .gregorian)
        let early = AbandonedBook(entry: makeEntry(id: "1"), reason: "",
                                  date: calendar.date(from: DateComponents(year: 2025, month: 3, day: 1))!)
        let late = AbandonedBook(entry: makeEntry(id: "2", progress: 30), reason: "slow",
                                 date: calendar.date(from: DateComponents(year: 2026, month: 5, day: 1))!)
        let all = ["1": early, "2": late]
        XCTAssertEqual(AbandonedBooks.sorted(all).map(\.bookID), ["2", "1"])
        XCTAssertEqual(AbandonedBooks.sorted(all, year: 2026, calendar: calendar).map(\.bookID), ["2"])
        XCTAssertEqual(late.percent, 30)
    }
}

final class WidgetSnapshotTests: XCTestCase {

    func testSnapshotRoundTrip() throws {
        let snapshot = WidgetSnapshot(
            reading: [.init(bookID: "1", title: "Dune", author: "Frank Herbert", percent: 40,
                            finishEstimate: Date(timeIntervalSince1970: 1_800_000_000), coverFile: "cover-1.jpg")],
            goal: .init(year: 2026, read: 10, goal: 24, ahead: -2),
            updated: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(WidgetSnapshot.self, from: encoder.encode(snapshot)), snapshot)
    }

    func testFolderIsInRealHome() {
        XCTAssertTrue(WidgetStore.folder.path.hasSuffix("Library/Application Support/GoodreadsGUI/widget"))
        XCTAssertFalse(WidgetStore.folder.path.contains("/Containers/"))
    }
}

final class SigningTests: XCTestCase {

    func testReadsTheCertificateName() {
        let signed = """
        Executable=/Applications/Goodreads.app/Contents/MacOS/Goodreads
        Identifier=local.goodreads.gui
        Authority=Goodreads Local Signing
        Signed Time=2 Nov 2026
        """
        XCTAssertEqual(SelfUpdater.signingAuthority(fromCodesignOutput: signed), "Goodreads Local Signing")
        let adHoc = """
        Identifier=local.goodreads.gui
        Signature=adhoc
        """
        XCTAssertNil(SelfUpdater.signingAuthority(fromCodesignOutput: adHoc))
    }
}
