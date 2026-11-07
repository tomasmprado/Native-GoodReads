import XCTest
@testable import GoodreadsGUI

final class TextTidyTests: XCTestCase {
    func testTitlesLoseSymbolsAndDoubleSpaces() {
        XCTAssertEqual(TextTidy.title("O  Ano da Morte de *Ricardo Reis*"), "O Ano da Morte de Ricardo Reis")
        XCTAssertEqual(TextTidy.title("  Leme ,  um romance  "), "Leme, um romance")
        XCTAssertEqual(TextTidy.title("Duna (Duna , #1)"), "Duna (Duna, #1)")
        XCTAssertEqual(TextTidy.title("Ensaio\u{00A0}sobre a cegueira\u{200B}"), "Ensaio sobre a cegueira")
        XCTAssertEqual(TextTidy.title("Espera... e depois"), "Espera... e depois")
        XCTAssertEqual(TextTidy.title("Os Maias - "), "Os Maias")
        XCTAssertEqual(TextTidy.title("RETORNO, O"), "O Retorno")
        XCTAssertEqual(TextTidy.title("poder magico do jejum, o"), "O Poder Magico do Jejum")
        XCTAssertEqual(TextTidy.title("Uma | Outra"), "Uma - Outra")
    }

    func testTitlesInCapitalsOrSmallLetters() {
        XCTAssertEqual(TextTidy.title("O ANO DA MORTE DE RICARDO REIS"), "O Ano da Morte de Ricardo Reis")
        XCTAssertEqual(TextTidy.title("the lord of the rings: the return of the king"),
                       "The Lord of the Rings: The Return of the King")
        XCTAssertEqual(TextTidy.title("HARRY POTTER E A PEDRA FILOSOFAL (HARRY POTTER, #1)"),
                       "Harry Potter e a Pedra Filosofal (Harry Potter, #1)")
        XCTAssertEqual(TextTidy.title("IT"), "IT", "one short word in capitals may be meant")
        XCTAssertEqual(TextTidy.title("Uma delicada coleção de ausências"), "Uma delicada coleção de ausências",
                       "mixed capitals are left as written")
    }

    func testNames() {
        XCTAssertEqual(TextTidy.name("JOSÉ SARAMAGO"), "José Saramago")
        XCTAssertEqual(TextTidy.name("sophia De mello breyner andresen"), "Sophia de Mello Breyner Andresen")
        XCTAssertEqual(TextTidy.name("Eça De Queirós"), "Eça de Queirós")
        XCTAssertEqual(TextTidy.name("gabriel garcía márquez"), "Gabriel García Márquez")
        XCTAssertEqual(TextTidy.name("J.R.R. TOLKIEN"), "J.R.R. Tolkien")
        XCTAssertEqual(TextTidy.name("jean-paul sartre"), "Jean-Paul Sartre")
        XCTAssertEqual(TextTidy.name("flannery o'connor"), "Flannery O'Connor")
        XCTAssertEqual(TextTidy.name("Cormac McCarthy"), "Cormac McCarthy")
        XCTAssertEqual(TextTidy.name("Ursula K. Le Guin"), "Ursula K. Le Guin")
        XCTAssertEqual(TextTidy.name("LUDWIG VAN BEETHOVEN"), "Ludwig van Beethoven")
        XCTAssertEqual(TextTidy.name("De Gaulle, charles"), "De Gaulle, Charles", "a name can start with De")
        XCTAssertEqual(TextTidy.name("Mário  de Sá-Carneiro *"), "Mário de Sá-Carneiro")
        XCTAssertEqual(TextTidy.name("Erin E. * Adams"), "Erin E. Adams")
        XCTAssertEqual(TextTidy.name("mario-de-carvalho"), "Mario de Carvalho")
        XCTAssertEqual(TextTidy.name("Hugo * van der Ding"), "Hugo van der Ding")
    }

    func testBooksAndEntriesAreTidiedWhenMadeAndDecoded() throws {
        let book = Book(id: "1", title: "O  ANO DA MORTE DE RICARDO REIS", author: "JOSÉ SARAMAGO", coverURL: nil, rating: nil)
        XCTAssertEqual(book.title, "O Ano da Morte de Ricardo Reis")
        XCTAssertEqual(book.author, "José Saramago")
        let json = #"{"id":"1","bookID":"1","title":"Leme  *","author":"madalena sá fernandes"}"#
        let entry = try JSONDecoder().decode(ShelfEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.title, "Leme")
        XCTAssertEqual(entry.author, "Madalena Sá Fernandes")
        let again = try JSONDecoder().decode(ShelfEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(again, entry)
    }
}
