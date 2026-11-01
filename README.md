# Goodreads GUI

A small native macOS front end for [`yareeh/goodreads-cli`](https://github.com/yareeh/goodreads-cli).
SwiftUI, no dependencies. Search a book, shelve it, see what your friends are
reading — done.

## How it's wired

Everything is native. There's no CLI, no Go, no Homebrew, no Chromium, and no
password on disk.

| Action | Path |
| --- | --- |
| Search | Google Books' `volumes` API (language, publisher, ISBN — Goodreads' own autocomplete reports none of these) |
| Sign in | `WKWebView` showing Goodreads' real sign-in page |
| Shelving | `WKWebView` — legacy AJAX endpoint first, page automation as fallback |
| Shelf contents | `/review/list?print=true`, the old table view, parsed in the page |
| Removing | same shelf endpoint with `a=remove` |
| Reading progress | home-feed widget automation (`/user_status/create` is confirmed gone — see below) |
| Rating + date read | `POST /review/create` |
| Shelf discovery | shelf links scraped from the My Books sidebar |
| Suggestions | recent Read shelf → author search → edition language check |

A plain, unauthenticated Goodreads `auto_complete` search is still in the app
(`SearchClient.swift`) as `GoodreadsLookup`'s last-resort way to find a
Goodreads id for a book that has no ISBN.

Reads happen through `fetch` + `DOMParser` from inside one resident page, not by
navigating the web view. Navigation is stateful and serial — two jobs sharing
one web view end up scraping each other's pages — so the only navigation left is
sign-in and the DOM fallback. Shelf pages are fetched four at a time.

Every write is verified: the shelf is read back, newest first, and the book has
to actually be there. Goodreads will happily return HTTP 200 and do nothing, and
a silent no-op is worse than an error.

WebKit does what rod did, but it's part of macOS. Practical differences:

- **No install step.** Nothing to `brew install`, no PATH to fix.
- **No stored password.** You sign in on Amazon's own page. The app only ever
  holds a session cookie, in its own `WKWebsiteDataStore`.
- **CAPTCHA and 2FA just work**, because you're looking at the page. That was
  the CLI's hardest failure mode.
- **Much faster.** Shelving reuses one warm web view instead of spawning a
  process and launching a browser each time.

## Build

Prebuilt releases — a `.dmg`, drag to Applications — are on the
[Releases](../../releases) page. That's the easiest way to get the app, and
what most people want.

To build from source instead:

```sh
swift build -c release
.build/release/GoodreadsGUI
```

Needs a full Xcode install, not just the Command Line Tools — SwiftPM calls
`xcrun --sdk macosx --show-sdk-platform-path`, which only Xcode ships (the
Command Line Tools package alone doesn't have a `Platforms/` directory to
resolve). If `swift build` fails with `xcrun: error: unable to lookup item
'PlatformPath'`, that's it: install Xcode from the App Store, or point
`xcode-select` at one you already have (`sudo xcode-select -s
/Applications/Xcode.app`), then retry. `open Package.swift` in Xcode works
the same way, and sidesteps the command line entirely.

This gets you a running app, not a proper signed `.app` bundle: no custom
Dock icon, no Info.plist, no code signing. Bundling, icon generation, and
`.dmg` packaging happen in the maintainer's own local tooling, which isn't
part of this repo — grab a Release if you want that experience without
assembling it yourself.

### Tests

```sh
swift test
```

