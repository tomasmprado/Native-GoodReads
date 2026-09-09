import Foundation

/// Your Goodreads friends, their recent activity, and their profiles — all
/// scraped from authenticated pages via the shared `WKWebView`.
///
/// The activity parser targets `table.newsfeedUpdates tr.update[data-timestamp]`
/// directly — real, confirmed markup (both the home feed's mixed-friends feed
/// and a single friend's own profile page use the identical table). Each
/// update row's rating comes from the same `.staticStar.p10`-per-star widget
/// already relied on elsewhere in this app; a written comment, when present,
/// sits in a separate sibling `<tr>` immediately after the update row, whose
/// `id` is the update's own id with `_2` appended.
enum GoodreadsFriends {

    struct Friend: Identifiable, Hashable {
        let id: String
        let name: String
        let avatarURL: URL?
        let profileURL: URL?

        // The `/friend` page's per-friend "Currently reading: <book>" line —
        // more reliable than the home feed's activity table, which Goodreads
        // appears to have restructured (it still renders visually, but the
        // markup this app scraped for it no longer matches).
        var statusLabel: String?
        var statusBookTitle: String?
        var statusBookURL: URL?
        var statusCoverURL: URL?

        var hasStatus: Bool { statusLabel != nil || statusBookTitle != nil }
    }

    struct Activity: Identifiable, Hashable {
        let id: String
        let friendName: String
        let friendProfileURL: URL?
        let action: String          // "rated a book", "wants to read", "is currently reading", "finished reading"
        let rating: Int?
        let bookTitle: String?
        let bookURL: URL?
        let coverURL: URL?
        let comment: String?
    }

    struct Profile {
        let name: String
        let avatarURL: URL?
        let stats: String?          // e.g. "90 ratings · 4.08 avg · 4 reviews", already-joined text
        let activity: [Activity]
    }

    /// `/friend/user/<id>` (used elsewhere in this file, and what a friend's
    /// own profile page links to) shows *that person's* friends — it isn't
    /// your own friends management page. That's plain `/friend`.
    static func fetchFriends() async throws -> [Friend] {
        let session = WebSession.shared

        // Reads the live document — load and evaluate share one lock.
        let raw = try await session.exclusive { () -> String in
            try await session.load(URL(string: "https://www.goodreads.com/friend")!, timeout: 20)
            return try await session.evaluate(friendsScript, label: "friends list")
        }
        guard let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(FriendsResult.self, from: data),
              result.ok, let rows = result.friends else {
            return []
        }
        return rows.compactMap(friend(from:))
    }

    /// The mixed, all-friends activity feed on the home page.
    static func fetchActivity() async throws -> [Activity] {
        let session = WebSession.shared

        let raw = try await session.exclusive { () -> String in
            try await session.load(URL(string: "https://www.goodreads.com/")!, timeout: 20)
            return try await session.evaluate(activityTableScript, label: "friend activity")
        }
        return decodeActivity(raw)
    }

    /// A deeper look at one friend — their header info and their own recent
    /// updates, reachable by tapping their name or avatar.
    static func fetchProfile(url: URL) async throws -> Profile {
        let session = WebSession.shared

        // The load and both evaluates read the same live document, so they
        // all need to share one lock across the whole sequence.
        let (raw, activityRaw) = try await session.exclusive { () -> (String, String) in
            try await session.load(url, timeout: 20)
            let profileRaw = try await session.evaluate(profileScript, label: "friend profile")
            let activity = try await session.evaluate(activityTableScript, label: "friend profile activity")
            return (profileRaw, activity)
        }
        guard let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(ProfileResult.self, from: data),
              result.ok else {
            throw AppError("Couldn't read this profile.")
        }

        return Profile(
            name: result.name ?? "Goodreads member",
            avatarURL: result.avatar.flatMap(URL.init(string:)),
            stats: result.stats,
            activity: decodeActivity(activityRaw)
        )
    }

    // MARK: - Shared decoding

