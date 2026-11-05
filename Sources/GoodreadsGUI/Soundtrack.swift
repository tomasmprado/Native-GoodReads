import AVFoundation
import SwiftUI

/// A soundtrack for a book: music from where its author comes from, from
/// when it was written and from its genre — calmer or more restless with
/// the "agitação" slider. Songs come from Apple's iTunes Search (no key),
/// play as 30-second previews and open whole in Apple Music.
struct SoundtrackTrack: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let name: String
    let artist: String
    let genre: String?
    let preview: URL?
    let link: URL?
    let artwork: URL?
}

/// One thing the music is picked from: a country, an era, a genre.
struct SoundtrackIngredient: Sendable, Equatable, Identifiable {
    let label: String
    /// Artists from calm to restless.
    let bands: [[String]]
    var id: String { label }
}

enum Soundtrack {

    // MARK: Ingredients

    /// Artists by country — calm, middle, restless.
    static let countries: [String: [[String]]] = [
        "PT": [["Carlos Paredes", "Rodrigo Leão", "Madredeus"], ["Amália Rodrigues", "Mariza", "Carminho"], ["Xutos & Pontapés", "Ornatos Violeta", "Buraka Som Sistema"]],
        "BR": [["João Gilberto", "Tom Jobim"], ["Caetano Veloso", "Gilberto Gil", "Chico Buarque"], ["Os Mutantes", "Jorge Ben Jor", "Tim Maia"]],
        "ES": [["Paco de Lucía", "Francisco Tárrega"], ["Rosalía", "Camarón de la Isla"], ["Gipsy Kings", "Héroes del Silencio"]],
        "FR": [["Erik Satie", "Claude Debussy", "Yann Tiersen"], ["Édith Piaf", "Serge Gainsbourg", "Françoise Hardy"], ["Daft Punk", "Justice", "Phoenix"]],
        "IT": [["Ludovico Einaudi", "Ennio Morricone"], ["Paolo Conte", "Lucio Battisti", "Mina"], ["Giorgio Moroder", "Måneskin"]],
        "DE": [["Johann Sebastian Bach", "Max Richter", "Nils Frahm"], ["Kraftwerk", "Marlene Dietrich"], ["Rammstein", "Can"]],
        "AT": [["Franz Schubert", "Wolfgang Amadeus Mozart"], ["Johann Strauss II"], ["Falco"]],
        "GB": [["Nick Drake", "Ralph Vaughan Williams"], ["The Beatles", "Kate Bush", "Radiohead"], ["The Clash", "The Rolling Stones", "Arctic Monkeys"]],
        "IE": [["Enya", "Clannad"], ["The Chieftains", "Van Morrison"], ["The Pogues", "U2"]],
        "US": [["Bill Evans", "Philip Glass", "Gillian Welch"], ["Bob Dylan", "Nina Simone", "Miles Davis"], ["Bruce Springsteen", "Chuck Berry", "Talking Heads"]],
        "CA": [["Leonard Cohen", "Joni Mitchell"], ["Neil Young", "Arcade Fire"], ["Rush", "Metric"]],
        "RU": [["Sergei Rachmaninoff", "Pyotr Ilyich Tchaikovsky"], ["Sergei Prokofiev", "Dmitri Shostakovich"], ["Igor Stravinsky", "Kino"]],
        "JP": [["Ryuichi Sakamoto", "Joe Hisaishi"], ["Mariya Takeuchi", "Haruomi Hosono"], ["Yellow Magic Orchestra", "Boris"]],
        "CN": [["Wu Man"], ["Faye Wong"], ["Cui Jian"]],
        "KR": [["Yiruma"], ["IU"], ["BTS"]],
        "IN": [["Ravi Shankar"], ["A. R. Rahman"], ["Asha Bhosle"]],
        "AR": [["Gustavo Santaolalla"], ["Astor Piazzolla", "Mercedes Sosa"], ["Soda Stereo"]],
        "CO": [["Totó la Momposina"], ["Carlos Vives"], ["Bomba Estéreo"]],
        "MX": [["Chavela Vargas"], ["Lila Downs"], ["Café Tacvba"]],
        "CL": [["Violeta Parra"], ["Víctor Jara"], ["Los Prisioneros"]],
        "CU": [["Compay Segundo"], ["Buena Vista Social Club"], ["Celia Cruz"]],
        "NG": [["King Sunny Adé"], ["Fela Kuti"], ["Burna Boy"]],
        "ZA": [["Abdullah Ibrahim"], ["Miriam Makeba", "Hugh Masekela"], ["Johnny Clegg"]],
        "ML": [["Ali Farka Touré", "Toumani Diabaté"], ["Amadou & Mariam"], ["Tinariwen"]],
        "CV": [["Cesária Évora"], ["Mayra Andrade"], ["Tito Paris"]],
        "AO": [["Bonga"], ["Paulo Flores"], ["Titica"]],
        "SE": [["Jan Johansson"], ["ABBA"], ["The Hives"]],
        "NO": [["Jan Garbarek"], ["a-ha"], ["Röyksopp"]],
        "FI": [["Jean Sibelius"], ["Jean Sibelius"], ["Nightwish"]],
        "PL": [["Frédéric Chopin"], ["Henryk Górecki"], ["Krzysztof Komeda"]],
        "CZ": [["Antonín Dvořák"], ["Bedřich Smetana"], ["The Plastic People of the Universe"]],
        "HU": [["Béla Bartók"], ["Franz Liszt"], ["Franz Liszt"]],
        "GR": [["Eleni Karaindrou"], ["Mikis Theodorakis"], ["Vangelis"]],
        "TR": [["Ömer Faruk Tekbilek"], ["Barış Manço"], ["Altın Gün"]],
        "IL": [["Avishai Cohen"], ["Ofra Haza"], ["Infected Mushroom"]],
        "EG": [["Umm Kulthum"], ["Umm Kulthum"], ["Mohamed Mounir"]],
        "LB": [["Fairuz"], ["Ibrahim Maalouf"], ["Mashrou' Leila"]],
        "IR": [["Hossein Alizadeh"], ["Googoosh"], ["Kayhan Kalhor"]],
        "AU": [["Dirty Three"], ["Nick Cave & The Bad Seeds"], ["AC/DC"]],
    ]

