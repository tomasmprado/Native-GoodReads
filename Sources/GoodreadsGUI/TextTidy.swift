import Foundation

/// Tidies the titles and author names that come from Goodreads, Google
/// Books and the rest: stray symbols ("*", "_", "•") and double spaces go,
/// and names (or titles typed all in capitals or all in small letters) get
/// capitals on every word except little ones like "de".
enum TextTidy {

    /// Symbols that are never part of a title or a name, only decoration.
    private static let junk: Set<Character> = ["*", "_", "~", "`", "^", "•", "·", "★", "☆", "®", "™", "©", "\u{FFFD}"]
    /// Invisible characters that sneak in from web pages.
    private static let invisible: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00AD}"]

    /// Spaces, symbols and punctuation, without touching capitals.
    static func clean(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            if invisible.contains(character) || junk.contains(character) { continue }
            if character == "|" { out.append(" - "); continue }
            out.append(character.isWhitespace ? " " : character)
        }
        guard out.contains("  ") || out.contains(" ,") || out.contains("( ") || out.contains(" )")
                || out.contains(" :") || out.contains(" ;") || out.contains(" .") || out.contains(",,")
                || out.first == " " || out.last == " " || out.hasSuffix(",") || out.hasSuffix(":") || out.hasSuffix("-")
        else { return out }
        out = out.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
        // No space before , ; : . ! ? ) — but keep "..." and a dash's spaces.
        out = out.replacingOccurrences(of: #" +([,;:!?)]|\.(?!\.))"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\( +"#, with: "(", options: .regularExpression)
        out = out.replacingOccurrences(of: #",{2,}"#, with: ",", options: .regularExpression)
        return out.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:-–—")))
    }

    // MARK: Names

    /// Little words that stay in small letters inside a name: "Sophia de Mello".
    private static let particles: Set<String> = ["de", "da", "do", "das", "dos", "e", "y", "di", "du", "del", "della", "dalla", "d'"]
    /// Ones that do too when the name came in all capitals ("LUDWIG VAN
    /// BEETHOVEN"), but otherwise are kept as written ("Ursula K. Le Guin").
    private static let softParticles: Set<String> = ["van", "von", "der", "den", "ten", "ter", "la", "le", "bin", "al"]

    /// "JOSÉ SARAMAGO" → "José Saramago", "sophia De mello" → "Sophia de Mello".
    /// Mixed capitals ("McCarthy", "DeLillo") are left alone.
    static func name(_ raw: String) -> String {
        var text = clean(raw)
        // A web address's way of writing a name: "mario-de-carvalho".
        if !text.contains(" "), text.contains("-"), text == text.lowercased() {
            text = text.replacingOccurrences(of: "-", with: " ")
        }
        guard text.contains(where: \.isLetter) else { return text }
        let shouting = text == text.uppercased() && text.filter(\.isLetter).count > 3
        var startOfName = true
        var words: [String] = []
        for word in text.split(separator: " ") {
            let word = String(word)
            words.append(nameWord(word, first: startOfName, shouting: shouting))
            // "Saramago, José" or "A, B": a new name starts after a comma or "&".
            startOfName = word.hasSuffix(",") || word == "&"
        }
        return words.joined(separator: " ")
    }

    private static func nameWord(_ word: String, first: Bool, shouting: Bool) -> String {
        let bare = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        // An initial ("Erin E. Adams") is never a particle.
        let isInitial = word.contains(".")
        if !first, !isInitial, particles.contains(bare) { return word.lowercased() }
        if !first, !isInitial, softParticles.contains(bare), shouting || word == word.lowercased() { return word.lowercased() }
        let letters = word.filter(\.isLetter)
        let allLower = letters == letters.lowercased()
        let allUpper = letters == letters.uppercased()
        // "JRR" or "DJ" in an ordinary name may be meant; only fix shouting.
        if allLower || (allUpper && shouting) {
            return capitalized(word.lowercased())
        }
        return word
    }

    /// Capital after the start, a hyphen, a full stop or "O'": "jean-paul",
    /// "j.r.r.", "o'brien" → "Jean-Paul", "J.R.R.", "O'Brien".
    private static func capitalized(_ word: String) -> String {
        var out = ""
        var upNext = true
        for character in word {
            out.append(upNext && character.isLetter ? Character(character.uppercased()) : character)
            if character.isLetter { upNext = false }
            if character == "-" || character == "." || character == "(" { upNext = true }
            if character == "'" || character == "’", out.lowercased().hasSuffix("o\(character)"), out.count == 2 { upNext = true }
        }
        return out
    }

    // MARK: Titles

    /// Little words that stay small inside a title written all in capitals
    /// or all in small letters (Portuguese, English, Spanish, French).
    private static let smallTitleWords: Set<String> = [
        "a", "o", "os", "as", "e", "de", "da", "do", "das", "dos", "em", "no", "na", "nos", "nas", "um", "uma",
        "por", "para", "com", "sem", "ao", "aos", "à", "às", "pelo", "pela",
        "the", "of", "and", "in", "on", "at", "to", "for", "an", "or", "by",
        "el", "la", "los", "las", "y", "en", "del", "con",
        "le", "les", "et", "du", "des", "un", "une",
    ]

    /// Spaces and symbols tidied; a title typed all in capitals or all in
    /// small letters gets capitals on its words. Others keep their capitals.
    static func title(_ raw: String) -> String {
        let text = clean(raw)
        let words = text.split(separator: " ")
        let letters = text.filter(\.isLetter)
        let shouting = words.filter { $0.contains(where: \.isLetter) }.count >= 2
            && letters.count > 4 && letters == letters.uppercased()
        let whispering = letters.count > 4 && letters == letters.lowercased()
            && letters.lowercased() != letters.uppercased()   // scripts without capitals
        // Catalogue style puts the article last: "Retorno, O" → "O Retorno".
        guard shouting || whispering else { return ShelfTitles.frontArticle(text) }
        var startOfPart = true
        var out: [String] = []
        for word in words {
            let lower = word.lowercased()
            let bare = lower.trimmingCharacters(in: .punctuationCharacters)
            if !startOfPart, smallTitleWords.contains(bare) {
                out.append(lower)
            } else if shouting, word.count <= 4, word.allSatisfy({ $0.isUppercase || $0 == "." }), word.contains(".") {
                out.append(String(word))                  // "U.S.A."
            } else if bare.allSatisfy({ "ivxlcdm".contains($0) }), !bare.isEmpty, bare != "i" || !startOfPart, bare.count > 1 {
                out.append(lower.uppercased())            // Roman numerals: "Volume II"
            } else {
                out.append(capitalized(lower))
            }
            startOfPart = word.hasSuffix(":") || word.hasSuffix(".") || word.hasSuffix("?") || word.hasSuffix("!")
                || word == "-" || word == "–" || word == "—" || word.hasPrefix("(")
        }
        return ShelfTitles.frontArticle(out.joined(separator: " "))
    }
}

// MARK: - Applied as they're made

/// A book's title, tidied whenever it's set or read back from the cache.
@propertyWrapper
struct TidyTitle: Hashable, Codable, Sendable {
    private var value: String
    var wrappedValue: String {
        get { value }
        set { value = TextTidy.title(newValue) }
    }
    init(wrappedValue: String) { value = TextTidy.title(wrappedValue) }
    init(from decoder: Decoder) throws {
        value = TextTidy.title(try decoder.singleValueContainer().decode(String.self))
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// An author's name, tidied the same way.
@propertyWrapper
struct TidyName: Hashable, Codable, Sendable {
    private var value: String
    var wrappedValue: String {
        get { value }
        set { value = TextTidy.name(newValue) }
    }
    init(wrappedValue: String) { value = TextTidy.name(wrappedValue) }
    init(from decoder: Decoder) throws {
        value = TextTidy.name(try decoder.singleValueContainer().decode(String.self))
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
