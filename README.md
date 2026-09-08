# Goodreads GUI

A small native macOS front end for [`yareeh/goodreads-cli`](https://github.com/yareeh/goodreads-cli).
SwiftUI, no dependencies, ~500 lines. Search a book, pick a shelf, done.

## How it's wired

Everything is native. There's no CLI, no Go, no Homebrew, no Chromium, and no
password on disk.

| Action | Path |
| --- | --- |
| Search | `URLSession` to `goodreads.com/book/auto_complete?format=json` |
| Sign in | `WKWebView` showing Goodreads' real sign-in page |
| Shelving | `WKWebView` — legacy AJAX endpoint first, page automation as fallback |
| Shelf contents | `/review/list?print=true`, the old table view, parsed in the page |
| Removing | same shelf endpoint with `a=remove` |
| Reading progress | `POST /user_status/create` |

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
open Goodreads.app
```

Command Line Tools is enough — no Xcode, no SwiftPM.

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

The sidebar has Search plus your three shelves.

**Search** — type, results appear as you pause, Return searches immediately.
The ••• button on a row adds it to a shelf.

**Shelves** — click one to load its contents. Each row's ••• menu offers:

- *Move to…* — the three main shelves are exclusive on Goodreads, so adding to
  one moves it off the others. That's how you change reading status.
- *Update Progress…* — currently-reading only. Percent or page, plus an optional
  note. Posts to your updates feed like the website does.
- *Remove from Shelf* — takes it off the shelf. Your review and rating survive;
  the book just stops being shelved.
- *Open on Goodreads*

Right-click does the same thing. The circular arrow reloads a shelf.

Sign in via **Log In** in the status bar.

Sessions persist across launches. **Browser** in the status bar opens the same
web view so you can watch what the app is doing — the equivalent of the CLI's
`--no-headless`.

## Limits worth knowing

- **First 100 books per shelf.** Goodreads paginates `/review/list` and this
  fetches one page. If your Read shelf is longer, you'll see the first hundred.
- **Only the three built-in shelves.** Custom shelves aren't in the sidebar,
  though the underlying endpoint handles them fine if you add cases to `Shelf`.
- **Removing isn't deleting.** A removed book keeps its review and rating on
  your profile. Deleting the review outright is a different endpoint.

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

The same applies to shelf listing and progress updates: both rely on legacy
Rails endpoints (`/review/list?print=true`, `/user_status/create`) that the site
still serves but no longer advertises. They're stable in a way the React UI
isn't, but they aren't a supported API, and Goodreads could retire them without
notice. If a shelf loads empty while the website shows books, open **Browser**
and look at what `/review/list?print=true&view=table` actually returns.

## Files

```
Package.swift          (unused by build-app.sh; kept for `swift build`)
build-app.sh
Sources/GoodreadsGUI/
  App.swift            entry point, window
  ContentView.swift    search bar, results, status bar, sheets
  LibraryModel.swift   state, debounced search, shelf actions
  SearchClient.swift   autocomplete JSON client
  WebSession.swift     shared WKWebView, cookies, sign-in state
  ShelfService.swift   shelving strategies
  WebViewHost.swift    SwiftUI wrapper + sign-in and browser sheets
  ShelfLibrary.swift   reads shelf contents
  ProgressSheet.swift  progress update UI
  Models.swift         Book, Shelf
```

## Migrating from the CLI version

The CLI, `~/.goodreads-cli.yaml`, and `~/.goodreads-cli-session` are no longer
used. Once this build works you can remove them:

```sh
brew uninstall goodreads-cli 2>/dev/null || rm -f ~/go/bin/goodreads*
rm -f ~/.goodreads-cli.yaml ~/.goodreads-cli-session
```

Delete the password file even if you keep the CLI around.

cd ~/Downloads/goodreads-gui

create-dmg \
  --volname "Goodreads" \
  --background "dmg-background.tiff" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 128 \
  --text-size 13 \
  --icon "Goodreads.app" 175 205 \
  --hide-extension "Goodreads.app" \
  --app-drop-link 485 205 \
  --no-internet-enable \
  --volicon "goodreads.icns" \
  Goodreads.dmg \
  Goodreads.app
