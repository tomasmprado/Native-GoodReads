import SwiftUI

// MARK: - Data

/// One runner in the reading-challenge race on Home.
struct RaceEntry: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let avatarURL: URL?
    let profileURL: URL?
    let read: Int
    let goal: Int
    let isMe: Bool

    var fraction: Double { goal > 0 ? min(1, Double(read) / Double(goal)) : 0 }
}

/// This week's reading, worked out from the progress history.
struct WeekSummary: Equatable {
    var pages = 0
    var finishedThisMonth = 0

    static func compute(history: [String: [ProgressPoint]], pages: [String: Int], read: [ShelfEntry],
                        now: Date = Date(), calendar: Calendar = .current) -> WeekSummary {
        var summary = WeekSummary()
        let weekStart = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        for (bookID, points) in history {
            guard let total = pages[bookID], total > 0 else { continue }
            let sorted = points.sorted { $0.date < $1.date }
            let inWeek = sorted.filter { $0.date >= weekStart && $0.date <= now }
            guard let latest = inWeek.last else { continue }
            let before = sorted.last { $0.date < weekStart }?.percent ?? inWeek.first?.percent ?? 0
            let gained = max(0, latest.percent - before)
            summary.pages += Int((Double(total) * Double(gained) / 100).rounded())
        }

        let month = calendar.dateComponents([.year, .month], from: now)
        summary.finishedThisMonth = read.filter { entry in
            guard let date = Suggestions.parseDate(entry.dateRead ?? "") else { return false }
            return calendar.dateComponents([.year, .month], from: date) == month
        }.count
        return summary
    }
}

extension LibraryModel {
    /// Friends' reading-challenge progress, from their profiles (saved for
    /// half a day; at most eight friends, one page at a time).
    func loadFriendRace() async {
        let year = Calendar.current.component(.year, from: Date())
        if friends.isEmpty { await loadFriends() }
        var runners: [RaceEntry] = []
        for friend in friends.prefix(8) {
            guard let url = friend.profileURL else { continue }
            var profile = await DataCache.shared.read(GoodreadsFriends.Profile.self, "profile", url.absoluteString,
                                                      ttl: 12 * 3600)
            if profile == nil || profile!.isStale || profile!.value.details == nil {
                if let fresh = try? await GoodreadsFriends.fetchProfile(url: url) {
                    await DataCache.shared.write(fresh, "profile", url.absoluteString)
                    profile = .init(value: fresh, fetched: Date(), isStale: false)
                }
            }
            guard let challenge = profile?.value.details?.challenge, challenge.year == nil || challenge.year == year else { continue }
            runners.append(RaceEntry(id: friend.id, name: friend.name, avatarURL: friend.avatarURL, profileURL: url,
                                     read: challenge.read, goal: challenge.goal, isMe: false))
            friendRace = runners
        }
        friendRace = runners
    }

    /// You and your friends, furthest along first.
    var race: [RaceEntry] {
        let me = RaceEntry(id: "me", name: String(localized: "You"), avatarURL: nil, profileURL: nil,
                           read: readThisYear, goal: Preferences.shared.yearlyGoal, isMe: true)
        return ([me] + friendRace).sorted { $0.fraction > $1.fraction }
    }

    /// Days in a row read, from every reading day the app knows: Kobo time,
    /// Apple Books, progress updates and "I read today".
    var readingStreak: ReadingStreak? {
        ReadingStreak.compute(days: ReadingLog.readingDays(readingLog, progress: progressHistory),
                              weekGoal: Preferences.shared.weeklyReadingDays)
    }

    /// Counts today as a reading day, for reading the app didn't see.
    func markReadToday() async {
        let book = currentlyReading.first
        await ReadingLog.add([ReadingRecord(bookID: book?.bookID, title: book?.title ?? "", start: Date(),
                                            seconds: 0, source: .timer)])
        readingLog = await ReadingLog.all()
        WidgetBridge.scheduleUpdate()
    }

    var weekSummary: WeekSummary {
        WeekSummary.compute(history: progressHistory, pages: bookExtras.compactMapValues(\.pages),
                            read: ShelfCache.read(.read)?.entries ?? [])
    }
}

