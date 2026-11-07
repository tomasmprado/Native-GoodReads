import AppKit
import SwiftUI

/// A colour as three numbers from 0 to 1, for saving and for sums.
struct RGB: Codable, Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    var color: Color { Color(red: r, green: g, blue: b) }
    /// How light it looks (Rec. 709 weights).
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var saturation: Double {
        let high = max(r, g, b), low = min(r, g, b)
        return high == 0 ? 0 : (high - low) / high
    }
}

/// Each book's spine takes its colour from its cover: the cover's main
/// colour, a little deepened so it reads like cloth. Worked out once per
/// book and saved.
@MainActor
final class SpineColours: ObservableObject {
    static let shared = SpineColours()

    @Published private(set) var colours: [String: RGB] = [:]
    private var asked: Set<String> = []
    private var loaded = false

    private var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoodreadsGUI/cache/spine-colours.json")
    }

    func colour(_ bookID: String) -> RGB? { colours[bookID] }

    /// Looks at the covers of `entries` that haven't been looked at yet,
    /// a few at a time.
    func load(_ entries: [ShelfEntry]) async {
        if !loaded {
            loaded = true
            if let data = try? Data(contentsOf: file),
               let saved = try? JSONDecoder().decode([String: RGB].self, from: data) {
                colours.merge(saved) { new, _ in new }
            }
        }
        let todo = entries.filter { colours[$0.bookID] == nil && !asked.contains($0.bookID) && $0.coverURL != nil }
        guard !todo.isEmpty else { return }
        todo.forEach { asked.insert($0.bookID) }
        var found = 0
        for entry in todo where !Task.isCancelled {
            guard let url = entry.coverURL, let image = await ImageMemoryCache.shared.load(url),
                  let pixels = Self.pixels(of: image), let main = Self.mainColour(pixels) else { continue }
            colours[entry.bookID] = Self.cloth(main)
            found += 1
            if found % 12 == 0 { save() }
        }
        if found > 0 { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(colours) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Forgets them all (Settings → Clear Cache).
    func clear() {
        colours = [:]
        asked = []
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: Sums

    /// The cover shrunk to 20 × 30 pixels.
    nonisolated static func pixels(of image: NSImage) -> [RGB]? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = 20, height = 30
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).map {
            RGB(r: Double(bytes[$0]) / 255, g: Double(bytes[$0 + 1]) / 255, b: Double(bytes[$0 + 2]) / 255)
        }
    }

    /// The colour most of the cover is, favouring real colour over the
    /// white or black of a background: colours are grouped into buckets,
    /// and the biggest bucket wins, weighted towards the more colourful.
    nonisolated static func mainColour(_ pixels: [RGB]) -> RGB? {
        guard !pixels.isEmpty else { return nil }
        var buckets: [Int: (count: Int, sum: RGB)] = [:]
        for pixel in pixels {
            let key = Int(pixel.r * 5.99) * 36 + Int(pixel.g * 5.99) * 6 + Int(pixel.b * 5.99)
            var bucket = buckets[key] ?? (0, RGB(r: 0, g: 0, b: 0))
            bucket.count += 1
            bucket.sum.r += pixel.r; bucket.sum.g += pixel.g; bucket.sum.b += pixel.b
            buckets[key] = bucket
        }
        let best = buckets.values.max { a, b in score(a) < score(b) }!
        let n = Double(best.count)
        return RGB(r: best.sum.r / n, g: best.sum.g / n, b: best.sum.b / n)
    }

    nonisolated private static func score(_ bucket: (count: Int, sum: RGB)) -> Double {
        let n = Double(bucket.count)
        let mean = RGB(r: bucket.sum.r / n, g: bucket.sum.g / n, b: bucket.sum.b / n)
        // Near-white paper and near-black ink count for less.
        let plain = mean.luminance > 0.92 || mean.luminance < 0.06 ? 0.35 : 1
        return n * (0.45 + mean.saturation) * plain
    }

    /// Deepened a little, and never quite white or black, so it looks like
    /// a cloth spine and the lettering stays readable.
    nonisolated static func cloth(_ colour: RGB) -> RGB {
        func clamp(_ v: Double) -> Double { min(0.9, max(0.08, v * 0.88)) }
        return RGB(r: clamp(colour.r), g: clamp(colour.g), b: clamp(colour.b))
    }
}
