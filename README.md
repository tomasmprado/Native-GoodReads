# Goodreads for Mac

A simple, native Mac app for your Goodreads library. See what you're reading,
update your progress, find your next book and keep up with your friends —
without opening the Goodreads website.

The app is in English and European Portuguese, following your Mac's language.

- [Install](#install)
- [Getting started](#getting-started)
- [What you can do](#what-you-can-do)
- [Widgets, Shortcuts and Siri](#widgets-shortcuts-and-siri)
- [Settings](#settings)
- [Your data and privacy](#your-data-and-privacy)
- [Questions and problems](#questions-and-problems)

## Install

You need a Mac with macOS 13 Ventura or later.

1. Go to the [latest release](../../releases/latest) and download both
   **Goodreads.dmg** and **install.sh** into your Downloads folder.
2. Open **Terminal** (it's in Applications → Utilities), paste this line and
   press Return:

   ```sh
   bash ~/Downloads/install.sh
   ```

The app is copied into your Applications folder and opens. The first time,
your Mac may ask for your login password so the app can use the Keychain —
type it and choose **Always Allow**. It won't ask again, not even after
updates.

<details>
<summary>What does install.sh do?</summary>

The app isn't sold through the App Store, so macOS doesn't know it. The script
takes care of that on your Mac only:

- it copies the app to Applications (and closes it first if it's open);
- it tells macOS the app is safe to open, so you don't get *"Goodreads" can't
  be opened* warnings;
- it gives the app a signature that stays the same from version to version,
  so the Keychain doesn't keep asking for your password.

Nothing is sent anywhere and it doesn't need your administrator password.

If you'd rather not use it: open the .dmg, drag Goodreads to Applications,
then right-click the app → **Open** the first time. You may see the Keychain
password prompt again after each update.

</details>

### Updating

When a new version is out, an **Update** button appears at the bottom of the
window. Click it to see what's new, then install — the app replaces itself
and reopens.

### Removing the app

Drag Goodreads from Applications to the Bin. To remove the signing certificate
the installer made, run `bash ~/Downloads/install.sh --remove-certificate`.

## Getting started

1. Open the app and click **Log In** at the bottom of the window.
2. Sign in on Goodreads' own page, the same way you do on the website. Your
   password goes only to Goodreads — the app never sees it.
3. Your shelves appear in the sidebar. That's it.

**Tip:** for better search results, add a free Google Books key in Settings
(see [Settings](#settings)). Search works without one, but shows less about
each book.

## What you can do

### Home

What you're reading right now, with your progress and — once you've updated it
a couple of times — roughly when you'll finish. There's also a book suggestion
picked from the authors you've read lately, and the next book on your Want to
Read list if you've put it in order.

Right-click a book on Home to update your progress, mark it as read, stop
reading it, or see its details.

### Your shelves

Every shelf you have is in the sidebar, including your own custom shelves,
with how many books each holds.

- **Click a book** to see everything about it (see [Book details](#book-details)).
- Switch between a **list** and a **wall of covers** from the toolbar.
- **Sort** by title, author, rating or date, and **filter** by your rating,
  the year you read it, or genre.
- On **Want to Read**, choose *My Order* and drag books into the order you'll
  read them.
- **Drag** a book onto another shelf in the sidebar to move it there.
- Each book's **•••** menu lets you update progress, mark it read and rate it,
  give it stars, move it, share it, or remove it. Moving or removing a book
  shows an **Undo** button for a few seconds.

### Book details

Click any book — on a shelf, in search, in suggestions, or in a friend's
updates — to open its page:

- the **synopsis**, with Goodreads' **average rating** and how the stars are
  spread;
- **genres**, the **publisher**, publication dates, pages, format, language,
  ISBN, and who illustrated, translated or edited it;
- **awards**, the main **characters** and where it's **set**;
- the **series** it belongs to, and the next book in it, which you can add to
  Want to Read in one click;
- **friends who read it**, with the stars they gave;
- a few **reviews** from other readers, and a box to post your own rating and
  review;
- **your notes and quotes** — private, kept on your Mac.

Click the author's name to see their bio and their other books.

### Search

Type a title or author. Books already on your shelves appear first, with the
shelf they're on. Use the filters to narrow by language, subject or the newest
books. From any result you can add the book to a shelf, mark it read, or open
its details.

### Suggestions

Books by authors you've read recently that aren't on your shelves yet, and
**New from Your Authors**: books just out or coming soon by writers you've
read more than once.

### Friends

Your friends' latest reading updates. Click a friend to see their profile,
browse their shelves, or **Compare Tastes** — how many books you've both read,
how often you agree, where you disagree most, and the books they loved that
you haven't read yet.

### Stats

Your reading at a glance: this year's goal and whether you're ahead or behind,
books per month and per year, your average rating, pages read, favourite
authors and genres. If you've joined the **Goodreads Reading Challenge**, its
goal is used automatically.

**Your Year in Books** (the gift button) sums up any year as a card you can
save as an image and share.

Books you stopped reading are listed here too, with **Resume Reading**.

### Stopping a book

Not enjoying a book? Choose **Stop Reading…** from its menu. Note why, if you
like, and choose whether it goes back to Want to Read or off your shelves. The
app remembers how far you got, and it doesn't count as read. If you have a
shelf called *dnf* or *abandoned*, it's added there too.

### Notes, quotes and highlights

Every book has a private **My Notes** box for your thoughts and favourite
quotes.

**File → Import Highlights…** brings in what you highlighted in **Apple Books**
on this Mac, or on a **Kindle** (connect it and choose
`documents/My Clippings.txt`). Each highlight lands as a quote in the right
book's notes. Importing twice doesn't create duplicates.

### Export

**Export Library…** at the bottom of the sidebar saves every shelf to one
spreadsheet file (CSV), in a format close to Goodreads' own export. The
toolbar button on a shelf exports just that shelf. It's a good idea to keep a
copy now and then.

### Menu bar

The books icon in the menu bar lists what you're reading, with a progress bar
and finish estimate for each. Choose one to update your progress. The app keeps
running there when you close its window, so notifications and widgets stay up
to date.

### Spotlight

Your books show up when you search with ⌘Space. Choosing one opens it in the
app.

## Widgets, Shortcuts and Siri

**Widgets** — right-click your desktop, choose **Edit Widgets**, and search for
Goodreads:

- **Currently Reading** — your books with progress, covers and finish dates
  (small, medium and large);
- **Reading Goal** — books read this year against your goal.

They update whenever something changes in the app.

**Shortcuts and Siri** — in the Shortcuts app, search for Goodreads to use:
*What Am I Reading*, *Update Reading Progress*, *Mark Book as Read* and
*Reading Goal Status*. You can also ask Siri, in English — for example
"What am I reading in Goodreads".

## Settings

Open them with **⌘,** (or Goodreads → Settings).

- **Suggestions** — which language suggested books should be in, and how far
  back "recently read" goes.
- **Google Books** — a free key that makes search and suggestions work better.
  To get one: go to console.cloud.google.com, enable the *Books API*, then
  *Credentials → Create Credentials → API key*, and paste it here. It's kept
  safely in your Keychain.
- **Notifications** — when a friend starts or finishes a book, and when an
  author you read has a new book.
- **Reading Reminder** — a daily nudge at the time you choose. Type a
  percentage straight into the notification to update your progress.
- **Reading Goal** — use your Goodreads Reading Challenge goal, or set your
  own in Stats.
- **Spotlight** — show or hide your books in ⌘Space search.
- **Backup** — save your notes, quotes, progress history and stopped books to
  a file, and restore them later (also in the File menu). Keep the file
  somewhere safe, like iCloud Drive — these exist only on your Mac.
- **Cache** — how much space the app uses to stay fast, and a button to clear
  it. Clearing is safe: everything is downloaded again when needed, and your
  notes are kept.

## Your data and privacy

- You sign in on Goodreads' own page; the app never sees or stores your
  password.
- Your shelves, ratings and reviews live on Goodreads, as always. The app
  keeps a copy on your Mac so it opens instantly.
- Your **notes, quotes, progress history and stopped books** are only on your
  Mac. Use **Settings → Backup** to keep a copy.
- Your Google Books key is kept in the Keychain.
- The app talks only to Goodreads, Google Books and GitHub (to check for
  updates). There's no tracking and no account of its own.

## Questions and problems

**The Mac keeps asking for my Keychain password.**
Run the installer again (`bash ~/Downloads/install.sh`) and choose **Always
Allow** once. If you installed by dragging the app, this is expected after each
update.

**"Goodreads" can't be opened because it's from an unidentified developer.**
Use the installer, or right-click the app → **Open**, or go to System Settings
→ Privacy & Security and click **Open Anyway**.

**Search finds nothing, or says the quota is used up.**
Add a Google Books key in Settings — the free shared one is almost always busy.

**A shelf or my friends' updates look empty or out of date.**
Click the reload button in the toolbar. If it's still wrong, Goodreads may
have changed its website: click **Log** at the bottom of the window, copy it,
and [open an issue](../../issues) with it.

**Friends Who Read This doesn't show anyone.**
It reads your friends' shelves in the background the first time, which can
take a minute. Friends whose shelves are private won't appear.

**The widget is empty.**
Open the app once — the widget shows what the app last saw.

**I'm offline.**
The app shows what it saved last time and says so at the bottom of the window.
It refreshes on its own when you're back online.

---

Building the app yourself, or curious how it works? See
[DEVELOPMENT.md](DEVELOPMENT.md).
