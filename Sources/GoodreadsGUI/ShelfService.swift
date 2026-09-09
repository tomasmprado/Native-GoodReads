import Foundation

/// Writes to Goodreads without leaving the app.
///
/// Each operation tries a legacy Rails endpoint first — DOM-independent and
/// fast — and falls back to driving the page the way a person would, which is
/// what the CLI's rod automation did.
enum ShelfService {

    // MARK: - Shelving

    static func add(bookID: String, to shelf: Shelf) async throws {
        let session = WebSession.shared
        try await session.ensureResident()

        // Phase 1: the endpoint. Fetch-based (see `WebScripts.dom`), so it
        // doesn't need the page it runs against to be any particular page.
        let endpointRaw = try await session.evaluate(
            addEndpointScript,
            arguments: ["shelf": shelf.name, "bookId": bookID],
            label: "add \(bookID) -> \(shelf.name)"
        )

        if let result = decode(endpointRaw), result.ok {
            // HTTP 200 doesn't mean it happened. Check.
            if try await isOnShelf(bookID: bookID, shelf: shelf) { return }
            await Diagnostics.shared.log("verify add", "endpoint claimed success but book isn't on \(shelf.name)", ok: false)
        }
        let endpointError = decode(endpointRaw)?.error ?? "endpoint reported success but nothing changed"

        // Phase 2: drive the book page, the way the CLI's automation did.
        // This script reads the live `document`, so the load and the
        // evaluate that depends on it must happen under one lock — otherwise
        // another task's navigation can land the page on something else in
        // between and the script reports "no shelf control found" against
        // the wrong page entirely.
        guard let url = URL(string: "https://www.goodreads.com/book/show/\(bookID)") else {
            throw AppError("Bad book ID.")
        }
        let domRaw = try await session.exclusive { () -> String in
            try await session.load(url)
            return try await session.evaluate(
                addDOMScript,
                arguments: ["shelf": shelf.name, "bookId": bookID, "label": shelf.label],
                label: "add via page \(bookID)"
            )
        }

        if let result = decode(domRaw), result.ok {
            if try await isOnShelf(bookID: bookID, shelf: shelf) { return }
        }
        let domError = decode(domRaw)?.error ?? "page automation didn't take effect"

        throw AppError("\(endpointError); \(domError)")
    }

    private enum ShelfPresence { case present, absent, unknown }

    /// Reads the shelf back, newest first, and looks for the book — fetch
    /// based, so it's safe to run without the lock. Distinguishes a
    /// *confirmed* absence/presence from an inconclusive check, so callers
    /// can fail safe in whichever direction avoids reporting a false
    /// negative for their own action.
    private static func shelfPresence(bookID: String, shelf: Shelf) async throws -> ShelfPresence {
        let raw = try await WebSession.shared.evaluate(
            verifyScript,
            arguments: ["shelf": shelf.name, "bookId": bookID],
            label: "verify \(bookID) on \(shelf.name)"
        )

        guard let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(VerifyResult.self, from: data),
              result.ok else {
            return .unknown
        }
        return (result.present == true) ? .present : .absent
    }

    /// Cheap enough to run after every write, and it's the difference between
    /// a silent no-op and an error you can act on.
    static func isOnShelf(bookID: String, shelf: Shelf) async throws -> Bool {
        switch try await shelfPresence(bookID: bookID, shelf: shelf) {
        case .present, .unknown:
            // If the check itself is inconclusive, don't claim the write failed.
            return true
        case .absent:
            return false
        }
    }

    private struct VerifyResult: Decodable {
        let ok: Bool
        let present: Bool?
        let error: String?
    }