Needs the same full Xcode install as `swift build` (Command Line Tools alone
can't resolve `XCTest`). CI runs this for real on every push and PR, on a
GitHub-hosted runner that does have full Xcode. The suite only covers pure
logic — date parsing, CSV escaping, shelf sorting, the author-matching
heuristic — not the WebKit-driven scraping and shelving, which has no
practical way to run headless against Goodreads' real markup; that's still
what **Browser** and **Log** are for.

## Using it

### ⌥Space — the reason this exists

Press ⌥Space anywhere. A panel appears, you type, you click a shelf icon, it's
gone. No browser tab, no Dock icon, no window management. Everything else here
is a nicer version of something the website already does; this is the part the
website can't do.

There's also a menu bar item with the same thing, plus a way back to the main
window.

The hotkey uses Carbon's `RegisterEventHotKey`, which is ancient but is the only
route that doesn't demand Accessibility permission. If another app already owns
⌥Space it silently loses the race — check Console for the warning, and change
the key in `HotKey.swift`.

Keyboard, once results appear: ↑/↓ moves the highlight, ⌘1/⌘2/⌘3 shelves the
highlighted book to Want to Read/Currently Reading/Read. The mouse still works
too — the point is not needing it.

### Home

A "Read Next" card — one pick from what you've been reading most, minus
anything already on a shelf — plus a horizontal carousel of whatever's on
Currently Reading, with a shortcut to update progress on each.

The full list behind that one pick lives in its own **Suggestions** pane in
the sidebar. No Goodreads recommendation API worth using exists, so both work
off what's visible: the authors you've finished recently.

Empty until you've marked something read inside the look-back window.

### Settings (⌘,)

**Book language** filters suggestions by edition language, read from each book
page's JSON-LD. This is about the books, not the interface. Books whose
language can't be determined can be included or hidden.

**Interface language** follows macOS: the app is in English and European
Portuguese, picked from System Settings → General → Language & Region (or per
app, under Applications there). Translations live in
`Sources/GoodreadsGUI/Resources/pt.lproj/Localizable.strings`.

**Friends** — optionally, a notification when a friend starts or finishes a
book. Checked whenever the friend list refreshes and every hour while the app
is open; the first check only records what's there, so turning it on is quiet.

**Cache** shows how much the app keeps on disk (shelves, book and author pages,
friends, covers) and clears it. Clearing is safe — everything is fetched again
the next time it's opened.

**Look back** sets how far "recently read" reaches: 30, 90, 180 days or a year.

**Google Books API key** — search and suggestions run against Google Books,
whose free unauthenticated tier is shared across every caller on the internet
and stays exhausted. Get a free key at console.cloud.google.com (enable the
"Books API", then Credentials → Create Credentials → API key) and paste it in;
it's kept in the Keychain, not on disk. Without one, search falls back to
Goodreads' own unauthenticated `auto_complete` endpoint instead of surfacing a
quota error — you lose language, publisher and ISBN data on results found
that way, but search still works out of the box. A key set here fixes that
and is generally worth adding.

### Main window

The sidebar lists every shelf you have, custom ones included, with counts.

**Search** — type, results appear as you pause, Return searches immediately.

**Shelves** — click one to load it. Cached copies appear instantly while the
refresh runs behind them, and refresh again on their own after six hours even
if you never touch them. The filter field in the toolbar narrows what's on
screen without touching the network; the sort menu next to it reorders by
title, author, rating, date read or date added, or leaves Goodreads' own shelf
order alone.

**Stats** — this year's reading goal (set it right there; it shows whether
you're ahead or behind schedule, with a per-month chart), books read, average
rating, books per year, your rating distribution and most-read authors. All
worked out from the Read shelf; Goodreads' shelf pages carry no page counts,
so everything is counted in books.

On macOS 26 the app uses Liquid Glass: the sidebar floats, pane buttons sit in
the glass toolbar, and cards and the ⌥Space panel are glass. Older macOS keeps
the previous look.

Each row's ••• menu:

- *Update Progress…* — currently-reading only. Percent or page, plus a note.
- *Mark Read & Rate…* — rating, finish date and an optional review, all in one
  post. This is the right way to finish a book; a bare shelf move leaves it
  unrated, which is the one thing Goodreads actually wants from you.
- *Rate* — stars on their own, for books already shelved.
- *Move to* — any shelf. The three built-ins are exclusive, so moving between
  them changes reading status. Custom shelves stack instead.
- *Remove from Shelf*, *Open on Goodreads*

Removing and moving both offer an **Undo** button in the status bar for a few
seconds afterward — the same shelf calls run in reverse, not a local-only
revert, so it's a real Goodreads write either way.

*View Details…* opens a book's description, Google Books metadata, and a
handful of Goodreads' own community reviews — scraped from the book page's
embedded JSON, not the CLI-era HTML. You can post your own rating and review
right there; like every other rating action in the app, it moves the book to
Read. Tapping the author's name opens their Goodreads author page (bio,
stats, their other books) in its own sheet.

### Friends

Your friends' recent activity, grouped by friend. Tap a name to open their
profile — avatar, stats, and more of their updates. Both views are scraped
from authenticated pages, so this is the one pane that costs a real page
load every time it's opened.