    /// Artists by when the book first came out.
    static func era(_ year: Int) -> (label: String, bands: [[String]]) {
        switch year {
        case ..<1750:  return (String(localized: "Baroque"), [["Johann Sebastian Bach"], ["George Frideric Handel"], ["Antonio Vivaldi"]])
        case ..<1820:  return (String(localized: "Classical era"), [["Wolfgang Amadeus Mozart"], ["Joseph Haydn"], ["Ludwig van Beethoven"]])
        case ..<1900:  return (String(localized: "19th century"), [["Frédéric Chopin", "Franz Schubert"], ["Johannes Brahms", "Pyotr Ilyich Tchaikovsky"], ["Richard Wagner", "Giuseppe Verdi"]])
        case ..<1920:  return (String(localized: "Belle Époque"), [["Claude Debussy", "Erik Satie"], ["Maurice Ravel", "Scott Joplin"], ["Igor Stravinsky"]])
        default:
            let decade = year / 10 * 10
            let label = String(localized: "The \(String(decade))s")
            switch decade {
            case 1920: return (label, [["Bix Beiderbecke"], ["Louis Armstrong", "Bessie Smith"], ["Duke Ellington", "Django Reinhardt"]])
            case 1930: return (label, [["Billie Holiday"], ["Ella Fitzgerald", "Django Reinhardt"], ["Benny Goodman", "Count Basie"]])
            case 1940: return (label, [["Billie Holiday", "Nat King Cole"], ["Frank Sinatra", "Édith Piaf"], ["Glenn Miller", "Charlie Parker"]])
            case 1950: return (label, [["Chet Baker", "Miles Davis"], ["Dave Brubeck", "Ella Fitzgerald"], ["Elvis Presley", "Little Richard", "Chuck Berry"]])
            case 1960: return (label, [["Nick Drake", "Simon & Garfunkel"], ["The Beatles", "Bob Dylan", "Nina Simone"], ["The Rolling Stones", "Jimi Hendrix", "The Doors"]])
            case 1970: return (label, [["Brian Eno", "Joni Mitchell"], ["Fleetwood Mac", "Stevie Wonder", "David Bowie"], ["Led Zeppelin", "Ramones", "Donna Summer"]])
            case 1980: return (label, [["Cocteau Twins", "Brian Eno"], ["The Cure", "Talking Heads", "Kate Bush"], ["New Order", "Joy Division", "Prince"]])
            case 1990: return (label, [["Portishead", "Massive Attack"], ["Radiohead", "Björk", "PJ Harvey"], ["Nirvana", "The Prodigy", "Rage Against the Machine"]])
            case 2000: return (label, [["Sigur Rós", "Bon Iver"], ["Arcade Fire", "The National", "Feist"], ["The Strokes", "LCD Soundsystem", "Yeah Yeah Yeahs"]])
            default: return (label, [["Nils Frahm", "Ólafur Arnalds", "Phoebe Bridgers"], ["Lana Del Rey", "Tame Impala", "Frank Ocean"], ["Kendrick Lamar", "Fontaines D.C.", "Charli XCX"]])
            }
        }
    }

