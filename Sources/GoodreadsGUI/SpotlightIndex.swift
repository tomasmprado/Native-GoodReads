import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Puts the books on your shelves into Spotlight: type a title or author in
/// ⌘Space and the book shows up; choosing it opens its details here.
///
/// Fed from `ShelfCache.write`, so whatever shelf just loaded is what gets
/// indexed — one Spotlight domain per shelf, replaced as a whole each time,
/// which also drops books that left the shelf.
enum SpotlightIndex {

    static let enabledKey = "indexInSpotlight"
    private static let idPrefix = "book:"

    /// On unless turned off in Settings.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func update(_ entries: [ShelfEntry], shelf: Shelf) {
        guard isEnabled else { return }
        let domain = "shelf:\(shelf.name)"
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            let items = entries.map { item(for: $0, shelf: shelf, domain: domain) }
            CSSearchableIndex.default().indexSearchableItems(items) { _ in }
        }
    }

    static func removeAll() {
        CSSearchableIndex.default().deleteAllSearchableItems { _ in }
    }

    /// The Goodreads book id inside a Spotlight item's identifier.
    static func bookID(fromIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(idPrefix) else { return nil }
        let rest = identifier.dropFirst(idPrefix.count)
        // "book:<id>@<shelf>" — the same book can sit on several shelves.
        return rest.split(separator: "@", maxSplits: 1).first.map(String.init)
    }

    private static func item(for entry: ShelfEntry, shelf: Shelf, domain: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = entry.title
        attributes.displayName = entry.title
        attributes.authorNames = [entry.author]
        attributes.contentDescription = "\(entry.author) · \(shelf.title)"
        attributes.keywords = [entry.author, shelf.title, "Goodreads"]
        if let rating = entry.rating, rating > 0 { attributes.rating = NSNumber(value: rating) }
        return CSSearchableItem(uniqueIdentifier: "\(idPrefix)\(entry.bookID)@\(shelf.name)",
                                domainIdentifier: domain,
                                attributeSet: attributes)
    }
}
