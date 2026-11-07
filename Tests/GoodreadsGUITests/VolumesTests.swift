import XCTest
@testable import GoodreadsGUI

final class VolumesTests: XCTestCase {
    private func entry(_ id: String, _ title: String, _ author: String = "Eça de Queirós") -> ShelfEntry {
        ShelfEntry(id: id, bookID: id, reviewID: nil, title: title, author: author, coverURLString: "https://x/\(id).jpg")
    }

    func testVolumeNumbersAtTheEnd() {
        XCTAssertEqual(Volumes.split("Os Maias I")?.base, "Os Maias")
        XCTAssertEqual(Volumes.split("Os Maias II")?.number, 2)
        XCTAssertEqual(Volumes.split("Os Maias - Vol. III")?.number, 3)
        XCTAssertEqual(Volumes.split("Os Maias, Volume 2")?.number, 2)
        XCTAssertEqual(Volumes.split("Guerra e Paz (Tomo IV)")?.base, "Guerra e Paz")
        XCTAssertEqual(Volumes.split("Os Maias II (Os Maias, #2)")?.number, 2)
        XCTAssertNil(Volumes.split("1984"))
        XCTAssertNil(Volumes.split("Fahrenheit 451"))
        XCTAssertNil(Volumes.split("Os Maias"))
        XCTAssertNil(Volumes.split("Volume I"), "no title before the number")
        XCTAssertNil(Volumes.split("Os Maias IIII"))
    }

    func testVolumesJoinUnderTheFirstCover() {
        let items = Volumes.group([entry("b", "Os Maias II"), entry("x", "O Primo Basílio"), entry("a", "Os Maias I"),
                                   entry("h", "Henrique V", "William Shakespeare")])
        XCTAssertEqual(items.map(\.entry.title), ["Os Maias", "O Primo Basílio", "Henrique V"])
        XCTAssertEqual(items[0].volumes.map(\.id), ["a", "b"])
        XCTAssertEqual(items[0].entry.coverURL?.absoluteString, "https://x/a.jpg", "the first volume's cover")
        XCTAssertFalse(items[2].isSet, "a volume alone stays as it is")
    }

    func testOtherAuthorsDontJoin() {
        let items = Volumes.group([entry("a", "Poemas I", "Ana Luísa Amaral"), entry("b", "Poemas II", "Herberto Helder")])
        XCTAssertEqual(items.count, 2)
        let tolstoy = Volumes.group([entry("a", "Guerra e Paz – Volume I", "Lev Tolstói"),
                                     entry("b", "Guerra e Paz - Volume II", "Leo Tolstoy")])
        XCTAssertEqual(tolstoy.count, 1, "one writer spelt two ways")
    }

    func testCountsAcrossShelves() {
        let read = [entry("a", "Os Maias I")]
        let all = read + [entry("b", "Os Maias II"), entry("c", "Os Maias III"), entry("x", "O Primo Basílio")]
        let counts = Volumes.counts(read: read, all: all)
        XCTAssertEqual(counts[Volumes.key(base: "Os Maias", author: "Eça de Queirós")]?.label, "1/3")
        XCTAssertEqual(counts.count, 1)
    }
}