    /// Artists by the book's genre (Goodreads' names), in order of preference.
    static let genres: [(genre: String, bands: [[String]])] = [
        ("Horror", [["Angelo Badalamenti", "Jóhann Jóhannsson"], ["Goblin", "John Carpenter"], ["Nine Inch Nails", "Ministry"]]),
        ("Science Fiction", [["Vangelis", "Brian Eno"], ["Jean-Michel Jarre", "Tangerine Dream"], ["Daft Punk", "Kavinsky", "Perturbator"]]),
        ("Dystopia", [["Ben Frost"], ["Radiohead", "Massive Attack"], ["Nine Inch Nails", "Rage Against the Machine"]]),
        ("Fantasy", [["Howard Shore", "Loreena McKennitt"], ["Hans Zimmer", "Enya"], ["Wardruna", "Two Steps from Hell"]]),
        ("Magical Realism", [["Gustavo Santaolalla"], ["Buena Vista Social Club", "Caetano Veloso"], ["Os Mutantes"]]),
        ("Mystery", [["Angelo Badalamenti", "Chet Baker"], ["Bernard Herrmann", "Henry Mancini"], ["Lalo Schifrin", "Portishead"]]),
        ("Thriller", [["Angelo Badalamenti"], ["Bernard Herrmann"], ["Lalo Schifrin", "Trent Reznor & Atticus Ross"]]),
        ("Crime", [["Chet Baker"], ["Henry Mancini"], ["Lalo Schifrin"]]),
        ("Romance", [["Norah Jones", "Chet Baker"], ["Adele", "Etta James"], ["Whitney Houston", "Beyoncé"]]),
        ("War", [["Samuel Barber", "Henryk Górecki"], ["Max Richter"], ["Hans Zimmer"]]),
        ("Historical Fiction", [["Jordi Savall", "Hildegard von Bingen"], ["Ennio Morricone", "Dead Can Dance"], ["Hans Zimmer"]]),
        ("Poetry", [["Erik Satie", "Keith Jarrett"], ["Leonard Cohen", "Patti Smith"], ["Patti Smith"]]),
        ("Philosophy", [["Arvo Pärt", "Philip Glass"], ["Steve Reich"], ["Philip Glass"]]),
        ("Humor", [["Vince Guaraldi Trio"], ["The Beatles"], ["Madness", "The B-52's"]]),
        ("Young Adult", [["Phoebe Bridgers"], ["Taylor Swift", "Lorde"], ["Paramore", "Olivia Rodrigo"]]),
        ("Travel", [["Ali Farka Touré"], ["Ibrahim Maalouf"], ["Tinariwen"]]),
        ("Memoir", [["Sufjan Stevens"], ["Joni Mitchell"], ["Patti Smith"]]),
        ("Classics", [["Frédéric Chopin"], ["Johannes Brahms"], ["Ludwig van Beethoven"]]),
        ("Nonfiction", [["Max Richter"], ["Ólafur Arnalds"], ["Explosions in the Sky"]]),
    ]

