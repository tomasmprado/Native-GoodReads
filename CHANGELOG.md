# Changelog

Everything below is relative to `v1.0.0`, current as of `main`. That range
(https://github.com/tomasmprado/Native-GoodReads/compare/v1.0.0...main)
landed on GitHub as one squashed "Initial commit" — 32 files changed,
+5226/−470 — so this groups the actual changes by what they do instead of
repeating that one message. Most of `Sources/GoodreadsGUI/` shows as newly
added in that diff, meaning `v1.0.0` predates all of it.

## [Unreleased]

### Added

- **Discover is a feed now**, ranked like a social app's. It learns from
  everything you do as you do it: hearts, "read it", passes (a quick pass
  counts more than one you thought about), opening a book's details and
  lingering on a card. Each card's genres, author, length, age, reach,
  rating and where the suggestion came from get a weight. The deck
  re-ranks after every swipe and keeps variety (no author twice in a row,
  no run of one genre). Now and then it shows something different, marked
  as such, to see if you like it. What it learns also moves the
  Suggestions list. It starts from your past swipes.
- **Reading streaks**: days in a row you've read, counted from Kobo time,
  Apple Books, progress updates and a new **I read today** button. Your
  Week on Home shows the streak, the longest one, and a gentle weekly
  goal ("3/5 days"; right-click to change it). A new **Reading Streak**
  widget nudges you on days you haven't read yet.
- **Works offline.** Rating, moving, removing, progress and finishing
  books all work with no connection: the change shows straight away, waits
  in an outbox (kept if you quit), and goes to Goodreads when you're back
  online, oldest first. The sidebar says how many are waiting. Every cover
  on your shelves is kept on disk, so the library looks the same offline.
- **Next volume** on Home: after "Os Maias I", "Os Maias II" from your Want
  to Read, with how many volumes you've read.
- **Bookcase**: spines take their colour from the book's cover; the arrow
  keys move along the shelf (↑ ↓ between rows), Return opens the book and
  Escape puts it back.

## [3.1.0] — 2026-11-07

### Added

- **Bookcase view** for shelves (not Currently Reading): spines with the
  title and author, thicker for longer books, on wooden planks. Click one
  to pull it out and see a little about it underneath; + opens its details.
- **Volumes together:** the volumes of one work on a shelf ("Os Irmãos
  Karamázov I" and "II", "Guerra e Paz – Volume I"…) show as one book with
  the first one's cover and "1/2" on the right — volumes read, of those on
  your shelves. Each volume's actions are in its own submenu.
- **Bingo**: a 4×4 card for the year built from what you rarely read —
  countries and continents you've never visited, books older than your
  grandparents, genres you skip or keep passing in Discover, books waiting
  on your shelves for years. Squares fill themselves as you finish books;
  each suggests books from your Want to Read. In Suggestions, next to
  Discover.
- **Letters to yourself**: a few lines when you finish a book (or any time),
  sealed until a month, six months, a year or five years later, with a
  notification when one opens. Letters, in Notes, also show what you
  finished, or were reading, on this day in past years.
- **Reading time and a calendar of the days you read** in Stats, from the
  Kobo's own reading time, the days a book was open in Apple Books, and
  progress updates.
- **Your Series** in Suggestions, from Google Books: how far you are in
  each series you've read from, the next book (one click to Want to Read),
  and a notification when a new book joins one of them.
- **Smarter suggestions ("Picked for You").** A taste profile from your Read
  shelf — authors and genres weighed by your stars against your own average
  and by how recently you read them, minus books you gave up on — scores
  books from several places at once: Goodreads' "Readers also enjoyed" for
  your favourites, friends' five-star books (friends who loved what you
  loved), next in your series, new and older books by authors you love,
  writers who shaped your authors (from Wikidata) whom you've never read,
  and well-rated books in your genres. Books several favourites point to rise
  to the top; each suggestion says why; two per author at most.
- **Discover**: suggestions one card at a time — swipe right (→) for Want to
  Read, left (←) to pass, up (↑) if you've read it (then rate it), ⌘Z to
  undo. Every swipe teaches the suggestions. The cover grows with the card,
  and the buttons are Liquid Glass.
- **A simpler sidebar:** Suggestions, Discover and Bingo share one pane,
  and so do Notes and Letters, with a switch at the top. Search is the
  magnifying glass in the toolbar (⌘K). The foot of the sidebar no longer
  says "Signed in" or confirms what worked; it speaks up only when
  something fails.
- **Scan a barcode** (File → Scan a Barcode…, ⇧⌘B, or the button in Search):
  hold a book's barcode up to the Mac's camera or an iPhone's through
  Continuity Camera (used when there is one); the barcode is outlined when
  it's read, and the book can go straight onto a shelf, or say which shelf
  it's on already.
- **Price alerts at Wook** (in Portugal), as well as Apple Books, for books
  on Want to Read.
- **Widgets:** Quote of the Day (one of your saved quotes, a new one daily)
  and Friends' Race.
- **Authors' Countries**: a world map in Stats of where the authors you've
  read are from, looked up on Wikidata by itself, and how many countries
  in Year in Books.

### Fixed

- Titles and author names are tidied everywhere: the "*" Goodreads puts
  inside some names ("Stephen * King"), double spaces, stray symbols and
  invisible characters go; names and titles typed all in capitals or all
  in small letters get proper capitals, keeping words like "de" small
  ("JOSÉ SARAMAGO" → "José Saramago", "sophia De mello" → "Sophia de
  Mello"); "Retorno, O" becomes "O Retorno".
- Rating a book could fail with "Goodreads rejected the rating (HTTP 404)";
  the app now rates through the same endpoint as the stars on the shelf
  page when the first one refuses, with a fresh token.
- Rate Unrated: the keyboard shortcuts rated the first book shown over and
  over instead of the one on screen. Books Goodreads won't take go back in
  the queue with the reason. Pick for Me had the same shortcut problem.
- The diagnostics log is also kept in a file.

## [3.0.0] — 2026-11-03

### Added

- **Calibre sync.** Your Calibre library is read along with Apple Books
  and Kobo: books are matched by Goodreads id, ISBN or title; their EPUBs
  and PDFs become your copies (left in Calibre, not copied); progress and
  highlights from Calibre's viewer come over; books not on a shelf can be
  added to Want to Read. Optionally, your stars, a "Goodreads: Read" style
  tag and the Goodreads id are written back into Calibre (while it's closed),
  keeping its other identifiers.
- **A new Home** that fits the window: what you're reading, this year's goal,
  **the race** — you and your friends running to your reading-challenge
  goals, with a finish line and where an even pace would be — your week
  (pages, days in a row, books finished this month) and what's next.
- **Your Year in Books**, redone like a story: one big fact at a time —
  books, pages, busiest month, top genre and author, shortest and longest,
  your average against everyone's, most popular and hidden gem, highest
  rated, first and latest, five-star books — then the card to share.
- **Your copy of a book**: add an EPUB or PDF to any book and open it in
  Apple Books.
- **Kobo sync**: plugging a Kobo in brings a notification to sync — send the
  books you've added files to, remove finished ones the app sent, bring
  progress and highlights over.
- **Custom stores** in Settings → Reading Apps, e.g.
  `https://www.wook.pt/pesquisa?keyword={bookname}`.
- **Finish by** a date: Home and the reminder say how many pages a day it takes.
- **Pick for Me** on Want to Read, and **Rate Unrated** on Read (1–5 keys).
- **Apple Books price alerts** for ebooks on Want to Read.
- **Add to Goodreads** in Safari's Share menu: finds the book on the page by
  its ISBN and adds it to Want to Read.
- **Notes and quotes in Spotlight.**
- **Profiles** — click a reviewer's name or picture (or a friend's) for their
  profile, now with much more: details and activity, their reading challenge,
  favourite genres and books, what they're reading, every shelf, quotes,
  friends, who they follow and their Year in Books.
- **Author pages** show birthplace and death, influences, reviews, works and
  followers, the full bio, their series (with the books in each), quotes and a
  link to their Wikipedia article (in Portuguese when there is one).
- **Apple Books and Kobo** — Reading Apps (File menu, or Settings) brings
  progress, finished books and books you started over to Goodreads, from
  Apple Books on this Mac and a Kobo plugged in by USB. It can run by itself,
  and can add books that aren't on your shelves. Kobo highlights can be
  imported too.
- **Where to Get It** adds Apple Books, Kindle and Kobo.

### Fixed

- Searching for an ISBN (with or without hyphens) finds the book: Google
  Books is asked for that ISBN, and Goodreads too when Google has nothing.
  Books on your shelves with that ISBN come first.

### Changed

- Settings are in tabs (General, Notifications, Reading Apps, Library,
  Troubleshooting); signing out and Export Library moved there.
- What's happening — results, Undo, offline, updates, Log In — shows at the
  foot of the sidebar instead of a bar at the bottom.
- Quotes is now **Notes**, and shows your note text too.
- Stats' goal counts books as Goodreads' Reading Challenge does.
- Search falls back to Goodreads when Google Books is down.
- Book Details, profiles and author pages no longer have a zoom (+) button.
- The Log moved to Settings → Troubleshooting, and the Browser button is off
  unless you turn it on there.
- The Reading Challenge goal is also read in the wording profiles use.

### Removed

- The menu bar icon.

## [2.7.0] — 2026-11-02

### Changed

- With a Google Books key set, Book Details takes the title, synopsis,
  publisher, date, pages and language from Google Books first — the reader's
  own edition by ISBN, else one in the app's language — and keeps Goodreads
  for ratings, reviews, awards, series and characters. The Goodreads title
  shows underneath when it differs.
- Book titles on shelves, Home, the menu bar and widgets come from Google
  Books by ISBN when there's a key, instead of whatever the edition was
  typed as on Goodreads. Titles without an ISBN that carry the author and
  publisher ("… de Author pela Publisher 1996") are trimmed.
- Genres are shown in Portuguese when the app is in Portuguese: on books, in
  the shelf filter, in Stats and in Your Year in Books.

### Fixed

- Widgets on a Liquid Glass or tinted desktop lost their covers and showed
  the progress bar as one solid line; covers stay pictures and the bar's
  filled part stands out in every mode.

## [2.6.0] — 2026-11-02

### Added

- **Pages** — Home shows which page you're on, how many are left and your
  pages a day; the progress window and the widget show pages too.
- **Friends reading it too** — on Home, the friends who have the same book on
  Currently Reading.
- **Smart lists** in a shelf's Filter menu: short books, highest rated on
  Goodreads, waiting the longest, and by authors you love.
- **Where to Get It** in Book Details: searches at Amazon, AbeBooks and
  libraries (OverDrive/Libby), plus Wook and Bertrand in Portugal.
- **Quotes** — a new pane with every quote and highlight you've saved,
  searchable, to copy or share as an image.
- **Automatic backups** — Settings → Backup can back up every week to iCloud
  Drive (or a folder you choose), keeping the last eight.
- **Text size** — the app follows the Mac's text size where macOS passes it
  on, and View → Bigger Text / Smaller Text (⌘+ / ⌘−) works everywhere.

- **Book Details** shows much more: the synopsis, Goodreads' average rating
  and star spread, genres, publisher, publication dates, format, ISBN,
  original title, illustrators and translators, awards, characters and
  setting.

### Changed

- Book pages that Goodreads' bot protection blocks are fetched again through
  your signed-in session, and whatever's still missing — synopsis,
  publisher, pages, genres, date, language — comes from Google Books. Page
  counts and genres for Home, smart lists and Stats use the same fallback.
- Clicking a book anywhere — shelves, search, suggestions, friends' shelves
  and updates — opens its details.
- The README is now a user guide; the technical notes moved to
  DEVELOPMENT.md.

### Removed

- The menu bar icon.

- The ⌥Space quick-add panel, and the menu bar's Quick Add item.

## [2.5.0] — 2026-11-02

### Added

- **Widgets** — Currently Reading (progress, finish estimates, covers) and
  Reading Goal, for the desktop and Notification Center.
- **Shortcuts and Siri** — What Am I Reading, Update Reading Progress, Mark
  Book as Read and Reading Goal Status.
- **Backup and restore** of what lives only on this Mac: notes and quotes,
  progress history and stopped books (Settings → Backup, or the File menu).
- **Import highlights** from Apple Books or a Kindle's My Clippings.txt into
  each book's notes and quotes.
- **Friends who read this** in Book Details, with their ratings.
- **Reading Challenge** — the Stats goal comes from your Goodreads Reading
  Challenge when you've joined it.
- **Stop reading** a book: keeps why and how far you got, moves it on
  Goodreads, and lists it in Stats with Resume Reading. It doesn't count as
  read.
- **install.sh** — installs the app from the `.dmg`, clears the
  downloaded-from-the-internet flag and signs it on your Mac, so the Keychain
  stops asking for your password after every update.

### Changed

- In-app updates are signed with the same certificate as the copy they
  replace, when it has one.

## [2.4.0] — 2026-11-01

### Added

- **Series** — Book Details shows a book's series and position, and the next
  volume with a one-click Want to Read.
- **Finish estimates** — when you'll finish each book at your pace so far, on
  Home and in the menu bar. The app now keeps a history of your progress
  updates.
- **Reading reminder** — a daily notification at a time you choose; type a
  percentage into it to update your progress.
- **Covers layout** for shelves, next to the list.
- **Shelf filters** — by your rating, year read and genre.
- **Search across your shelves** — matches from your own library come first.
- **My Order** for Want to Read: drag books into the order you'll read them;
  Home shows what's up next.
- **Notes and quotes** per book, kept on this Mac, kept through Clear Cache,
  and exported to CSV (two new columns).
- **Compare tastes** with a friend: books in common, how often you agree,
  where you disagree, and their favourites you haven't read.
- **New from your authors** in Suggestions, with optional notifications.
- **Your Year in Books** — a summary card for any year, saved as an image.

### Changed

- Clear Cache (and signing out) no longer touches your notes or progress
  history.

## [2.3.0] — 2026-11-01

### Added

- **Menu bar** — the menu lists what you're currently reading, with a progress
  bar for each; choosing one opens its progress update.
- **Spotlight** — books on your shelves show up in ⌘Space search, and open in
  the app (Settings → Spotlight turns it off).
- **Drag and drop** — drag a book onto a sidebar shelf to move it there.
- **Share** — share a book's Goodreads link from its row menu or its details.
- **What's new before updating** — the update button shows the release notes
  first, and the download has a progress bar.
- **Stats: pages and genres** — pages per year, pages this year and top
  genres, from each book's Goodreads page; *Fill In* fetches the missing ones.
- **Offline notice** — the status bar says when you're seeing saved data, and
  the pane refreshes once you're back online.

### Changed

- Proper plurals in English and Portuguese ("1 book", "1 livro").
- VoiceOver reads star ratings, book rows, the reading-progress cards and the
  charts sensibly; covers and avatars are skipped as decoration.
- Builds in the Swift 6 language mode. That turned up two possible data races
  in the cache, now fixed.
- Tests for the Goodreads page parsers, so markup changes show up in CI.

### Fixed

- The local build script could silently skip code signing when the project
  sat in an iCloud-synced folder.

## [2.2.0] — 2026-11-01

### Added

- **Stats** — a new pane with this year's reading goal (adjustable, with
  ahead/behind schedule and a per-month chart), books read, average rating,
  books per year, rating distribution and most-read authors.
- **Friend notifications** — optional (Settings): a macOS notification when a
  friend starts or finishes a book, checked hourly while the app is open.
- **One-click updates** — "Update to x.y.z" downloads the release, replaces
  the app and reopens it, falling back to the release page when the app
  can't replace itself.
- **European Portuguese** — the whole interface, chosen from the system
  language.
- **Settings → Cache** — shows the space used and clears it.

### Changed

- Pane buttons and the shelf filter moved into the window toolbar (glass on
  macOS 26); Book Details, Author and Profile sheets use glass headers, and
  Book Details shows a blurred cover behind its top.
- Faster: a few seconds after launch, never-cached shelves and the friend
  list are filled in; covers are fetched ahead of scrolling; recent searches
  are reused for ten minutes.
- No compiler warnings left, and the code builds cleanly in Swift 6 mode.
- `build-app.sh` stops with a clear message when no SDK it can use is
  installed.

### Fixed

- A friends refresh that came back empty (Goodreads changing its markup)
  replaced the good cached list; it no longer does.

## [2.1.0] — 2026-11-01

### Added

- **Liquid Glass** on macOS 26 and later, with the previous look on older
  systems.
- **Caching** of book pages, author pages, friends, profiles, friends'
  shelves, suggestions and author searches — shown instantly, refreshed in
  the background — and of decoded covers, which no longer blink on scroll.

### Added

- **Friends** — recent activity from your friends, grouped by friend; open
  a profile for their stats and more updates. A **Collections** view lets
  you browse a friend's own shelves (Want to Read / Currently Reading /
  Read) with their star ratings, the same way you'd browse your own.
