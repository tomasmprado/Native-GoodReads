# OpenShelf

A free, native Mac app for your Goodreads library. (It used to be called
Goodreads / Native GoodReads.)

**Website:** [tomasmprado.github.io/OpenShelf](https://tomasmprado.github.io/OpenShelf/) ·
[Guide](https://tomasmprado.github.io/OpenShelf/docs.html) ·
[What's new](https://tomasmprado.github.io/OpenShelf/changelog.html)

**Latest:** 3.2 — Discover learns from every swipe, reading streaks and a
streak widget, works offline, the next volume of what you've started, and a
bookcase in your books' own colours. [Every version](https://tomasmprado.github.io/OpenShelf/changelog.html)

## Features

- **Home**: what you're reading, your goal, a race with your friends, your
  reading streak and what to read next
- **Your shelves** as a list, a wall of covers or a bookcase of spines; a
  work's volumes show as one book
- **Suggestions that know your taste**, each saying why, and **Discover**:
  swipe through them one card at a time, ranked like a feed that learns from
  every swipe
- **A Bingo for the year** from what you rarely read, and **letters to
  yourself** that come back in a year
- **Book details**: synopsis, rating, series, reviews and the friends who
  read it
- **Friends**: what they're reading, their shelves, and how your tastes compare
- **Stats**: yearly goal, reading time, streaks, where your authors come from,
  and Your Year in Books
- **Notes, quotes and highlights** from Apple Books, Kobo, Calibre or Kindle
- **Works offline**: changes wait and go to Goodreads when you're back online
- **Widgets, Shortcuts and Siri**, Spotlight, Safari's Share menu and a
  barcode scanner

## Install

Requires macOS 13 or later.

1. Download **OpenShelf.dmg** and **install.sh** from the
   [latest release](../../releases/latest).
2. In Terminal, run:

   ```sh
   bash ~/Downloads/install.sh
   ```

3. Open the app and click **Log In**.

Or with [Homebrew](https://brew.sh):

```sh
b()(brew $1 tomasmprado/tap);b tap;b trust;brew instal openshelf;bash $(b --repo)/install.sh --resign
```

The last part signs the app on your Mac, so the Keychain stops asking for your
password after updates.

## Privacy

You sign in on Goodreads' own page; the app never sees your password. Your
notes stay on your Mac.

---

Not affiliated with Goodreads or Amazon. For developers: [DEVELOPMENT.md](DEVELOPMENT.md)
and the full [CHANGELOG.md](CHANGELOG.md).