    static func ingredients(country: AuthorCountry?, year: Int?, genres bookGenres: [String]) -> [SoundtrackIngredient] {
        var result: [SoundtrackIngredient] = []
        if let country, let bands = countries[country.code] {
            result.append(SoundtrackIngredient(label: "\(country.flag) \(country.displayName)", bands: bands))
        }
        if let year {
            let era = era(year)
            result.append(SoundtrackIngredient(label: era.label, bands: era.bands))
        }
        let lowered = Set(bookGenres.map { $0.lowercased() })
        for (genre, bands) in genres where lowered.contains(genre.lowercased()) {
            result.append(SoundtrackIngredient(label: Bingo.genreName(genre), bands: bands))
            if result.count >= 4 { break }
        }
        return result
    }

    /// 0 calm … 1 restless → which band of artists.
    static func band(for energy: Double) -> Int {
        min(2, max(0, Int((energy * 3).rounded(.down))))
    }

    static func energyLabel(_ energy: Double) -> String {
        switch band(for: energy) {
        case 0: String(localized: "Calm")
        case 1: String(localized: "Balanced")
        default: String(localized: "Restless")
        }
    }

    /// How restless a song is likely to be, from its genre.
    static func energy(ofGenre genre: String?) -> Double {
        let genre = genre?.lowercased() ?? ""
        let table: [(String, Double)] = [
            ("classical", 0.1), ("ambient", 0.1), ("fado", 0.3), ("new age", 0.1), ("soundtrack", 0.35), ("jazz", 0.4),
            ("singer/songwriter", 0.35), ("folk", 0.35), ("world", 0.45), ("blues", 0.5), ("latin", 0.6),
            ("r&b", 0.55), ("soul", 0.55), ("pop", 0.6), ("alternative", 0.65), ("electronic", 0.7),
            ("rock", 0.75), ("hip-hop", 0.8), ("rap", 0.8), ("dance", 0.85), ("house", 0.85),
            ("hard rock", 0.9), ("punk", 0.95), ("metal", 0.95),
        ]
        return table.last { genre.contains($0.0) }?.1 ?? 0.5
    }

    // MARK: Picking songs

    /// The mix: a few songs by each ingredient's artists for this energy,
    /// taking turns, at most two per artist. The same seed gives the same mix.
    static func mix(_ songs: [(ingredient: Int, artist: String, tracks: [SoundtrackTrack])],
                    energy target: Double, seed: UInt64, limit: Int = 18) -> [SoundtrackTrack] {
        var rng = SeededRandom(seed: seed)
        var queues: [Int: [SoundtrackTrack]] = [:]
        for group in songs {
            // Popular songs first (iTunes' order), a little shuffled, closest
            // in energy first.
            let picked = group.tracks.prefix(10).shuffled(using: &rng).prefix(4)
                .sorted { abs(energy(ofGenre: $0.genre) - target) < abs(energy(ofGenre: $1.genre) - target) }
                .prefix(2)
            queues[group.ingredient, default: []] += picked
        }
        for key in queues.keys { queues[key]?.shuffle(using: &rng) }
        var result: [SoundtrackTrack] = []
        var seen: Set<String> = []
        while result.count < limit, queues.values.contains(where: { !$0.isEmpty }) {
            for key in queues.keys.sorted() where result.count < limit {
                guard var queue = queues[key], !queue.isEmpty else { continue }
                let track = queue.removeFirst()
                queues[key] = queue
                let name = track.name.lowercased()
                if seen.insert(name).inserted { result.append(track) }
            }
        }
        return result
    }