- **Suggestions / Read Next** — recommendations built from the authors
  you've read most recently, excluding anything already shelved. One pick
  surfaces on Home; the full list lives in its own Suggestions pane.
- **Search via Google Books** — replaces reliance on Goodreads' bare
  `auto_complete` endpoint, adding language, publisher, and ISBN data
  Goodreads' own autocomplete doesn't report. Needs a free Google Books API
  key, kept in the Keychain. Without one, search now falls back to that same
  `auto_complete` endpoint instead of surfacing a quota error, so it still
  works — with less metadata — out of the box.
- **Book Details** — a sheet with a book's description, Google Books
  metadata, and a handful of Goodreads' own community reviews (scraped from
  the book page's embedded JSON). Post your own rating and review from
  here, or jump to the author's Goodreads page.
- **⌥Space quick panel** — a floating, global-hotkey search panel for
  shelving a book without opening the main window, plus a matching menu
  bar item. ↑/↓ now moves a highlight through the results and ⌘1/⌘2/⌘3
  shelves the highlighted book, so the mouse is optional.
- **Diagnostics log** — a copyable, in-app record of every request the app
  has made, for troubleshooting the scraping-based parts of the app.
- **CSV export** — per-shelf, or the whole library in one file, now
  including ISBN, ISBN13 (Excel-safe-wrapped, matching Goodreads' own
  export) and Date Added columns; a failed shelf during **Export
  Library…** is reported instead of just silently missing from the file.