From a friend's profile, **Collections** lets you browse their own shelves —
Want to Read, Currently Reading, Read — the same way you'd browse your own,
ratings included. It's the same `/review/list` page Goodreads serves for your
own shelves, just keyed to their id instead.

Goodreads' home-feed activity table has drifted out from under the selectors
this scrapes for it, so the activity list can come back empty even when your
actual Home feed shows updates. When that happens the Friends pane falls back
to each friend's own current-status line instead (what they're reading right
now, pulled from their profile page, which has stayed put) — see
[The fragile part](#the-fragile-part).

### Troubleshooting

Two buttons in the status bar, for when a scrape or a write doesn't do what
it should:

- **Browser** shows the live page the app is actually driving — the
  fastest way to see what Goodreads served instead of what the app expected.
- **Log** is a running, copyable record of every request the app has made
  (shelf loads, writes, verification checks), including ones that failed
  silently. Paste it when something breaks.

An **Update to X.Y** button appears in the same status bar when a newer
version is out on [Releases](../../releases) — a quiet, best-effort check
against the GitHub API on launch, silent on any failure (offline, rate
limited). Clicking it downloads the release's `.dmg`, checks the app inside is
Goodreads at that version, swaps it for the running copy and reopens. The old
copy is put back if anything goes wrong. When the app can't replace itself —
run straight from the disk image, or from Downloads before being moved — the
button opens the release page instead.

### Export

Per-shelf CSV from the toolbar icon, or **Export Library…** at the bottom of the
sidebar, which walks every shelf and writes one file. Columns (`Book Id,
Title, Author, ISBN, ISBN13, My Rating, Date Read, Date Added, Shelf`) match
Goodreads' own export format closely enough to import elsewhere; ISBNs are
wrapped `="0439023483"` the same way Goodreads' export does, so a spreadsheet
treats them as text instead of mangling a leading zero or a 13-digit number
into scientific notation. **Export Library…** also tells you if any shelf
failed to read rather than just quietly leaving it out of the file.

Worth doing occasionally. This app rests on undocumented endpoints, Goodreads
could retire them whenever, and Amazon has let the site rot for a decade. A
local copy is cheap insurance.

## Limits worth knowing

- **Removing isn't deleting.** A removed book keeps its review and rating on
  your profile. Deleting the review outright is a different endpoint.
- **Paging stops at 2500 books** (25 pages of 100) as a safety stop. Raise
  `maxPages` in `ShelfLibrary.swift` if your library is bigger.
- **Everything is cached and refreshes in the background**: shelves after six
  hours, friends after one, book pages after a day, author pages after three.
  The last copy shows immediately either way; a failed refresh keeps it on
  screen. A few seconds after launch the app also fills in any shelf or
  friends list it has never fetched. Sign Out (or Settings → Clear Cache)
  clears it all.
- **Custom shelves aren't exclusive**, so "Move to" a custom shelf adds without
  removing. That's Goodreads' behaviour, not a bug here.

## The fragile part

Shelving tries two things:

1. `POST /shelf/add_to_shelf.json` with the page's CSRF token. DOM-independent,
   fast, and works if Goodreads still honours the legacy endpoint.
2. If that fails, it finds and clicks the shelf control in the page.

**Strategy 2's selectors are educated guesses.** I couldn't inspect Goodreads'
current markup while writing this, so `[data-testid="wantToReadButton"]` and
friends in `ShelfService.swift` may not match what's actually served. If
shelving fails with "Could not find the shelf control", open **Browser**, load a
book page, and check the real element — then update the selector list at the top
of the second strategy. That's a one-line fix if you're building from source.

Running the prebuilt `.dmg` instead? `SelectorOverrides.swift` reads extra
selectors — tried before the built-ins, so a working override doesn't need to
oust anything — from a JSON file at
`~/Library/Application Support/GoodreadsGUI/selectors.json`:

```json
{ "shelfOpener": ["button.someNewClassName"] }
```

`shelfOpener`, `shelfDropdown`, `activityRow` and `friendCard` are the four
lists it reads, matching the four fragile spots below; relaunch after editing.
No Xcode, no rebuild.

Strategy 1 failing silently is the good case: it falls through to 2.

Shelf listing relies the same way on `/review/list?print=true`, a legacy Rails
endpoint the site still serves but no longer advertises — stable in a way the
React UI isn't, but not a supported API, and Goodreads could retire it without
notice. If a shelf loads empty while the website shows books, open **Browser**
and look at what `/review/list?print=true&view=table` actually returns — the
app itself tries to tell the two apart (a page that doesn't even look like a
shelf page gets its own error instead of "Nothing here yet."), but that check
is a generic heuristic, not a guarantee.

Every fetch-based read in here also retries once or twice, with backoff, on a
429 or 503 — Goodreads answering a burst of requests (four shelf pages at
once, or a full-library export) with a rate limit rather than throttling the
connection itself turns into a slower load instead of pages that come back
mysteriously empty.

Reading progress is worse off: `/user_status/create`, the endpoint this used to
go through, is confirmed gone (404, even signed out) — the control moved off
the book page entirely, onto a widget on the Goodreads home feed, one per
currently-reading book. `ShelfService.swift` still tries the old endpoint first
(costs nothing, in case Goodreads brings it back) and falls through to driving
that home-feed widget, the same click-and-read-the-DOM-back approach as
shelving's strategy 2.

Friends' activity feed is the confirmed-broken case, not just a suspected
one: `GoodreadsFriends.swift`'s selector for the home feed's newsfeed table
(`table.newsfeedUpdates tr.update[data-timestamp]`) no longer matches
anything, even though the page still visually shows friend updates — Goodreads
restructured that section at some point without changing what it looks like.
The `/friend` page's own markup (`.friendInfo`, `.statuses`), by contrast, was
checked against a real signed-in fetch and is current as of this writing,
which is why the Friends pane now leans on that instead. If it goes stale too,
the fix is the same as strategy 2's: open **Browser**, load `/friend`, and
update the selectors at the top of `friendsScript` (`activityRow` and
`friendCard` in `selectors.json`, for the no-Xcode version of that fix).

## Files

```
Package.swift           swift build entry point
Sources/GoodreadsGUI/
  App.swift               entry point, window
  ContentView.swift       search bar, results, status bar, sheets
  LibraryModel.swift      state, debounced search, shelf actions
  Models.swift            Book, Shelf, ShelfEntry
  SearchClient.swift      Goodreads auto_complete client (last-resort id lookup)
  GoogleBooksClient.swift search and author lookups via Google Books
  GoodreadsLookup.swift   resolves a Book to a Goodreads id (cached)
  GoodreadsBookPage.swift book detail: language, author link, reviews
  GoodreadsAuthorPage.swift author bio, stats, and their books
  GoodreadsFriends.swift  friends list, activity feed, friend profiles, a friend's own shelves
  WebSession.swift        shared WKWebView, cookies, sign-in state, locking
  ShelfService.swift      shelving, rating, progress — the write path
  WebScripts.swift        shared JS (fetch + DOMParser helpers)
  WebViewHost.swift       SwiftUI wrapper + sign-in and browser sheets
  ShelfLibrary.swift      reads shelf contents, paginated; shelf and friend-shelf discovery
  ShelfCache.swift        on-disk JSON cache
  CSVExport.swift         CSV generation and save panel
  Suggestions.swift       "Read Next" recommendation building
  Preferences.swift       settings window, language filter, API key
  Keychain.swift          Keychain wrapper for the API key
  Diagnostics.swift       request log, for troubleshooting
  BookDetailView.swift    book detail sheet: metadata, reviews, rate/review
  ProgressSheet.swift     progress update UI
  FinishSheet.swift       rating, finish date, review
  HotKey.swift            Carbon global hotkey
  QuickPanel.swift        floating panel + compact search
  AppDelegate.swift       menu bar item, hotkey wiring
  SelectorOverrides.swift user-editable extra CSS selectors (selectors.json)
  UpdateChecker.swift     checks GitHub Releases for a newer build
Tests/GoodreadsGUITests/  unit tests for the pure logic above (`swift test`)
```

## Migrating from the CLI version

The CLI, `~/.goodreads-cli.yaml`, and `~/.goodreads-cli-session` are no longer
used. Once this build works you can remove them:

```sh
brew uninstall goodreads-cli 2>/dev/null || rm -f ~/go/bin/goodreads*
rm -f ~/.goodreads-cli.yaml ~/.goodreads-cli-session
```

Delete the password file even if you keep the CLI around.