    private static func decode(_ raw: String) -> ScriptResult? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ScriptResult.self, from: data)
    }

    /// Removing is the same legacy endpoint with `a=remove`, verified the
    /// same way an add is — but only a *confirmed* "still there" counts as a
    /// failure; an inconclusive check shouldn't turn a successful remove into
    /// a reported error.
    static func remove(bookID: String, from shelf: Shelf) async throws {
        let session = WebSession.shared

        let raw = try await session.exclusive { () -> String in
            try await session.ensureOnGoodreads()
            return try await session.evaluate(
                removeScript,
                arguments: ["shelf": shelf.name, "bookId": bookID]
            )
        }
        try check(raw)

        if try await shelfPresence(bookID: bookID, shelf: shelf) == .present {
            await Diagnostics.shared.log("verify remove", "endpoint claimed success but book is still on \(shelf.name)", ok: false)
            throw AppError("Goodreads accepted the request but the book is still on \(shelf.label).")
        }
    }

    // MARK: - Finishing a book

    /// Rating, date read and the Read shelf all go through `/review/create`,
    /// which is the same form the website posts when you finish something.
    static func finish(bookID: String,
                       rating: Int?,
                       dateRead: Date?,
                       note: String) async throws {
        let session = WebSession.shared

        var args: [String: Any] = ["bookId": bookID, "note": note]
        args["rating"] = rating ?? 0

        if let dateRead {
            let calendar = Calendar.current
            let parts = calendar.dateComponents([.year, .month, .day], from: dateRead)
            args["readYear"] = parts.year ?? 0
            args["readMonth"] = parts.month ?? 0
            args["readDay"] = parts.day ?? 0
        } else {
            args["readYear"] = 0
            args["readMonth"] = 0
            args["readDay"] = 0
        }

        let raw = try await session.exclusive { () -> String in
            try await session.load(URL(string: "https://www.goodreads.com/book/show/\(bookID)")!)
            return try await session.evaluate(finishScript, arguments: args)
        }
        try check(raw)
    }

    /// Rating on its own, for a book already on a shelf — unlike `finish`,
    /// this does *not* touch shelf membership. It posts only
    /// `review[rating]`, no `add_to_shelves`, which relies on a review row
    /// already existing for the book (true for anything already shelved,
    /// since shelving creates one) rather than creating one on the Read
    /// shelf the way `finish` deliberately does.
    static func rate(bookID: String, stars: Int) async throws {
        let session = WebSession.shared

        let raw = try await session.exclusive { () -> String in
            try await session.ensureOnGoodreads()
            return try await session.evaluate(
                rateScript,
                arguments: ["bookId": bookID, "rating": stars]
            )
        }
        try check(raw)
    }

    // MARK: - Progress

    struct ProgressResult {
        let percent: Int?
        let page: Int?
    }

    /// Posts a reading-progress update. Percent, or a page number if you'd
    /// rather — Goodreads accepts either, and shows it on your updates feed.
    /// Returns the percent/page Goodreads actually recorded, read back from
    /// the widget's own progress bar rather than trusted from the input —
    /// a page-mode entry has no percent otherwise.
    ///
    /// `/user_status/create` is confirmed gone (404, even signed out) — the
    /// control for this moved off the book page entirely, onto a widget on
    /// the Goodreads home feed, one per currently-reading book. Phase 1 below
    /// costs nothing to keep trying in case Goodreads brings the endpoint
    /// back; phase 2 drives that home-feed widget instead.
    @discardableResult
    static func updateProgress(bookID: String,
                               percent: Int?,
                               page: Int?,
                               note: String) async throws -> ProgressResult {
        let session = WebSession.shared

        var args: [String: Any] = ["bookId": bookID, "note": note]
        args["percent"] = percent ?? -1
        args["page"] = page ?? -1

        let endpointRaw = try await session.exclusive { () -> String in
            try await session.ensureOnGoodreads()
            return try await session.evaluate(progressScript, arguments: args,
                                              label: "progress endpoint \(bookID)")
        }
        if let result = decode(endpointRaw), result.ok {
            return ProgressResult(percent: percent, page: page)
        }
        let endpointError = decode(endpointRaw)?.error ?? "endpoint reported success but nothing changed"

        // Phase 2 drives the home-feed widget's live DOM — load and evaluate
        // have to happen under one lock for the same reason as shelving's
        // phase 2 above.
        let domRaw = try await session.exclusive { () -> String in
            try await session.load(URL(string: "https://www.goodreads.com/")!)
            return try await session.evaluate(
                progressHomeFeedScript, arguments: args,
                label: "progress via home feed \(bookID)"
            )
        }
        if let data = domRaw.data(using: .utf8),
           let result = try? JSONDecoder().decode(ProgressDecodeResult.self, from: data),
           result.ok {
            return ProgressResult(percent: result.percent ?? percent, page: result.page ?? page)
        }
        let domError = decode(domRaw)?.error ?? "home-feed automation didn't take effect"

        throw AppError("\(endpointError); \(domError)")
    }

    private struct ProgressDecodeResult: Decodable {
        let ok: Bool
        let percent: Int?
        let page: Int?
        let error: String?
    }

    /// Percent progress for every book on the Currently Reading home-feed
    /// widget, keyed by book id — the shelf listing itself (`/review/list`)
    /// carries no progress field at all, so this is the only place that has
    /// it before you've touched a book's progress from inside the app.
    ///
    /// Reads the live DOM, so load and evaluate share one lock.
    static func currentProgress() async throws -> [String: Int] {
        let session = WebSession.shared

        let raw = try await session.exclusive { () -> String in
            try await session.load(URL(string: "https://www.goodreads.com/")!, timeout: 20)
            return try await session.evaluate(currentProgressScript, label: "current progress")
        }
        guard let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(CurrentProgressResult.self, from: data),
              result.ok, let progress = result.progress else {
            return [:]
        }
        return progress
    }

    private struct CurrentProgressResult: Decodable {
        let ok: Bool
        let progress: [String: Int]?
    }

    private static let currentProgressScript = """
    try {
        const result = {};
        for (const card of document.querySelectorAll('.currentlyReadingShelf .gr-mediaBox')) {
            const link = card.querySelector('a[href*="/book/show/"]');
            const href = link ? link.getAttribute('href') : '';
            const match = href.match(/\\/book\\/show\\/(\\d+)/);
            if (!match) continue;

            const progressEl = card.querySelector('progress');
            if (!progressEl) continue;
            const value = parseInt(progressEl.getAttribute('value'), 10);
            const max = parseInt(progressEl.getAttribute('max'), 10);
            if (!isNaN(value) && !isNaN(max) && max > 0) {
                result[match[1]] = Math.round((value / max) * 100);
            }
        }
        return JSON.stringify({ ok: true, progress: result });
    } catch (e) {
        return JSON.stringify({ ok: false, error: String(e && e.message ? e.message : e) });
    }
    """

    // MARK: - Plumbing

    private static func check(_ raw: String) throws {
        guard let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(ScriptResult.self, from: data) else {
            throw AppError("The page didn't respond as expected.")
        }
        if !result.ok { throw AppError(result.error ?? "Request failed.") }
    }

    /// React book pages don't carry a csrf-token meta tag, so an unsigned POST
    /// gets rejected. Pull one from a legacy Rails page instead — no navigation
    /// needed, since fetch is same-origin.
    private static let tokenPrelude = """
    async function csrfToken(forceFresh) {
        if (!forceFresh) {
            const meta = document.querySelector('meta[name="csrf-token"]');
            if (meta && meta.content) return meta.content;
        }

        for (const path of ['/review/list', '/']) {
            try {
                const html = await (await fetch(path, { credentials: 'same-origin' })).text();
                const match = html.match(/name="csrf-token"[^>]*content="([^"]+)"/)
                    || html.match(/content="([^"]+)"[^>]*name="csrf-token"/);
                if (match) return match[1];
            } catch (e) { /* try the next one */ }
        }
        return null;
    }

    async function postShelf(token, shelf, bookId, action) {
        const headers = {
            'Content-Type': 'application/x-www-form-urlencoded',
            'X-Requested-With': 'XMLHttpRequest'
        };
        if (token) headers['X-CSRF-Token'] = token;

        const params = { name: shelf, book_id: bookId, a: action };
        if (token) params.authenticity_token = token;

        // The .json variant first, then the plain form endpoint. If the token
        // we had was stale, Rails answers 401/403/422 — fetch a fresh one and
        // go again. That stale-token rejection is why an action would
        // sometimes only work on the second try.
        for (const path of ['/shelf/add_to_shelf.json', '/shelf/add_to_shelf']) {
            for (let attempt = 0; attempt < 2; attempt++) {
                try {
                    const response = await fetch(path, {
                        method: 'POST',
                        credentials: 'same-origin',
                        headers,
                        body: new URLSearchParams(params)
                    });
                    const text = await response.text();
                    if (response.ok && !/sign_in|<html/i.test(text)) {
                        return { ok: true, via: path };
                    }
                    var lastStatus = path + ' -> HTTP ' + response.status;

                    if ([401, 403, 419, 422].includes(response.status) && attempt === 0) {
                        const fresh = await csrfToken(true);
                        if (fresh) {
                            headers['X-CSRF-Token'] = fresh;
                            params.authenticity_token = fresh;
                            continue;
                        }
                    }
                    break;
                } catch (e) {
                    var lastStatus = path + ' -> ' + String(e);
                    break;
                }
            }
        }
        return { ok: false, error: lastStatus || 'no response' };
    }
    """

    private struct ScriptResult: Decodable {
        let ok: Bool
        let via: String?
        let error: String?
    }

    // MARK: - Scripts

    private static let addEndpointScript = tokenPrelude + """
    const token = await csrfToken();
    const result = await postShelf(token, shelf, bookId, '');
    if (!result.ok && !token) result.error = 'no CSRF token found; ' + result.error;
    return JSON.stringify(result);
    """

    private static let addDOMScript = """
    const sleep = (ms) => new Promise(r => setTimeout(r, ms));
    const visible = (el) => el && el.offsetParent !== null;
    const byText = (text) => [...document.querySelectorAll(
        'button, a, [role="menuitem"], [role="option"], li, div[tabindex]'
    )].find(el => visible(el) && el.textContent.trim().toLowerCase() === text.toLowerCase());

    const opener = document.querySelector(
        '[data-testid="wantToReadButton"], .WantToReadButton, button.wtrToRead, .wtrToRead'
    ) || byText('Want to Read') || byText('Currently Reading') || byText('Read');

    if (!opener) {
        // Report what IS on the page — makes the next fix a one-liner.
        const buttons = [...document.querySelectorAll('button')]
            .filter(visible).slice(0, 8)
            .map(b => b.textContent.trim().slice(0, 24)).filter(Boolean);
        return JSON.stringify({
            ok: false,
            error: 'no shelf control found (visible buttons: ' + (buttons.join(' | ') || 'none') + ')'
        });
    }

    if (shelf === 'to-read' || shelf === 'want-to-read') {
        opener.click();
        await sleep(1400);
        return JSON.stringify({ ok: true, via: 'click' });
    }

    const caret = document.querySelector(
        '[data-testid="shelfDropdownButton"], .WantToReadButton__dropdown, button[aria-haspopup="true"]'
    );
    (caret || opener).click();
    await sleep(1000);

    const item = byText(label);
    if (!item) {
        const options = [...document.querySelectorAll('[role="menuitem"], [role="option"], li')]
            .filter(visible).slice(0, 12)
            .map(el => el.textContent.trim().slice(0, 24)).filter(Boolean);
        return JSON.stringify({
            ok: false,
            error: 'no "' + label + '" in the menu (saw: ' + (options.join(' | ') || 'nothing') + ')'
        });
    }
    item.click();
    await sleep(1400);
    return JSON.stringify({ ok: true, via: 'menu' });
    """

    private static let verifyScript = WebScripts.dom + """
    try {
        // Newest first, so a just-added book is on the first page.
        const doc = await getDoc(shelfURL(shelf, 1, 50, '&sort=date_added&order=d'));
        const rows = parseRows(doc);
        const present = rows.some(r => r.bookId === String(bookId));
        return JSON.stringify({ ok: true, present: present });
    } catch (e) {
        return JSON.stringify({ ok: false, error: String(e && e.message ? e.message : e) });
    }
    """

    private static let removeScript = tokenPrelude + """
    const token = await csrfToken();
    const result = await postShelf(token, shelf, bookId, 'remove');
    return JSON.stringify(result);
    """

    private static let finishScript = tokenPrelude + """
    try {
        const token = await csrfToken();
        if (!token) return JSON.stringify({ ok: false, error: 'No CSRF token anywhere — are you signed in?' });

        const body = new URLSearchParams();
        body.append('authenticity_token', token);
        body.append('book_id', bookId);
        body.append('add_to_shelves', 'read');
        if (rating > 0) body.append('review[rating]', String(rating));
        if (note) body.append('review[review]', note);

        if (readYear > 0) {
            body.append('review[read_at][year]', String(readYear));
            body.append('review[read_at][month]', String(readMonth));
            body.append('review[read_at][day]', String(readDay));
        }

        const response = await fetch('/review/create', {
            method: 'POST',
            credentials: 'same-origin',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
                'X-Requested-With': 'XMLHttpRequest'
            },
            body
        });

        if (response.ok) return JSON.stringify({ ok: true, via: 'review/create' });
        return JSON.stringify({ ok: false, error: 'Goodreads rejected it (HTTP ' + response.status + ').' });
    } catch (e) {
        return JSON.stringify({ ok: false, error: String(e) });
    }
    """

    /// Rating only — no `add_to_shelves`, so it doesn't create or move a
    /// shelf entry the way `finishScript` deliberately does. Relies on a
    /// review row already existing (true for anything already shelved).
    private static let rateScript = tokenPrelude + """
    try {
        const token = await csrfToken();
        if (!token) return JSON.stringify({ ok: false, error: 'No CSRF token anywhere — are you signed in?' });

        const body = new URLSearchParams();
        body.append('authenticity_token', token);
        body.append('book_id', bookId);
        body.append('review[rating]', String(rating));

        const response = await fetch('/review/create', {
            method: 'POST',
            credentials: 'same-origin',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
                'X-Requested-With': 'XMLHttpRequest'
            },
            body
        });

        if (response.ok) return JSON.stringify({ ok: true, via: 'review/create' });
        return JSON.stringify({ ok: false, error: 'Goodreads rejected the rating (HTTP ' + response.status + ').' });
    } catch (e) {
        return JSON.stringify({ ok: false, error: String(e) });
    }
    """

    private static let progressScript = tokenPrelude + """
    try {
        const token = await csrfToken();
        if (!token) return JSON.stringify({ ok: false, error: 'No CSRF token anywhere — are you signed in?' });

        const body = new URLSearchParams();
        body.append('authenticity_token', token);
        body.append('user_status[book_id]', bookId);
        if (percent >= 0) body.append('user_status[percent]', String(percent));
        if (page >= 0) body.append('user_status[page]', String(page));
        if (note) body.append('user_status[body]', note);

        const response = await fetch('/user_status/create', {
            method: 'POST',
            credentials: 'same-origin',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
                'X-Requested-With': 'XMLHttpRequest'
            },
            body
        });

        if (response.ok) return JSON.stringify({ ok: true, via: 'endpoint' });
        return JSON.stringify({ ok: false, error: 'Progress update rejected (HTTP ' + response.status + ').' });
    } catch (e) {
        return JSON.stringify({ ok: false, error: String(e) });
    }
    """

    /// Drives the "Update progress" widget on the Goodreads home feed — one
    /// per currently-reading book — since `/user_status/create` no longer
    /// exists. Found structurally (the book's card in `.currentlyReadingShelf`,
    /// which has exactly one button — the trigger), not by button text: the
    /// app's web view carries its own cookies, separate from any browser
    /// you're signed into, and can land on a differently-localised page
    /// where "Update progress" isn't the literal label.
    private static let progressHomeFeedScript = """
    const sleep = (ms) => new Promise(r => setTimeout(r, ms));
    const visible = (el) => el && el.offsetParent !== null;

    const cards = [...document.querySelectorAll('.currentlyReadingShelf .gr-mediaBox')];
    const card = cards.find(c => c.querySelector('a[href*="/book/show/' + bookId + '"]'));

    if (!card) {
        return JSON.stringify({
            ok: false,
            error: 'this book isn\\'t on the Currently Reading shelf on your home feed ('
                + cards.length + ' book(s) shown there)'
        });
    }

    const target = card.querySelector('button');
    if (!target || !visible(target)) {
        return JSON.stringify({ ok: false, error: 'no progress button found on this book\\'s card' });
    }

    target.click();
    await sleep(900);

    const input = document.querySelector('.updateReadingProgress__headerInput');
    if (!input || !visible(input)) {
        return JSON.stringify({ ok: false, error: 'progress popup did not open' });
    }

    // The active entry mode's toggle button is the disabled one — switch
    // modes only when the popup didn't already open in the one we want.
    const wantPercent = percent >= 0;
    const toggle = [...document.querySelectorAll('.buttonToggle')]
        .find(t => t.textContent.trim() === (wantPercent ? '%' : '#'));
    if (toggle && !toggle.disabled) {
        toggle.click();
        await sleep(400);
    }

    // A plain "input.value = x" doesn't reliably notify a React-controlled
    // input; going through the native setter first does.
    const setValue = (el, value) => {
        const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
    };

    setValue(input, String(wantPercent ? percent : page));

    // A note field, if this popup has one — best-effort, not required.
    if (note) {
        const noteField = document.querySelector('.longTextPopupForm textarea');
        if (noteField) setValue(noteField, note);
    }

    const submit = document.querySelector('.longTextPopupForm__submitButton');
    if (!submit) {
        return JSON.stringify({ ok: false, error: 'no submit button found in the progress popup' });
    }
    submit.click();
    await sleep(1400);

    // Read the real result back from the widget's own progress bar (numeric
    // attributes, not the localisable label text) rather than trusting
    // whatever was typed in — a page-mode entry has no percent otherwise.
    const progressEl = card.querySelector('progress');
    let resultPage = null, resultTotal = null, resultPercent = null;
    if (progressEl) {
        resultPage = parseInt(progressEl.getAttribute('value'), 10);
        resultTotal = parseInt(progressEl.getAttribute('max'), 10);
        if (!isNaN(resultPage) && !isNaN(resultTotal) && resultTotal > 0) {
            resultPercent = Math.round((resultPage / resultTotal) * 100);
        }
    }

    return JSON.stringify({
        ok: true, via: 'home-feed',
        percent: resultPercent, page: isNaN(resultPage) ? null : resultPage
    });
    """
}