- **In-app sign-in and Browser** — sign in on Goodreads' own page inside
  the app (the app never sees your password), and a debug view of whatever
  page it's currently driving.
- **Undo** for Remove and Move — a status-bar button for a few seconds
  after either action, running the same shelf calls in reverse.
- **Shelf sorting** — by title, author, rating, date read or date added, or
  Goodreads' own order, from a menu next to the filter box.
- **`selectors.json`** — user-editable extra CSS selectors for the four
  spots in "The fragile part" most likely to drift, so a `.dmg` install
  (not just a from-source build) can be patched when Goodreads' markup
  moves.
- **Update check** — a quiet, best-effort look at GitHub Releases on
  launch; a status-bar button appears when a newer build is out.
- Unit tests (`swift test`) for the app's pure logic — date parsing, CSV
  escaping, shelf sorting, the author-matching heuristic, version
  comparison — plus a CI workflow that builds and runs them on every push.

### Fixed

- Several scripts that read the live page could race a concurrent
  navigation on the shared web view — reading or writing against whichever
  page happened to load in between. Every such script now holds the
  navigation lock across its whole load-then-read sequence, not just the
  load.
- A navigation WebKit never calls back for (e.g. one that turns into a
  file download) could hang the app indefinitely with that lock held.
  Loads now carry their own timeout independent of WebKit's delegate
  callbacks.
