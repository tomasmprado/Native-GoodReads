# Goodreads GUI

A small native macOS front end for [`yareeh/goodreads-cli`](https://github.com/yareeh/goodreads-cli).
SwiftUI, no dependencies. Search a book, pick a shelf, done.

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

```sh
bash build-app.sh
```

Builds a universal (arm64 + x86_64) binary and opens the app when it's done —
no separate `open` step needed. Command Line Tools is enough — no Xcode, no
SwiftPM.

## Icon

`icon-source.png` is a placeholder. To use your own, drop any square PNG
(1024x1024 is ideal) over it and rebuild — `build-app.sh` runs `make-icon.sh`
automatically when there's no `AppIcon.icns` yet.

To swap an icon after one already exists:

```sh
rm AppIcon.icns
bash make-icon.sh path/to/your.png
bash build-app.sh
```

`make-icon.sh` uses `sips` and `iconutil`, both built into macOS. If the Dock
still shows the old icon, it's caching — drag the app somewhere else and back,
or log out and in.

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

### Home

Suggestions built from what you finished recently: the authors you've been
reading most, minus anything already on a shelf. No Goodreads recommendation API
worth using exists, so this works from what's visible.

Empty until you've marked something read inside the look-back window.

### Settings (⌘,)

**Book language** filters suggestions by edition language, read from each book
page's JSON-LD. This is about the books, not the interface — the app itself is
English only. Books whose language can't be determined can be included or hidden.

**Look back** sets how far "recently read" reaches: 30, 90, 180 days or a year.

**Google Books API key** — search and suggestions run against Google Books,
whose free unauthenticated tier is shared across every caller on the internet
and stays exhausted. Get a free key at console.cloud.google.com (enable the
"Books API", then Credentials → Create Credentials → API key) and paste it in;
it's kept in the Keychain, not on disk. Without one, search mostly returns a
quota error.

### Main window

The sidebar lists every shelf you have, custom ones included, with counts.

**Search** — type, results appear as you pause, Return searches immediately.

**Shelves** — click one to load it. Cached copies appear instantly while the
refresh runs behind them. The filter box narrows what's on screen without
touching the network.

Each row's ••• menu:

- *Update Progress…* — currently-reading only. Percent or page, plus a note.
- *Mark Read & Rate…* — rating, finish date and an optional review, all in one
  post. This is the right way to finish a book; a bare shelf move leaves it
  unrated, which is the one thing Goodreads actually wants from you.
- *Rate* — stars on their own, for books already shelved.
- *Move to* — any shelf. The three built-ins are exclusive, so moving between
  them changes reading status. Custom shelves stack instead.
- *Remove from Shelf*, *Open on Goodreads*

### Export

Per-shelf CSV from the toolbar icon, or **Export Library…** at the bottom of the
sidebar, which walks every shelf and writes one file. Columns match the
Goodreads export format closely enough to import elsewhere.

Worth doing occasionally. This app rests on undocumented endpoints, Goodreads
could retire them whenever, and Amazon has let the site rot for a decade. A
local copy is cheap insurance.

## Limits worth knowing

- **Removing isn't deleting.** A removed book keeps its review and rating on
  your profile. Deleting the review outright is a different endpoint.
- **Paging stops at 2500 books** (25 pages of 100) as a safety stop. Raise
  `maxPages` in `ShelfLibrary.swift` if your library is bigger.
- **The cache is never invalidated on its own.** It shows you the last fetch and
  refreshes in the background; it doesn't expire. Sign Out clears it.
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
of the second strategy. That's a one-line fix.

Strategy 1 failing silently is the good case: it falls through to 2.

Shelf listing relies the same way on `/review/list?print=true`, a legacy Rails
endpoint the site still serves but no longer advertises — stable in a way the
React UI isn't, but not a supported API, and Goodreads could retire it without
notice. If a shelf loads empty while the website shows books, open **Browser**
and look at what `/review/list?print=true&view=table` actually returns.

Reading progress is worse off: `/user_status/create`, the endpoint this used to
go through, is confirmed gone (404, even signed out) — the control moved off
the book page entirely, onto a widget on the Goodreads home feed, one per
currently-reading book. `ShelfService.swift` still tries the old endpoint first
(costs nothing, in case Goodreads brings it back) and falls through to driving
that home-feed widget, the same click-and-read-the-DOM-back approach as
shelving's strategy 2.

## Files

```
Package.swift          (unused by build-app.sh; kept for `swift build`)
build-app.sh
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
  GoodreadsFriends.swift  friends list, activity feed, friend profiles
  WebSession.swift        shared WKWebView, cookies, sign-in state, locking
  ShelfService.swift      shelving, rating, progress — the write path
  WebScripts.swift        shared JS (fetch + DOMParser helpers)
  WebViewHost.swift       SwiftUI wrapper + sign-in and browser sheets
  ShelfLibrary.swift      reads shelf contents, paginated; shelf discovery
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
```

## Migrating from the CLI version

The CLI, `~/.goodreads-cli.yaml`, and `~/.goodreads-cli-session` are no longer
used. Once this build works you can remove them:

```sh
brew uninstall goodreads-cli 2>/dev/null || rm -f ~/go/bin/goodreads*
rm -f ~/.goodreads-cli.yaml ~/.goodreads-cli-session
```

Delete the password file even if you keep the CLI around.
