import Foundation

/// Your Goodreads Reading Challenge for a year — the goal you pledged there,
/// so the Stats goal matches it instead of being a second, separate number.
struct ReadingChallenge: Codable, Sendable, Equatable {
    let year: Int
    /// Nil when you haven't joined that year's challenge.
    let goal: Int?
    /// Books Goodreads counts towards it, when the page says.
    let read: Int?
}

enum GoodreadsChallenge {

    static func url(year: Int) -> URL {
        URL(string: "https://www.goodreads.com/readingchallenges/gr/annual/\(year)")!
    }

    @MainActor static func fetch(year: Int) async throws -> ReadingChallenge {
        let session = WebSession.shared
        let raw = try await session.exclusive { () -> String in
            try await session.load(url(year: year), timeout: 25)
            return try await session.evaluate(script, arguments: ["year": year], label: "reading challenge")
        }
        guard let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(Result.self, from: data) else {
            throw AppError("Couldn't read the Reading Challenge page.")
        }
        guard result.ok else { throw AppError(verbatim: result.error ?? "Couldn’t read the Reading Challenge page.") }
        return ReadingChallenge(year: year, goal: result.goal.flatMap(plausible), read: result.read)
    }

    /// A pledge Goodreads would accept.
    static func plausible(_ goal: Int) -> Int? {
        (1...9999).contains(goal) ? goal : nil
    }

    /// The goal in a page's text, e.g. "You have read 12 of 40 books" or
    /// "12/40 books" — what the script does in the page, testable here.
    static func parse(text: String) -> (read: Int, goal: Int)? {
        let patterns = [
            #"(\d[\d,.]*)\s*(?:of|out of|/|de)\s*(\d[\d,.]*)\s*(?:books|livros)"#,
            #"(?:read|lido|leu)\s*(\d[\d,.]*)\s*(?:of|de)\s*(\d[\d,.]*)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text) else { continue }
            let number = { (s: Substring) in Int(s.filter(\.isNumber)) }
            if let read = number(text[a]), let goal = number(text[b]), plausible(goal) != nil {
                return (read, goal)
            }
        }
        return nil
    }

    private struct Result: Decodable {
        let ok: Bool
        let goal: Int?
        let read: Int?
        let error: String?
    }

    /// Waits a few seconds for the page to render, then looks in its embedded
    /// data for a goal field, and in its text for "N of M books".
    private static let script = """
    try {
        const challengeYear = Number(year);
        if (/\\/(ap\\/signin|user\\/sign_in)/.test(location.pathname)) {
            return JSON.stringify({ ok: false, error: "Signed out of Goodreads." });
        }
        const sleep = (ms) => new Promise(r => setTimeout(r, ms));
        const num = (v) => {
            if (typeof v === 'number') return v;
            if (typeof v === 'string' && /^\\d+$/.test(v)) return Number(v);
            return null;
        };
        const goalKey = /^(goal|goalCount|bookGoal|booksGoal|targetBooks|target|targetCount|pledge|pledgedBooks|numBooks)$/i;
        const readKey = /^(booksRead|readCount|currentCount|progress|count|numRead|booksCompleted)$/i;

        function fromData() {
            const blobs = [];
            document.querySelectorAll('script#__NEXT_DATA__, script[type="application/json"], [data-react-props]')
                .forEach(el => blobs.push(el.getAttribute('data-react-props') || el.textContent || ''));
            for (const blob of blobs) {
                let root;
                try { root = JSON.parse(blob); } catch (e) { continue; }
                const stack = [root];
                let seen = 0;
                while (stack.length && seen++ < 50000) {
                    const node = stack.pop();
                    if (!node || typeof node !== 'object') continue;
                    let goal = null, read = null, nodeYear = null;
                    for (const [k, v] of Object.entries(node)) {
                        if (goalKey.test(k) && num(v) !== null) goal = num(v);
                        else if (readKey.test(k) && num(v) !== null) read = num(v);
                        else if (/year/i.test(k) && num(v) !== null) nodeYear = num(v);
                        if (v && typeof v === 'object') stack.push(v);
                    }
                    if (goal !== null && goal > 0 && (nodeYear === null || nodeYear === challengeYear)) {
                        return { goal, read };
                    }
                }
            }
            return null;
        }

        function fromText() {
            const text = (document.body && document.body.innerText) || '';
            let m = text.match(/(\\d[\\d,.]*)\\s*(?:of|out of|\\/|de)\\s*(\\d[\\d,.]*)\\s*(?:books|livros)/i);
            if (m) return { read: Number(m[1].replace(/\\D/g, '')), goal: Number(m[2].replace(/\\D/g, '')) };
            m = text.match(/(?:goal|meta)[^\\d]{0,20}(\\d[\\d,.]*)\\s*(?:books|livros)/i);
            if (m) return { read: null, goal: Number(m[1].replace(/\\D/g, '')) };
            return null;
        }

        function notJoined() {
            const text = (document.body && document.body.innerText) || '';
            return /(join|start) (the )?(\\d{4} )?(reading )?challenge|set (your|a) goal/i.test(text);
        }

        for (let i = 0; i < 16; i++) {
            const found = fromData() || fromText();
            if (found && found.goal > 0) return JSON.stringify({ ok: true, goal: found.goal, read: found.read });
            await sleep(500);
        }
        if (notJoined()) return JSON.stringify({ ok: true, goal: null, read: null });
        return JSON.stringify({ ok: false, error: "Couldn't find the goal on the Reading Challenge page." });
    } catch (e) {
        return JSON.stringify({ ok: false, error: String(e && e.message ? e.message : e) });
    }
    """
}