- Rating a book silently moved it to the Read shelf — it now only posts
  the rating, matching what the UI already claimed it did.
- Removing a book from a shelf wasn't verified the way adding one is; it
  now is.
- Exporting the whole library could emit a stray blank line for each empty
  shelf, and could corrupt on any review text containing a newline. The
  combined CSV is now built from data rows directly instead of splitting
  each shelf's own header off after the fact.
- Shelf-load progress only ever updated once, at the very end, regardless
  of how many pages a shelf had. Pagination is now driven from Swift so
  progress updates as each page lands.
- The Friends pane's scrapers had drifted out from under Goodreads'
  current markup: the home-feed activity table no longer matches anything
  (confirmed against a real signed-in fetch), and the friend-list page's
  selectors were scoped under a wrapper class that no longer exists. The
  pane now falls back to each friend's own current-status line when the
  activity feed comes back empty.
- The ISBN-to-Goodreads-id lookup cache was a plain mutable dictionary
  shared across concurrent lookups — now an actor.
- `Package.swift` targeted `.macOS(.v11)` while the app (and its own build
  script) required macOS 13 APIs, so `swift build` didn't actually build.
- Smaller fixes: a failed hotkey registration could leave a duplicate
  event handler behind; the quick panel's search field didn't refocus on
  reopen; the book-detail and author-page sheets could fail to open one
  from inside the other; signing out didn't clear the persistent cookie
  store.
