import Foundation

/// Shared JavaScript. Everything here runs *inside* a loaded Goodreads page and
/// uses `fetch` + `DOMParser` instead of navigating the web view.
///
/// That's the whole point: navigation is stateful and serial, so two jobs
/// fighting over one web view would scrape each other's pages. Fetching is
/// stateless and parallel, and it carries the same cookies.
enum WebScripts {

    static let dom = """
    async function getDoc(url) {
        const response = await fetch(url, { credentials: 'same-origin' });
        if (!response.ok) throw new Error('HTTP ' + response.status + ' for ' + url);
        // response.url reflects where the fetch actually landed, after any
        // redirect — reliable on any page type, unlike sniffing the HTML for
        // a "/user/sign_in" link, which book pages carry even while signed in.
        if (/\\/user\\/sign_in/.test(response.url)) {
            throw new Error('signed out');
        }
        const html = await response.text();
        return new DOMParser().parseFromString(html, 'text/html');
    }

    function bookIdFrom(href) {
        if (!href) return '';
        const match = href.match(/\\/book\\/show\\/(\\d+)/);
        return match ? match[1] : '';
    }

    function cellText(row, cls) {
        const cell = row.querySelector('td.field.' + cls + ' .value');
        if (!cell) return '';
        // Empty dates render as "not set [edit]" — chrome, not a value.
        return (cell.textContent || '')
            .replace(/\\[\\s*edit\\s*\\]/gi, '')
            .replace(/\\s+/g, ' ')
            .trim();
    }

    function dateOrEmpty(value) {
        return (!value || /^not set$/i.test(value)) ? '' : value;
    }

    // The shelf table's rating cell is the same editable star widget the
    // book page uses to let you click a new rating — a `.stars` div with
    // both a `data-rating` attribute and one `.star.on`/`.star.off` per
    // star, unrelated to the read-only `.staticStar` widget used elsewhere
    // (reviews, aggregate ratings). `data-rating` first; counting `.on`
    // stars as a fallback in case it's ever missing.
    function ratingOf(row) {
        const stars = row.querySelector('td.field.rating .stars');
        if (!stars) return null;

        const attr = stars.getAttribute('data-rating');
        const fromAttr = attr ? Math.round(parseFloat(attr)) : 0;
        if (fromAttr > 0) return fromAttr;

        const onCount = stars.querySelectorAll('.star.on').length;
        return onCount || null;
    }

    function parseRows(doc) {
        const out = [];

        for (const row of doc.querySelectorAll('tr.bookalike, tr[id^="review_"]')) {
            const link = row.querySelector('td.field.title a, td.field.cover a');
            const bookId = bookIdFrom(link ? link.getAttribute('href') : '');
            if (!bookId) continue;

            const reviewMatch = (row.id || '').match(/review_(\\d+)/);
            const img = row.querySelector('td.field.cover img');

            // The table shows authors as "Last, First" — flip it back.
            let author = cellText(row, 'author');
            if (author.indexOf(',') !== -1) {
                const parts = author.split(',');
                author = (parts[1] || '').trim() + ' ' + parts[0].trim();
            }

            let cover = img ? img.getAttribute('src') : null;
            if (cover) cover = cover.replace(/\\._S[XY]\\d+_/, '._SY160_');

            let title = cellText(row, 'title');
            if (!title && link) title = (link.getAttribute('title') || '').trim();

            out.push({
                bookId: bookId,
                reviewId: reviewMatch ? reviewMatch[1] : null,
                title: title.trim(),
                author: author.trim(),
                cover: cover,
                rating: ratingOf(row),
                dateRead: dateOrEmpty(cellText(row, 'date_read')),
                dateAdded: dateOrEmpty(cellText(row, 'date_added'))
            });
        }

        return out;
    }

    function lastPageNumber(doc) {
        let max = 1;
        for (const link of doc.querySelectorAll('#reviewPagination a, div.pagination a')) {
            const n = parseInt((link.textContent || '').trim(), 10);
            if (!isNaN(n) && n > max) max = n;
        }
        return max;
    }

    // `userId` browses someone else's shelf instead of the signed-in user's
    // own — same template, same table, same rating column, just keyed by
    // `/review/list/<id>` instead of the implicit `/review/list`.
    function shelfURL(shelf, page, perPage, extra, userId) {
        const path = userId ? ('/review/list/' + encodeURIComponent(userId)) : '/review/list';
        return path + '?shelf=' + encodeURIComponent(shelf)
            + '&per_page=' + perPage
            + '&page=' + page
            + '&print=true&view=table'
            + (extra || '');
    }
    """
}
