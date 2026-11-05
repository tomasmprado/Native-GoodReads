import SwiftUI
import UserNotifications

/// A few lines to yourself about a book, sealed until a day you choose —
/// a year, usually. Kept in letters.json, not in the cache.
struct Letter: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var bookID: String?
    var title: String?
    var author: String?
    var cover: String?
    let text: String
    let written: Date
    let opens: Date
    var notified = false
    var read = false

    var coverURL: URL? { cover.flatMap(URL.init(string:)) }
    func isOpen(at now: Date = Date()) -> Bool { opens <= now }
}

@MainActor
final class LetterBox: ObservableObject {
    static let shared = LetterBox()
    nonisolated static let category = "letter"

    @Published private(set) var letters: [Letter]

    private init() {
        letters = SavedFile.read([Letter].self, "letters") ?? []
    }

    var unread: Int { letters.filter { $0.isOpen() && !$0.read }.count }

    func add(_ text: String, title: String?, author: String?, bookID: String?, cover: URL?, opens: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        letters.append(Letter(id: UUID().uuidString, bookID: bookID, title: title, author: author,
                              cover: cover?.absoluteString, text: trimmed, written: Date(), opens: opens))
        save()
    }

    func delete(_ letter: Letter) {
        letters.removeAll { $0.id == letter.id }
        save()
    }

    func markRead(_ letter: Letter) {
        guard let index = letters.firstIndex(where: { $0.id == letter.id }), !letters[index].read else { return }
        letters[index].read = true
        save()
    }