// MARK: - Views

/// Home: what you're reading, your goal, the race with your friends, your
/// week and what's next — laid out to fit the window without scrolling.
struct HomeDashboard: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        GeometryReader { proxy in
            // The window's height is shared out, so nothing spills into the
            // next card however small the window is.
            let spacing: CGFloat = 12
            let usable = max(320, proxy.size.height - 32 - 34 - spacing * 2)
            let top = min(250, max(150, usable * 0.46))
            let bottom = usable - top
            VStack(alignment: .leading, spacing: spacing) {
                header.frame(height: 34)

                HStack(alignment: .top, spacing: 14) {
                    ReadingStrip(model: model, height: top)
                        .frame(maxWidth: .infinity)
                    GoalCardSmall(read: model.readThisYear, goal: Preferences.shared.yearlyGoal)
                        .frame(width: 170)
                }
                .frame(height: top)

                HStack(alignment: .top, spacing: 14) {
                    RaceCard(model: model, height: bottom)
                        .frame(maxWidth: .infinity)
                    VStack(spacing: 12) {
                        WeekCard(model: model, summary: model.weekSummary)
                            .frame(height: min(110, (bottom - 12) / 2))
                        NextCard(model: model)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(width: 250)
                }
                .frame(height: bottom)
            }
            .padding(16)
        }
        .task {
            await model.loadStats()
            if model.friendRace.isEmpty { await model.loadFriendRace() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(greeting).appFont(size: 22, weight: .semibold)
            Spacer()
            Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .appFont(size: 12).foregroundStyle(.secondary)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return String(localized: "Good morning")
        case 12..<20: return String(localized: "Good afternoon")
        default: return String(localized: "Good evening")
        }
    }
}

private struct GoalCardSmall: View {
    let read: Int
    let goal: Int

    var body: some View {
        let expected = ReadingStats.expectedByToday(goal: goal)
        VStack(spacing: 8) {
            Text("\(String(Calendar.current.component(.year, from: Date()))) Goal")
                .appFont(size: 11, weight: .semibold).foregroundStyle(.secondary)
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: goal > 0 ? min(1, Double(read) / Double(goal)) : 0)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(read)").appFont(size: 26, weight: .bold, design: .rounded)
                    Text("of \(goal)").appFont(size: 11).foregroundStyle(.secondary)
                }
            }
            .frame(width: 110, height: 110)
            Text(read >= goal ? String(localized: "Goal reached 🎉")
                 : read - expected >= 0 ? String(localized: "\(read - expected) ahead of schedule")
                 : String(localized: "\(expected - read) behind schedule"))
                .appFont(size: 11, weight: .medium)
                .foregroundStyle(read - expected >= 0 ? Color.green : Color.orange)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }
}

/// The reading challenge as a race: everyone's share of their own goal, a
/// finish line, and where an even pace would put you today.
private struct RaceCard: View {
    @ObservedObject var model: LibraryModel
    var height: CGFloat = 300

