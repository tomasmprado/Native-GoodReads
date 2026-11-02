import SwiftUI

/// Text that grows with the Mac's text size (System Settings → Accessibility
/// → Display → Text size, where macOS passes it on to apps) and with View →
/// Bigger / Smaller (⌘+ / ⌘−), which always works.
@MainActor
final class TextZoom: ObservableObject {
    static let shared = TextZoom()

    static let range: ClosedRange<Double> = 0.85...1.6
    private static let step = 0.1
    private static let key = "textZoom"

    @Published private(set) var factor: Double

    private init() {
        let saved = UserDefaults.standard.double(forKey: Self.key)
        factor = saved > 0 ? min(max(saved, Self.range.lowerBound), Self.range.upperBound) : 1
    }

    var canGrow: Bool { factor < Self.range.upperBound - 0.001 }
    var canShrink: Bool { factor > Self.range.lowerBound + 0.001 }
    var isActualSize: Bool { abs(factor - 1) < 0.001 }

    func grow() { set(factor + Self.step) }
    func shrink() { set(factor - Self.step) }
    func reset() { set(1) }

    private func set(_ value: Double) {
        factor = (min(max(value, Self.range.lowerBound), Self.range.upperBound) * 100).rounded() / 100
        UserDefaults.standard.set(factor, forKey: Self.key)
    }

    /// How much the Mac's own text size setting enlarges text.
    nonisolated static func systemFactor(_ size: DynamicTypeSize) -> Double {
        switch size {
        case .xSmall: return 0.85
        case .small: return 0.9
        case .medium: return 0.95
        case .large: return 1
        case .xLarge: return 1.1
        case .xxLarge: return 1.2
        case .xxxLarge: return 1.3
        case .accessibility1: return 1.45
        case .accessibility2: return 1.6
        case .accessibility3: return 1.75
        case .accessibility4: return 1.9
        case .accessibility5: return 2.05
        @unknown default: return 1
        }
    }
}

private struct AppFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight?
    let design: Font.Design?
    let italic: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var zoom = TextZoom.shared

    func body(content: Content) -> some View {
        let scaled = size * CGFloat(zoom.factor * TextZoom.systemFactor(dynamicTypeSize))
        var font = Font.system(size: scaled, weight: weight ?? .regular, design: design ?? .default)
        if italic { font = font.italic() }
        return content.font(font)
    }
}

extension View {
    /// The app's text: `size` at the standard text size, scaled with the
    /// Mac's text size and View → Bigger / Smaller.
    func appFont(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil,
                 italic: Bool = false) -> some View {
        modifier(AppFont(size: size, weight: weight, design: design, italic: italic))
    }
}

/// View → Bigger, Smaller and Actual Size.
struct TextSizeCommands: Commands {
    @ObservedObject private var zoom = TextZoom.shared

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Bigger Text") { zoom.grow() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!zoom.canGrow)
            Button("Smaller Text") { zoom.shrink() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!zoom.canShrink)
            Button("Actual Text Size") { zoom.reset() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(zoom.isActualSize)
        }
    }
}
