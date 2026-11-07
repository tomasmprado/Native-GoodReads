import Foundation

/// A book on a shelf as it's shown: usually one entry, but the volumes of
/// one work ("Os Maias I", "Os Maias II") are shown together, under the
/// first one's cover.
struct ShelfItem: Identifiable, Hashable {
    /// The first volume, titled without its number.
    let entry: ShelfEntry
    /// Every volume on the shelf, in order; just `entry` for an ordinary book.
    let volumes: [ShelfEntry]
    /// The key the volumes share, for counting them across shelves.
    let key: String?

    var id: String { entry.id }
    var isSet: Bool { volumes.count > 1 }
}

enum Volumes {
    /// Goodreads' "(Series, #2)" after a title.
    private static let seriesSuffix = #"\s*\([^()]*#[^()]*\)\s*$"#
    /// "Os Maias I", "Os Maias - II", "Os Maias, Vol. III", "Os Maias (Tomo IV)".
    private static let roman = try! NSRegularExpression(
        pattern: #"^(.+?)[\s,.:;\-–—]*\(?\s*(?:(?i:vol(?:ume)?|tomo|livro|parte|part|book|band)\.?\s*)?([IVX]{1,5})\s*\)?$"#)
    /// "Os Maias, Vol. 2", "Os Maias (Tomo 3)" — a number needs the word before it.
    private static let arabic = try! NSRegularExpression(
        pattern: #"^(.+?)[\s,.:;\-–—]*\(?\s*(?:vol(?:ume)?|tomo|livro|parte|part|book|band)\.?\s*(\d{1,2})\s*\)?$"#,
        options: [.caseInsensitive])

    private static let keywords: Set<String> = ["vol", "volume", "tomo", "livro", "parte", "part", "book", "band"]

    /// The work's title and the volume's number, when the title ends in one.
    static func split(_ title: String) -> (base: String, number: Int)? {
        let bare = title.replacingOccurrences(of: seriesSuffix, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let range = NSRange(bare.startIndex..., in: bare)
        for (regex, isRoman) in [(roman, true), (arabic, false)] {
            guard let match = regex.firstMatch(in: bare, range: range),
                  let baseRange = Range(match.range(at: 1), in: bare),
                  let numberRange = Range(match.range(at: 2), in: bare) else { continue }
            let base = String(bare[baseRange]).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",.:;-–—(")))
            let text = String(bare[numberRange])
            guard base.filter(\.isLetter).count >= 2, !keywords.contains(base.lowercased()),
                  let number = isRoman ? romanValue(text) : Int(text), number >= 1, number <= 30 else { continue }
            return (base, number)
        }
        return nil
    }

    static func romanValue(_ text: String) -> Int? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10]
        var total = 0
        var previous = 0
        for character in text.reversed() {
            guard let value = values[character] else { return nil }
            total += value < previous ? -value : value
            previous = max(previous, value)
        }
        // Only the usual way of writing it: "IIII" or "VX" aren't volumes.
        let canonical = ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X",
                         "XI", "XII", "XIII", "XIV", "XV", "XVI", "XVII", "XVIII", "XIX", "XX"]
        return total < canonical.count && canonical[total] == text ? total : nil
    }

    /// The work and its author. Authors are matched on the start of the
    /// surname, so "Leo Tolstoy" and "Lev Tolstói" are the same writer.
    static func key(base: String, author: String) -> String {
        let surname = TasteProfile.authorKey(author).split(separator: " ").last.map { String($0.prefix(5)) } ?? ""
        return Suggestions.normalizedTitle(base) + "|" + surname
    }

    /// The shelf with each work's volumes joined into one item, where the
    /// first of them was. A volume alone stays as it is.
    static func group(_ entries: [ShelfEntry]) -> [ShelfItem] {
        var parsed: [String: [(entry: ShelfEntry, number: Int, base: String)]] = [:]
        for entry in entries {
            guard let (base, number) = split(entry.title) else { continue }
            parsed[key(base: base, author: entry.author), default: []].append((entry, number, base))
        }
        let sets = parsed.filter { Set($0.value.map(\.number)).count > 1 }
        var placed = Set<String>()
        var items: [ShelfItem] = []
        for entry in entries {
            if let (base, _) = split(entry.title), case let key = key(base: base, author: entry.author),
               let volumes = sets[key] {
                guard placed.insert(key).inserted else { continue }
                let ordered = volumes.sorted { $0.number < $1.number }
                items.append(ShelfItem(entry: ordered[0].entry.withTitle(ordered[0].base),
                                       volumes: ordered.map(\.entry), key: key))
            } else {
                items.append(ShelfItem(entry: entry, volumes: [entry], key: nil))
            }
        }
        return items
    }

    /// How many volumes of each work you've read, and how many are on your
    /// shelves at all.
    struct Count: Equatable {
        let read: Int
        let total: Int
        var label: String { "\(read)/\(total)" }
    }

    static func counts(read: [ShelfEntry], all: [ShelfEntry]) -> [String: Count] {
        var have: [String: Set<Int>] = [:]
        var done: [String: Set<Int>] = [:]
        for (list, isRead) in [(all, false), (read, true)] {
            for entry in list {
                guard let (base, number) = split(entry.title) else { continue }
                let key = key(base: base, author: entry.author)
                have[key, default: []].insert(number)
                if isRead { done[key, default: []].insert(number) }
            }
        }
        var result: [String: Count] = [:]
        for (key, numbers) in have where numbers.count > 1 {
            result[key] = Count(read: done[key]?.count ?? 0, total: numbers.count)
        }
        return result
    }
}
