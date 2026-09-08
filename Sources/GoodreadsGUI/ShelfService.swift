import Foundation

/// Adds a book to a shelf without leaving the app.
///
/// Two strategies, tried in order. The first is a plain request and needs no
/// DOM at all; the second falls back to driving the page the way a person
/// would, which is what the CLI's rod automation does.
enum ShelfService {

    static func add(bookID: String, to shelf: Shelf) async throws {
        let session = WebSession.shared

        guard let url = URL(string: "https://www.goodreads.com/book/show/\(bookID)") else {
            throw AppError("Bad book ID.")
        }
        try await session.load(url)

        let raw = try await session.evaluate(
            script,
            arguments: ["shelf": shelf.rawValue, "bookId": bookID, "label": shelf.label]
        )

        guard let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(ScriptResult.self, from: data) else {
            throw AppError("The page didn't respond as expected.")
        }

        if !result.ok {
            throw AppError(result.error ?? "Shelving failed.")
        }
    }

    /// Removing is the same legacy endpoint with `a=remove`.
    static func remove(bookID: String, from shelf: Shelf) async throws {
        let session = WebSession.shared
        try await session.ensureOnGoodreads()

        let raw = try await session.evaluate(
            removeScript,
            arguments: ["shelf": shelf.rawValue, "bookId": bookID]
        )
        try check(raw)
    }

    /// Posts a reading-progress update. Percent, or a page number if you'd
    /// rather — Goodreads accepts either, and shows it on your updates feed.
    static func updateProgress(bookID: String,
                               percent: Int?,
                               page: Int?,
                               note: String) async throws {
        let session = WebSession.shared
        try await session.load(URL(string: "https://www.goodreads.com/book/show/\(bookID)")!)

        var args: [String: Any] = ["bookId": bookID, "note": note]
        args["percent"] = percent ?? -1
        args["page"] = page ?? -1

        let raw = try await session.evaluate(progressScript, arguments: args)
        try check(raw)
    }

    private static func check(_ raw: String) throws {
        guard let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(ScriptResult.self, from: data) else {
            throw AppError("The page didn't respond as expected.")
        }
        if !result.ok { throw AppError(result.error ?? "Request failed.") }
    }

    private static let removeScript = """
    try {
        const token = document.querySelector('meta[name="csrf-token"]')?.content;
        const headers = {
            'Content-Type': 'application/x-www-form-urlencoded',
            'X-Requested-With': 'XMLHttpRequest'
        };
        if (token) headers['X-CSRF-Token'] = token;

        const response = await fetch('/shelf/add_to_shelf.json', {
            method: 'POST',
            credentials: 'same-origin',
            headers,
            body: new URLSearchParams({ name: shelf, book_id: bookId, a: 'remove' })
        });

        if (response.ok) return JSON.stringify({ ok: true, via: 'endpoint' });
        return JSON.stringify({ ok: false, error: 'Goodreads refused the removal (HTTP ' + response.status + ').' });
    } catch (e) {
        return JSON.stringify({ ok: false, error: String(e) });
    }
    """

    private static let progressScript = """
    try {
        const token = document.querySelector('meta[name="csrf-token"]')?.content;
        if (!token) return JSON.stringify({ ok: false, error: 'No CSRF token on the page — are you signed in?' });

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

    private struct ScriptResult: Decodable {
        let ok: Bool
        let via: String?
        let error: String?
    }

    /// Runs inside the loaded book page, so `fetch` carries the session cookies.
    private static let script = """
    const sleep = (ms) => new Promise(r => setTimeout(r, ms));

    // --- Strategy 1: the legacy AJAX endpoint. No DOM dependency. -----------
    try {
        const token = document.querySelector('meta[name="csrf-token"]')?.content;
        const headers = {
            'Content-Type': 'application/x-www-form-urlencoded',
            'X-Requested-With': 'XMLHttpRequest'
        };
        if (token) headers['X-CSRF-Token'] = token;

        const response = await fetch('/shelf/add_to_shelf.json', {
            method: 'POST',
            credentials: 'same-origin',
            headers,
            body: new URLSearchParams({ name: shelf, book_id: bookId, a: '' })
        });

        if (response.ok) {
            const text = await response.text();
            if (!text.includes('sign_in') && !text.includes('error')) {
                return JSON.stringify({ ok: true, via: 'endpoint' });
            }
        }
    } catch (e) { /* fall through */ }

    // --- Strategy 2: click it, like a person would. -------------------------
    const visible = (el) => el && el.offsetParent !== null;
    const byText = (text) => [...document.querySelectorAll(
        'button, a, [role="menuitem"], [role="option"], li'
    )].find(el => visible(el) && el.textContent.trim().toLowerCase() === text.toLowerCase());

    const opener = document.querySelector(
        '[data-testid="wantToReadButton"], .WantToReadButton, button.wtrToRead'
    ) || byText('Want to Read');

    if (!opener) {
        return JSON.stringify({ ok: false, error: 'Could not find the shelf control on the page.' });
    }

    // "Want to Read" is the primary button; the others live behind the caret.
    if (shelf === 'want-to-read') {
        opener.click();
        await sleep(1200);
        return JSON.stringify({ ok: true, via: 'click' });
    }

    const caret = document.querySelector(
        '[data-testid="shelfDropdownButton"], .WantToReadButton__dropdown, button[aria-haspopup="true"]'
    );
    (caret || opener).click();
    await sleep(900);

    const item = byText(label);
    if (!item) {
        return JSON.stringify({
            ok: false,
            error: 'Opened the shelf menu but found no "' + label + '" option.'
        });
    }
    item.click();
    await sleep(1200);
    return JSON.stringify({ ok: true, via: 'menu' });
    """
}