    var body: some View {
        let runners = model.race
        let today = dayFraction
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("The Race").appFont(size: 13, weight: .semibold)
                Text("to this year’s goal").appFont(size: 11).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "flag.checkered").foregroundStyle(.secondary)
            }
            if runners.count == 1 {
                Text("Friends who’ve joined this year’s Reading Challenge race here too.")
                    .appFont(size: 11).foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                ForEach(runners.prefix(max(1, Int((height - 90) / 36)))) { runner in
                    lane(runner, today: today)
                }
            }
            Spacer(minLength: 0)
            Text("Dotted line: where an even pace would be today.")
                .appFont(size: 10).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .glassCard(cornerRadius: 14)
    }

    private var dayFraction: Double {
        let calendar = Calendar.current
        let now = Date()
        guard let day = calendar.ordinality(of: .day, in: .year, for: now),
              let days = calendar.range(of: .day, in: .year, for: now)?.count else { return 0 }
        return Double(day) / Double(days)
    }

    private func lane(_ runner: RaceEntry, today: Double) -> some View {
        HStack(spacing: 8) {
            Text(runner.name.split(separator: " ").first.map(String.init) ?? runner.name)
                .appFont(size: 11, weight: runner.isMe ? .semibold : .regular)
                .frame(width: 64, alignment: .leading)
                .lineLimit(1)
            GeometryReader { proxy in
                let width = proxy.size.width - 26
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12)).frame(height: 6).offset(y: 0)
                    Capsule().fill(runner.isMe ? Color.orange : Color.accentColor.opacity(0.7))
                        .frame(width: max(6, width * runner.fraction + 13), height: 6)
                    // Where an even pace would be.
                    Path { path in
                        path.move(to: CGPoint(x: 13 + width * today, y: 2))
                        path.addLine(to: CGPoint(x: 13 + width * today, y: 24))
                    }
                    .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    avatar(runner)
                        .offset(x: width * runner.fraction)
                        .animation(.spring(response: 0.8, dampingFraction: 0.8), value: runner.fraction)
                    Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 2, height: 22)
                        .offset(x: width + 12)
                }
                .frame(height: 26)
            }
            .frame(height: 26)
            Text("\(runner.read)/\(runner.goal)")
                .appFont(size: 10).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = runner.profileURL { Task { await model.openFriendProfile(url) } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(runner.name): \(runner.read) of \(runner.goal) books"))
    }

    @ViewBuilder
    private func avatar(_ runner: RaceEntry) -> some View {
        if runner.isMe {
            Image(systemName: "figure.run")
                .appFont(size: 13, weight: .bold)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.orange))
        } else {
            CachedAsyncImage(url: runner.avatarURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Circle().fill(Color.secondary.opacity(0.3))
                }
            }
            .frame(width: 26, height: 26)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
        }
    }
}