    private static func decodeActivity(_ raw: String) -> [Activity] {
        guard let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(ActivityResult.self, from: data),
              result.ok, let rows = result.activity else {
            return []
        }
        return rows.compactMap { row in
            guard !row.id.isEmpty, !row.friendName.isEmpty else { return nil }
            return Activity(
                id: row.id,
                friendName: row.friendName,
                friendProfileURL: row.profileURL.flatMap(URL.init(string:)),
                action: row.action,
                rating: (row.rating ?? 0) > 0 ? row.rating : nil,
                bookTitle: row.bookTitle,
                bookURL: row.bookURL.flatMap(URL.init(string:)),
                coverURL: row.cover.flatMap(URL.init(string:)),
                comment: row.comment?.isEmpty == false ? row.comment : nil
            )
        }
    }

    private static func friend(from row: FriendRow) -> Friend? {
        guard !row.id.isEmpty, !row.name.isEmpty else { return nil }
        return Friend(
            id: row.id,
            name: row.name,
            avatarURL: row.avatar.flatMap(URL.init(string:)),
            profileURL: row.url.flatMap(URL.init(string:)),
            statusLabel: row.statusLabel?.isEmpty == false ? row.statusLabel : nil,
            statusBookTitle: row.statusBookTitle?.isEmpty == false ? row.statusBookTitle : nil,
            statusBookURL: row.statusBookURL.flatMap(URL.init(string:)),
            statusCoverURL: row.statusCover.flatMap(URL.init(string:))
        )
    }

    /// The numeric Goodreads user id inside a `/user/show/<id>-<slug>` URL —
    /// used to cross-reference an activity row's friend against the friend
    /// list's avatar, since update rows themselves carry no avatar image.
    static func userID(from url: URL?) -> String? {
        guard let path = url?.path,
              let range = path.range(of: #"/user/show/(\d+)"#, options: .regularExpression) else {
            return nil
        }
        return path[range].replacingOccurrences(of: "/user/show/", with: "")
    }

    // MARK: - Wire format

    private struct FriendsResult: Decodable {
        let ok: Bool
        let friends: [FriendRow]?
    }

    private struct FriendRow: Decodable {
        let id: String
        let name: String
        let avatar: String?
        let url: String?
        let statusLabel: String?
        let statusBookTitle: String?
        let statusBookURL: String?
        let statusCover: String?
    }

    private struct ActivityResult: Decodable {
        let ok: Bool
        let activity: [ActivityRow]?
    }

    private struct ActivityRow: Decodable {
        let id: String
        let friendName: String
        let profileURL: String?
        let action: String
        let rating: Int?
        let bookTitle: String?
        let bookURL: String?
        let cover: String?
        let comment: String?
    }

    private struct ProfileResult: Decodable {
        let ok: Bool
        let name: String?
        let avatar: String?
        let stats: String?
    }

    // MARK: - Scripts

    /// Goodreads profile links are consistently `/user/show/<id>-<slug>`.
    /// Driven off `.friendInfo` directly rather than a `.leftContainer
    /// .elementList` outer scope — that wrapper class turned out to no
    /// longer exist on the page (confirmed against a real signed-in fetch),
    /// while `.friendInfo` and everything inside a friend's card were
    /// unchanged. `.friendInfo a.userLink` is itself enough to stay off the
    /// page's own header/nav (also full of `/user/show/<your-id>` links back
    /// to your own profile), since nothing there sits inside a `.friendInfo`.
    private static let friendsScript = """
    try {
        const seen = new Set();
        const friends = [];

        for (const info of document.querySelectorAll('.friendInfo')) {
            const link = info.querySelector('a.userLink[href*="/user/show/"]');
            if (!link) continue;

            const href = link.getAttribute('href') || '';
            const match = href.match(/\\/user\\/show\\/(\\d+)/);
            if (!match) continue;

            const id = match[1];
            const name = (link.textContent || '').trim();
            if (!name || seen.has(id)) continue;
            seen.add(id);

            // `.elementList` (when present) scopes the avatar and status
            // block to this friend's own card; fall back to the immediate
            // parent so a rename of that class doesn't lose everything.
            const card = info.closest('.elementList') || info.parentElement || info;
            const img = card.querySelector('.leftAlignedImage img, img');

            let statusLabel = null, statusBookTitle = null, statusBookURL = null, statusCover = null;
            const statuses = card.querySelector('.statuses');
            if (statuses) {
                const labelEl = statuses.querySelector('.greyText');
                if (labelEl) statusLabel = (labelEl.textContent || '').replace(/:\\s*$/, '').trim() || null;

                // The status block has two `/book/show/` links — one wraps
                // just the cover image, the other carries the title text.
                const bookLinks = [...statuses.querySelectorAll('a[href*="/book/show/"]')];
                const titleLink = bookLinks.find(a => (a.textContent || '').trim().length > 0) || bookLinks[0];
                if (titleLink) {
                    statusBookTitle = (titleLink.textContent || '').trim() || null;
                    statusBookURL = 'https://www.goodreads.com' + (titleLink.getAttribute('href') || '').split('?')[0];
                }
                const coverImg = statuses.querySelector('img');
                statusCover = coverImg ? coverImg.getAttribute('src') : null;
            }

            friends.push({
                id: id,
                name: name,
                avatar: img ? img.getAttribute('src') : null,
                url: 'https://www.goodreads.com' + href.split('?')[0],
                statusLabel: statusLabel,
                statusBookTitle: statusBookTitle,
                statusBookURL: statusBookURL,
                statusCover: statusCover
            });
        }

        return JSON.stringify({ ok: true, friends: friends });
    } catch (e) {
        return JSON.stringify({ ok: false, error: String(e && e.message ? e.message : e) });
    }
    """

