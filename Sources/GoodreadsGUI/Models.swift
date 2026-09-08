import Foundation

struct Book: Identifiable, Hashable {
    let id: String
    let title: String
    let author: String
    let coverURL: URL?
    let rating: String?
}

enum Shelf: String, CaseIterable, Identifiable {
    case wantToRead = "want-to-read"
    case currentlyReading = "currently-reading"
    case read = "read"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wantToRead: return "Want to Read"
        case .currentlyReading: return "Currently Reading"
        case .read: return "Read"
        }
    }

    var symbol: String {
        switch self {
        case .wantToRead: return "bookmark"
        case .currentlyReading: return "book"
        case .read: return "checkmark.circle"
        }
    }
}