- A shelf write whose own read-back verification came back inconclusive
  (rather than confirming presence or absence) was silently treated as a
  clean success, with nothing logged — the fail-safe policy was right, but
  the caller had no way to know its "success" was actually unverified. Both
  add and remove now say so.
- An empty shelf and a shelf page Goodreads restructured out from under this
  app's selectors both showed "Nothing here yet." — now told apart by a
  generic (non-Goodreads-specific) check for whether the response even
  looked like a normal page.
- `WebSession.exclusive`'s lock briefly went back to "unlocked" between
  releasing it and waking the next queued caller — a window a brand-new
  caller could win, cutting in line ahead of whoever had actually been
  waiting. Ownership now hands off directly, with the lock never appearing
  free while anyone is still queued.
- A session that lapsed server-side went unnoticed until the next explicit
  sign-in check — shelf loads and writes now recognise Goodreads' own
  "signed out" redirect immediately and re-prompt instead of waiting.
- `exportEverything()` dropped any shelf that failed to load with no
  indication in the final "Exported N books" message.

### Changed

- The app icon now follows macOS's Dock icon proportions (content scaled
  to about 80% of the canvas, matching Safari/Finder) instead of filling
  the canvas edge-to-edge.
- Local builds are universal (arm64 + x86_64); a separate script builds a
  `.dmg` installer with its own background art and volume icon.
- The Google Books API key moved from a plaintext `UserDefaults` plist to
  the Keychain.
- The published repo is source-only (`Sources/`, `Package.swift`,
  `README.md`). Build scripts, icon assets, and release artifacts stay
  local; releases are distributed as prebuilt `.dmg`s on GitHub Releases
  instead.
- The shelf cache refreshes itself in the background after six hours
  instead of only ever refreshing when something else happened to trigger
  it.
- Every fetch-based read retries once or twice, with backoff, on a 429 or
  503 rather than treating a rate limit the same as any other failure.
- `AsyncImage`'s cache capacity is bumped well past its 512KB/10MB default
  at launch, so covers and avatars stop re-fetching on every pane switch or
  scroll-recycle.
- Eight sibling `.sheet` modifiers on `ContentView` — worked around with a
  dismiss-then-sleep-350ms-then-present hand-off, since SwiftUI won't stack
  a second sheet from the same modifier chain — are now one `.sheet(item:)`
  driven by a single `PresentedSheet` enum. Opening one sheet from inside
  another is instant.