    /// Reads every `tr.update[data-timestamp]` row on the current page —
    /// works on the home feed (all friends mixed) and on a single friend's
    /// own profile page (their "Recent Updates" box uses the same table).
    private static let activityTableScript = """
    try {
        const rows = [...document.querySelectorAll('table.newsfeedUpdates tr.update[data-timestamp]')];
        const activity = [];

        for (const row of rows) {
            const nameLink = row.querySelector('.updateAction strong a[href*="/user/show/"]');
            if (!nameLink) continue;

            const actionDiv = row.querySelector('.updateAction');
            const clone = actionDiv.cloneNode(true);
            clone.querySelectorAll('strong, .staticStars').forEach(el => el.remove());
            const action = (clone.textContent || '').replace(/\\s+/g, ' ').trim();

            const rating = row.querySelectorAll('.staticStars .staticStar.p10').length || null;

            const bookTitleEl = row.querySelector('.bookTitle');
            const coverImg = row.querySelector('.updateImage img');

            // A written review/comment sits in a separate sibling row right
            // after this one, whose id is this row's id plus "_2" — only
            // present when the friend actually wrote something.
            let comment = null;
            const next = row.nextElementSibling;
            if (next && next.id && row.id && next.id.indexOf(row.id + '_') === 0) {
                const textSpan = next.querySelector('[id^="freeTextContainer"]');
                if (textSpan) comment = (textSpan.textContent || '').trim();
            }

            const bookHref = bookTitleEl ? (bookTitleEl.getAttribute('href') || '') : '';
            activity.push({
                id: row.id,
                friendName: (nameLink.textContent || '').trim(),
                profileURL: 'https://www.goodreads.com' + (nameLink.getAttribute('href') || '').split('?')[0],
                action: action,
                rating: rating,
                bookTitle: bookTitleEl ? (bookTitleEl.textContent || '').trim() : null,
                bookURL: bookHref ? 'https://www.goodreads.com' + bookHref.split('?')[0] : null,
                cover: coverImg ? coverImg.getAttribute('src') : null,
                comment: comment
            });
            if (activity.length >= 60) break;
        }

        return JSON.stringify({ ok: true, activity: activity });
    } catch (e) {
        return JSON.stringify({ ok: false, error: String(e && e.message ? e.message : e) });
    }
    """

    private static let profileScript = """
    try {
        const name = (document.querySelector('#profileNameTopHeading, .userProfileName') || {}).textContent;
        const avatarImg = document.querySelector('.leftAlignedProfilePicture img');
        const statsEl = document.querySelector('.profilePageUserStatsInfo');
        const stats = statsEl ? (statsEl.textContent || '').replace(/\\s+/g, ' ').trim() : null;

        return JSON.stringify({
            ok: true,
            name: name ? name.trim() : null,
            avatar: avatarImg ? avatarImg.getAttribute('src') : null,
            stats: stats
        });
    } catch (e) {
        return JSON.stringify({ ok: false, error: String(e && e.message ? e.message : e) });
    }
    """
}