    /// Songs by one artist, saved for a month.
    static func songs(by artist: String) async -> [SoundtrackTrack] {
        let region = Locale.current.region?.identifier ?? "US"
        let key = "\(region)-\(artist.lowercased())"
        if let hit = await DataCache.shared.read([SoundtrackTrack].self, "itunes-artist", key, ttl: 30 * 24 * 3600), !hit.isStale {
            return hit.value
        }
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: artist), URLQueryItem(name: "attribute", value: "artistTerm"),
            URLQueryItem(name: "media", value: "music"), URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "25"), URLQueryItem(name: "country", value: region),
            URLQueryItem(name: "lang", value: "en_us"),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SearchResult.self, from: data) else { return [] }
        // Only the artist asked for — the search also matches namesakes.
        let tracks = decoded.results.filter { AuthorWikipedia.sameName($0.artistName, artist) || fold($0.artistName).contains(fold(artist)) }
            .compactMap { item -> SoundtrackTrack? in
                guard let id = item.trackId, let name = item.trackName, item.previewUrl != nil else { return nil }
                return SoundtrackTrack(id: id, name: name, artist: item.artistName, genre: item.primaryGenreName,
                                       preview: item.previewUrl.flatMap(URL.init(string:)),
                                       link: item.trackViewUrl.flatMap(URL.init(string:)),
                                       artwork: item.artworkUrl100.flatMap(URL.init(string:)))
            }
        await DataCache.shared.write(tracks, "itunes-artist", key)
        return tracks
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter }
    }

    private struct SearchResult: Decodable {
        struct Item: Decodable {
            let trackId: Int?
            let trackName: String?
            let artistName: String
            let primaryGenreName: String?
            let previewUrl: String?
            let trackViewUrl: String?
            let artworkUrl100: String?
        }
        let results: [Item]
    }

    /// A seed that's the same on every launch (Swift's hashes aren't).
    static func seed(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}

// MARK: - Player

@MainActor
final class SoundtrackPlayer: ObservableObject {
    static let shared = SoundtrackPlayer()

    @Published private(set) var playing: SoundtrackTrack?
    private var queue: [SoundtrackTrack] = []
    private let player = AVPlayer()
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.next() }
        }
    }

    /// Plays `track`, then the ones after it in `list`.
    func play(_ track: SoundtrackTrack, in list: [SoundtrackTrack]) {
        guard let url = track.preview else { return }
        if let index = list.firstIndex(of: track) { queue = Array(list[(index + 1)...]) } else { queue = [] }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
        playing = track
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        playing = nil
        queue = []
    }

    private func next() {
        guard !queue.isEmpty else { stop(); return }
        let track = queue.removeFirst()
        play(track, in: [track] + queue)
    }
}

// MARK: - Pane

