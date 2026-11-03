import AppIntents
import Foundation

// Shortcuts and Siri. The actions run inside the app (it opens in the
// background if needed), through the same model the window uses.

/// A book on your Currently Reading shelf.
struct ReadingBookEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Book")
    static let defaultQuery = ReadingBookQuery()

    let id: String
    let title: String
    let author: String
    let progress: Int?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)",
                              subtitle: "\(author)\(progress.map { " · \($0)%" } ?? "")")
    }

    init(_ entry: ShelfEntry) {
        id = entry.bookID
        title = entry.title
        author = entry.author
        progress = entry.progress
    }
}

struct ReadingBookQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ReadingBookEntity] {
        Self.reading().filter { identifiers.contains($0.bookID) }.map(ReadingBookEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ReadingBookEntity] {
        Self.reading().map(ReadingBookEntity.init)
    }

    @MainActor
    static func reading() -> [ShelfEntry] {
        let model = LibraryModel.shared
        return model.currentlyReading.isEmpty
            ? (ShelfCache.read(.currentlyReading)?.entries ?? [])
            : model.currentlyReading
    }
}

/// Signs in first if the app hasn't checked yet this launch.
@MainActor
private func readyModel() async throws -> LibraryModel {
    let model = LibraryModel.shared
    if !model.loggedIn { await model.checkSession() }
    guard model.loggedIn else {
        throw AppError(verbatim: String(localized: "Sign in to Goodreads in the app first."))
    }
    return model
}

struct UpdateProgressIntent: AppIntent {
    static let title: LocalizedStringResource = "Update Reading Progress"
    static let description = IntentDescription("Sets how far you are in a book on Currently Reading.")

    @Parameter(title: "Book")
    var book: ReadingBookEntity

    @Parameter(title: "Percent", inclusiveRange: (0, 100))
    var percent: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$book) to \(\.$percent)%")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await readyModel()
        guard let entry = ReadingBookQuery.reading().first(where: { $0.bookID == book.id }) else {
            throw AppError(verbatim: String(localized: "That book isn’t on Currently Reading any more."))
        }
        await model.updateProgress(entry, percent: percent, page: nil, note: "")
        if let status = model.status, status.isError { throw AppError(verbatim: status.text) }
        return .result(dialog: "\(book.title): \(percent)%")
    }
}

struct MarkReadIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Book as Read"
    static let description = IntentDescription("Moves a book from Currently Reading to Read, with an optional rating.")

    @Parameter(title: "Book")
    var book: ReadingBookEntity

    @Parameter(title: "Rating", inclusiveRange: (1, 5))
    var rating: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$book) as read") {
            \.$rating
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await readyModel()
        await model.finish(bookID: book.id, title: book.title, rating: rating, dateRead: Date(), note: "")
        if let status = model.status, status.isError { throw AppError(verbatim: status.text) }
        await model.loadCurrentlyReading(force: true)
        return .result(dialog: "\(model.status?.text ?? book.title)")
    }
}

struct CurrentlyReadingIntent: AppIntent {
    static let title: LocalizedStringResource = "What Am I Reading"
    static let description = IntentDescription("Lists the books on Currently Reading, with your progress.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ReadingBookEntity]> & ProvidesDialog {
        let model = LibraryModel.shared
        if model.currentlyReading.isEmpty { await model.loadCurrentlyReading() }
        let books = ReadingBookQuery.reading()
        guard !books.isEmpty else {
            return .result(value: [], dialog: "Nothing on Currently Reading.")
        }
        let lines = books.map { entry -> String in
            var line = entry.title
            if let progress = entry.progress { line += " — \(progress)%" }
            if let estimate = model.finishEstimate(for: entry) {
                line += String(localized: ", done around \(LibraryModel.shortDate(estimate))")
            }
            return line
        }
        return .result(value: books.map(ReadingBookEntity.init),
                       dialog: "\(lines.joined(separator: "\n"))")
    }
}

struct ReadingGoalIntent: AppIntent {
    static let title: LocalizedStringResource = "Reading Goal Status"
    static let description = IntentDescription("How many books you've read this year, against your goal.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let model = LibraryModel.shared
        if model.readingStats == nil { await model.loadStats() }
        let read = model.readThisYear
        let goal = Preferences.shared.yearlyGoal
        let ahead = read - ReadingStats.expectedByToday(goal: goal)
        let pace = read >= goal
            ? String(localized: "Goal reached 🎉")
            : ahead >= 0 ? String(localized: "\(ahead) ahead of schedule") : String(localized: "\(-ahead) behind schedule")
        return .result(value: read, dialog: "\(String(localized: "\(read) of \(goal) books")) · \(pace)")
    }
}

struct GoodreadsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CurrentlyReadingIntent(),
                    phrases: ["What am I reading in \(.applicationName)",
                              "My books in \(.applicationName)"],
                    shortTitle: "What Am I Reading", systemImageName: "book")
        AppShortcut(intent: UpdateProgressIntent(),
                    phrases: ["Update my reading progress in \(.applicationName)",
                              "Update \(\.$book) in \(.applicationName)"],
                    shortTitle: "Update Progress", systemImageName: "chart.bar")
        AppShortcut(intent: MarkReadIntent(),
                    phrases: ["I finished \(\.$book) in \(.applicationName)",
                              "Mark a book as read in \(.applicationName)"],
                    shortTitle: "Mark as Read", systemImageName: "checkmark.circle")
        AppShortcut(intent: ReadingGoalIntent(),
                    phrases: ["How is my reading goal in \(.applicationName)"],
                    shortTitle: "Reading Goal", systemImageName: "target")
    }
}