private struct WeekCard: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var prefs = Preferences.shared
    let summary: WeekSummary

    var body: some View {
        let streak = model.readingStreak
        let current = streak?.current() ?? 0
        let atRisk = streak?.atRisk() ?? false
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your Week").appFont(size: 13, weight: .semibold)
                Spacer()
                if !(streak?.readToday() ?? false) {
                    Button { Task { await model.markReadToday() } } label: {
                        Label("I read today", systemImage: "checkmark")
                            .appFont(size: 10, weight: .medium)
                    }
                    .controlSize(.mini)
                    .glassButton()
                    .help("Count today as a reading day, for reading the app didn’t see")
                }
            }
            HStack(spacing: 10) {
                stat("\(current)", current == 1 ? String(localized: "day in a row") : String(localized: "days in a row"),
                     atRisk ? "flame" : "flame.fill", tint: current > 0 ? .orange : .secondary)
                    .help(atRisk ? String(localized: "Read today to keep it going")
                                 : String(localized: "Longest: \(streak?.longest ?? 0) days"))
                weekGoal(streak?.daysThisWeek() ?? 0)
                stat("\(summary.pages)", String(localized: "pages"), "book.pages", tint: .orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .glassCard(cornerRadius: 14)
        .contextMenu {
            Picker("Weekly goal", selection: $prefs.weeklyReadingDays) {
                ForEach(1...7, id: \.self) { days in
                    Text(days == 7 ? String(localized: "Every day") : String(localized: "\(days) days a week")).tag(days)
                }
            }
        }
        .task { if model.readingLog.isEmpty { model.readingLog = await ReadingLog.all() } }
    }

    /// "3/5" days read this week, as a small ring.
    private func weekGoal(_ days: Int) -> some View {
        let goal = prefs.weeklyReadingDays
        return VStack(alignment: .leading, spacing: 2) {
            ZStack {
                Circle().stroke(Color.orange.opacity(0.2), lineWidth: 2.5)
                Circle().trim(from: 0, to: min(1, CGFloat(days) / CGFloat(max(goal, 1))))
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 11, height: 11)
            Text("\(days)/\(goal)").appFont(size: 18, weight: .bold, design: .rounded)
            Text(days >= goal ? String(localized: "week’s goal met") : String(localized: "days this week"))
                .appFont(size: 9).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .help("Right-click to change the weekly goal")
    }

    private func stat(_ value: String, _ label: String, _ symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: symbol).appFont(size: 11).foregroundStyle(tint)
            Text(value).appFont(size: 18, weight: .bold, design: .rounded)
            Text(label).appFont(size: 9).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct NextCard: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Next").appFont(size: 13, weight: .semibold)
            if let volume = model.nextVolume, volume.entry.id != model.upNext?.id {
                row(title: volume.entry.title, author: volume.entry.author, cover: volume.entry.coverURL,
                    label: String(localized: "Next volume · \(volume.read)/\(volume.total) read")) {
                    model.showBookDetail(volume.entry.asBook)
                }
            }
            if let next = model.upNext {
                row(title: next.title, author: next.author, cover: next.coverURL,
                    label: String(localized: "Up next on Want to Read")) { model.showBookDetail(next.asBook) }
            }
            // Two at most, so Home still fits the window.
            if let suggestion = model.suggestions.first, model.nextVolume == nil || model.upNext == nil {
                row(title: suggestion.book.title, author: suggestion.book.author, cover: suggestion.book.coverURL,
                    label: String(localized: "Suggested for you")) { model.showBookDetail(suggestion.book) }
            }
            if model.upNext == nil && model.nextVolume == nil && model.suggestions.isEmpty {
                Text("Put Want to Read in your order, or open Suggestions.").appFont(size: 11).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .glassCard(cornerRadius: 14)
    }

    private func row(title: String, author: String, cover: URL?, label: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 8) {
                CachedAsyncImage(url: cover) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                    }
                }
                .frame(width: 28, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).appFont(size: 9).foregroundStyle(.secondary)
                    Text(title).appFont(size: 11, weight: .medium).foregroundStyle(.primary).lineLimit(1)
                    Text(author).appFont(size: 10).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


/// Home's Currently Reading: compact cards sized to the space Home gives them.
private struct ReadingStrip: View {
    @ObservedObject var model: LibraryModel
    let height: CGFloat

    var body: some View {
        // Header, padding and the text under each cover take about 95pt.
        let coverHeight = max(60, min(130, height - 98))
        let coverWidth = coverHeight * 2 / 3
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Currently Reading").appFont(size: 13, weight: .semibold)
                if model.isLoadingCurrentlyReading { ProgressView().controlSize(.small) }
            }
            if model.currentlyReading.isEmpty {
                Spacer()
                Text(model.isLoadingCurrentlyReading ? String(localized: "Loading…") : String(localized: "Nothing on Currently Reading yet."))
                    .appFont(size: 12).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(model.currentlyReading) { entry in
                            card(entry, width: max(coverWidth, 92), coverHeight: coverHeight, coverWidth: coverWidth)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .glassCard(cornerRadius: 14)
    }

    private func card(_ entry: ShelfEntry, width: CGFloat, coverHeight: CGFloat, coverWidth: CGFloat) -> some View {
        let pages = model.pages(for: entry)
        return VStack(alignment: .leading, spacing: 4) {
            Button { model.showBookDetail(entry.asBook) } label: {
                CachedAsyncImage(url: entry.coverURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
                            .overlay(Image(systemName: "book.closed").foregroundStyle(.tertiary))
                    }
                }
                .frame(width: coverWidth, height: coverHeight)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            Text(entry.title).appFont(size: 11, weight: .medium).lineLimit(1)
            ProgressView(value: Double(entry.progress ?? 0), total: 100)
                .accessibilityLabel(Text("Progress"))
            Text(pages.map { String(localized: "\(entry.progress ?? 0)% · p. \($0.page) of \($0.total)") }
                 ?? (entry.progress.map { "\($0)%" } ?? String(localized: "No progress yet")))
                .appFont(size: 9).foregroundStyle(.secondary).lineLimit(1)
            Button("Update Progress…") { model.activeSheet = .progress(entry) }
                .buttonStyle(.link)
                .appFont(size: 9)
        }
        .frame(width: width, alignment: .leading)
        .contextMenu {
            Button("Update Progress…") { model.activeSheet = .progress(entry) }
            Button("Mark Read & Rate…") { model.activeSheet = .finish(entry) }
            Button("Stop Reading…") { model.activeSheet = .abandon(entry) }
            Divider()
            Button("View Details…") { model.showBookDetail(entry.asBook) }
        }
    }
}