struct SoundtrackPane: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var player = SoundtrackPlayer.shared
    @AppStorage("soundtrackEnergy") private var energy = 0.4
    @State private var shownEnergy = 0.4
    @State private var ingredients: [SoundtrackIngredient] = []
    @State private var tracks: [SoundtrackTrack] = []
    @State private var isLoading = false
    @State private var mixNumber = 0
    @State private var copied = false

    private var choices: [Book] {
        let reading = ShelfCache.read(.currentlyReading)?.entries ?? []
        let read = (ShelfCache.read(.read)?.entries ?? []).sorted {
            (Suggestions.parseDate($0.dateRead ?? "") ?? .distantPast) > (Suggestions.parseDate($1.dateRead ?? "") ?? .distantPast)
        }
        return (reading + read.prefix(15)).map(\.asBook)
    }

    private var book: Book? { model.soundtrackBook ?? choices.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let book {
                header(book)
                energySlider
                Divider()
                trackList
            } else {
                EmptyPane(symbol: "music.note", text: String(localized: "Start reading something and it gets a soundtrack."))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Soundtrack")
        .onAppear { shownEnergy = energy }
        .task(id: "\(book?.id ?? "")-\(Soundtrack.band(for: energy))-\(mixNumber)") { await build() }
    }

    private func header(_ book: Book) -> some View {
        HStack(alignment: .top, spacing: 14) {
            CachedAsyncImage(url: book.coverURL) { phase in
                if case .success(let image) = phase { image.resizable().aspectRatio(contentMode: .fill) }
                else { RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)) }
            }
            .frame(width: 64, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(radius: 3, y: 2)
            VStack(alignment: .leading, spacing: 6) {
                Menu {
                    ForEach(choices) { choice in
                        Button(choice.title) { model.soundtrackBook = choice }
                    }
                } label: {
                    Text(book.title).appFont(size: 18, weight: .semibold).lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Text(book.author).appFont(size: 12).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(ingredients) { ingredient in
                        Text(ingredient.label)
                            .appFont(size: 10, weight: .medium)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .glassCapsule()
                    }
                }
            }
            Spacer()
        }
    }

    private var energySlider: some View {
        HStack(spacing: 10) {
            Text("Agitation").appFont(size: 12, weight: .medium)
            Image(systemName: "leaf").foregroundStyle(.green)
            Slider(value: $shownEnergy, in: 0...1) { editing in
                if !editing { energy = shownEnergy }
            }
            .frame(maxWidth: 280)
            Image(systemName: "flame").foregroundStyle(.orange)
            Text(Soundtrack.energyLabel(shownEnergy)).appFont(size: 11).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
            Button { mixNumber += 1 } label: { Label("Another Mix", systemImage: "shuffle") }
                .help("Other songs from the same ingredients")
            Button {
                if player.playing != nil { player.stop() } else if let first = tracks.first { player.play(first, in: tracks) }
            } label: {
                Label(player.playing != nil ? "Stop" : "Play All", systemImage: player.playing != nil ? "stop.fill" : "play.fill")
            }
            .disabled(tracks.isEmpty)
            Button {
                let text = tracks.map { "\($0.artist) — \($0.name)" }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
            } label: { Label(copied ? "Copied" : "Copy List", systemImage: "doc.on.doc") }
                .disabled(tracks.isEmpty)
        }
    }

    @ViewBuilder
    private var trackList: some View {
        if tracks.isEmpty, !isLoading {
            Text(ingredients.isEmpty
                 ? String(localized: "Not enough is known about this book yet — no country, year or genre to go on.")
                 : String(localized: "No songs found right now."))
                .foregroundStyle(.secondary)
        } else {
            List(tracks) { track in
                HStack(spacing: 10) {
                    CachedAsyncImage(url: track.artwork) { phase in
                        if case .success(let image) = phase { image.resizable() }
                        else { RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)) }
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    Button {
                        if player.playing == track { player.stop() } else { player.play(track, in: tracks) }
                    } label: {
                        Image(systemName: player.playing == track ? "pause.circle.fill" : "play.circle")
                            .appFont(size: 20)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.name).appFont(size: 12, weight: player.playing == track ? .semibold : .regular).lineLimit(1)
                        Text([track.artist, track.genre].compactMap { $0 }.joined(separator: " · "))
                            .appFont(size: 10).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let link = track.link {
                        Button { NSWorkspace.shared.open(link) } label: { Image(systemName: "arrow.up.forward.app") }
                            .buttonStyle(.plain)
                            .help("Open in Apple Music")
                    }
                }
                .padding(.vertical, 2)
                .listRowBackground(player.playing == track ? Color.accentColor.opacity(0.12) : Color.clear)
            }
            .listStyle(.inset)
        }
    }

    private func build() async {
        guard let book else { return }
        isLoading = true
        copied = false
        defer { isLoading = false }
        var genres = book.genresFromCategories
        var year = book.publishedDate.flatMap { Int($0.prefix(4)) }
        if let id = book.goodreadsID {
            var page = await DataCache.shared.read(GoodreadsBookPage.Detail.self, "book-page", id, ttl: .infinity)?.value
            if page == nil { page = try? await GoodreadsBookPage.fetch(bookID: id) }
            if let page {
                if let found = page.genres, !found.isEmpty { genres = found }
                if let date = page.about?.firstPublished ?? page.about?.published {
                    year = Calendar.current.component(.year, from: date)
                }
            }
            if genres.isEmpty, let extras = model.bookExtras[id] { genres = extras.genres }
        }
        let country = await AuthorCountries.country(for: book.author)
        ingredients = Soundtrack.ingredients(country: country, year: year, genres: genres)

        let band = Soundtrack.band(for: energy)
        var groups: [(ingredient: Int, artist: String, tracks: [SoundtrackTrack])] = []
        for (index, ingredient) in ingredients.enumerated() {
            for artist in ingredient.bands[band].prefix(3) where !Task.isCancelled {
                groups.append((index, artist, await Soundtrack.songs(by: artist)))
            }
        }
        guard !Task.isCancelled else { return }
        tracks = Soundtrack.mix(groups, energy: energy, seed: Soundtrack.seed("\(book.id)-\(band)-\(mixNumber)"))
        Diagnostics.shared.log("soundtrack", "\(book.title): \(ingredients.map(\.label).joined(separator: ", ")) → \(tracks.count) songs")
    }
}