    /// Letters whose day has come get a notification, once.
    func deliver() async {
        var changed = false
        for index in letters.indices where letters[index].isOpen() && !letters[index].notified {
            let letter = letters[index]
            let content = UNMutableNotificationContent()
            content.title = String(localized: "A letter from you")
            let when = letter.written.formatted(date: .long, time: .omitted)
            content.body = letter.title.map { String(localized: "Written on \(when), when you finished \($0).") }
                ?? String(localized: "Written on \(when).")
            content.sound = .default
            content.categoryIdentifier = Self.category
            content.userInfo = ["letterID": letter.id]
            try? await UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: "letter-\(letter.id)", content: content, trigger: nil))
            letters[index].notified = true
            changed = true
        }
        if changed { save() }
    }

    /// Checks now and then every hour while the app runs.
    func startDelivering() {
        Task {
            while !Task.isCancelled {
                await deliver()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private func save() {
        SavedFile.write(letters, "letters")
    }
}

/// "On this day": the books you finished around today's date in past
/// years, and the ones you were in the middle of.
struct OnThisDay: Identifiable, Equatable {
    let year: Int
    let finished: [ShelfEntry]
    let reading: [ShelfEntry]
    var id: Int { year }

    static func find(in entries: [ShelfEntry], today: Date = Date(), calendar: Calendar = .current) -> [OnThisDay] {
        let thisYear = calendar.component(.year, from: today)
        // Only dates with a day: "Mar 2019" says too little.
        let dated: [(ShelfEntry, Date)] = entries.compactMap { entry in
            guard let text = entry.dateRead, text.contains(",") || text.count == 10,
                  let date = Suggestions.parseDate(text) else { return nil }
            return (entry, date)
        }
        var result: [OnThisDay] = []
        for year in (thisYear - 30..<thisYear).reversed() {
            var parts = calendar.dateComponents([.month, .day], from: today)
            parts.year = year
            guard let day = calendar.date(from: parts) else { continue }
            func days(_ date: Date) -> Int { calendar.dateComponents([.day], from: day, to: date).day ?? 999 }
            let finished = dated.filter { abs(days($0.1)) <= 3 }.map(\.0)
            let reading = dated.filter { (4...25).contains(days($0.1)) }.map(\.0)
            if !finished.isEmpty || !reading.isEmpty {
                result.append(OnThisDay(year: year, finished: finished, reading: Array(reading.prefix(3))))
            }
        }
        return result
    }
}

// MARK: - Pane

struct LettersPane: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var box = LetterBox.shared
    @State private var composing = false
    @State private var past: [OnThisDay] = []

    private var opened: [Letter] { box.letters.filter { $0.isOpen() }.sorted { $0.opens > $1.opens } }
    private var sealed: [Letter] { box.letters.filter { !$0.isOpen() }.sorted { $0.opens < $1.opens } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Letters").appFont(size: 22, weight: .semibold)
                        Text("Write to yourself about a book; it opens in a year.")
                            .appFont(size: 12).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { composing = true } label: { Label("Write a Letter", systemImage: "square.and.pencil") }
                }

                onThisDay

                if !opened.isEmpty {
                    section(String(localized: "Opened")) {
                        ForEach(opened) { letter in openLetter(letter) }
                    }
                }
                if !sealed.isEmpty {
                    section(String(localized: "Sealed")) {
                        ForEach(sealed) { letter in sealedLetter(letter) }
                    }
                }
                if box.letters.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "envelope").appFont(size: 34).foregroundStyle(.tertiary)
                        Text("No letters yet. When you finish a book, write a couple of lines — you’ll get them back next year.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                }
            }
            .padding(18)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Letters")
        .sheet(isPresented: $composing) { LetterComposer(model: model) }
        .task {
            past = OnThisDay.find(in: ShelfCache.read(.read)?.entries ?? [])
            await box.deliver()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).appFont(size: 15, weight: .semibold)
            content()
        }
    }

    @ViewBuilder
    private var onThisDay: some View {
        if !past.isEmpty {
            section(String(localized: "On this day")) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(past) { day in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(yearsAgo(day.year)).appFont(size: 12, weight: .bold).foregroundStyle(Color.accentColor)
                                ForEach(day.finished) { entry in
                                    pastBook(entry, String(localized: "you finished"))
                                }
                                ForEach(day.reading) { entry in
                                    pastBook(entry, String(localized: "you were reading"))
                                }
                            }
                            .padding(12)
                            .frame(width: 230, alignment: .topLeading)
                            .glassCard(cornerRadius: 14)
                        }
                    }
                    .padding(4)
                }
            }
        }
    }

    private func yearsAgo(_ year: Int) -> String {
        let years = Calendar.current.component(.year, from: Date()) - year
        return years == 1 ? String(localized: "A year ago") : String(localized: "\(years) years ago · \(String(year))")
    }

    private func pastBook(_ entry: ShelfEntry, _ what: String) -> some View {
        Button { model.showBookDetail(entry.asBook) } label: {
            HStack(spacing: 8) {
                cover(entry.coverURL, width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(what).appFont(size: 9).foregroundStyle(.secondary)
                    Text(entry.title).appFont(size: 11, weight: .medium).lineLimit(2)
                    if let rating = entry.rating, rating > 0 {
                        Text(String(repeating: "★", count: rating)).appFont(size: 9).foregroundStyle(.orange)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func openLetter(_ letter: Letter) -> some View {
        HStack(alignment: .top, spacing: 14) {
            cover(letter.coverURL, width: 44)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let title = letter.title {
                        Text(title).appFont(size: 13, weight: .semibold).lineLimit(1)
                    }
                    if !letter.read {
                        Text("New").appFont(size: 9, weight: .bold).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    Spacer()
                    Text(letter.written.formatted(date: .long, time: .omitted))
                        .appFont(size: 10).foregroundStyle(.secondary)
                }
                Text(letter.text)
                    .font(.system(size: 14, design: .serif))
                    .italic()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.98, green: 0.95, blue: 0.86).opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))
        .onAppear { box.markRead(letter) }
        .contextMenu { Button("Delete Letter", role: .destructive) { box.delete(letter) } }
    }

    private func sealedLetter(_ letter: Letter) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope.fill").appFont(size: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(letter.title.map { String(localized: "About \($0)") } ?? String(localized: "A letter"))
                    .appFont(size: 12, weight: .medium).lineLimit(1)
                Text("Opens \(letter.opens.formatted(date: .long, time: .omitted)) · \(letter.opens.formatted(.relative(presentation: .named)))")
                    .appFont(size: 11).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
        .contextMenu { Button("Delete Letter", role: .destructive) { box.delete(letter) } }
    }

    private func cover(_ url: URL?, width: CGFloat) -> some View {
        CachedAsyncImage(url: url) { phase in
            if case .success(let image) = phase { image.resizable().aspectRatio(contentMode: .fill) }
            else { RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)) }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// Writing a letter about any book you've read or are reading.
struct LetterComposer: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var bookID = ""
    @State private var text = ""
    @State private var months = 12

    private var books: [ShelfEntry] {
        let reading = ShelfCache.read(.currentlyReading)?.entries ?? []
        let read = (ShelfCache.read(.read)?.entries ?? []).sorted {
            (Suggestions.parseDate($0.dateRead ?? "") ?? .distantPast) > (Suggestions.parseDate($1.dateRead ?? "") ?? .distantPast)
        }
        return reading + read.prefix(30)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A letter to yourself").appFont(size: 15, weight: .semibold)
            Picker("About", selection: $bookID) {
                Text("No book in particular").tag("")
                ForEach(books) { entry in Text(entry.title).tag(entry.bookID) }
            }
            TextEditor(text: $text)
                .font(.system(size: 13, design: .serif))
                .frame(height: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Picker("Opens in", selection: $months) {
                Text("a month").tag(1)
                Text("six months").tag(6)
                Text("a year").tag(12)
                Text("five years").tag(60)
            }
            .pickerStyle(.segmented)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Seal") {
                    let entry = books.first { $0.bookID == bookID }
                    let opens = Calendar.current.date(byAdding: .month, value: months, to: Date()) ?? Date()
                    LetterBox.shared.add(text, title: entry?.title, author: entry?.author, bookID: entry?.bookID,
                                         cover: entry?.coverURL, opens: opens)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { if bookID.isEmpty { bookID = books.first?.bookID ?? "" } }
    }
}
