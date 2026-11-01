import SwiftUI

// Liquid Glass on macOS 26+, with the old material look as a fallback — the
// app still runs on macOS 13, so every glass call goes through these helpers
// instead of being sprinkled behind `#available` checks across the views.
//
// `#if compiler(>=6.2)` keeps this building with older Xcodes (Swift 6.2
// shipped with the macOS 26 SDK, which is where the glass APIs live); those
// builds simply get the fallback look everywhere.

extension View {

    /// A floating glass surface — cards, panels, the Read Next pick.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26, iOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape).shadow(radius: 4)
        }
        #else
        background(.regularMaterial, in: shape).shadow(radius: 4)
        #endif
    }

    /// A capsule of glass behind a small control — filter fields, tags.
    @ViewBuilder
    func glassCapsule(interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, iOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: Capsule())
        } else {
            background(Color.secondary.opacity(0.1), in: Capsule())
        }
        #else
        background(Color.secondary.opacity(0.1), in: Capsule())
        #endif
    }

    /// Round glass icon buttons for pane headers (refresh, export, clear).
    @ViewBuilder
    func glassIconButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, iOS 26, *) {
            buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
        } else {
            buttonStyle(.plain)
        }
        #else
        buttonStyle(.plain)
        #endif
    }

    /// Ordinary glass buttons (status bar, secondary actions).
    @ViewBuilder
    func glassButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, iOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.automatic)
        }
        #else
        buttonStyle(.automatic)
        #endif
    }

    /// The one primary action in a group.
    @ViewBuilder
    func glassProminentButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, iOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
        #else
        buttonStyle(.borderedProminent)
        #endif
    }

    /// Groups nearby glass shapes so they blend and morph together, which is
    /// how Liquid Glass expects a row of controls to be drawn.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 8) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// The ⌥Space panel's whole surface.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 22) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, iOS 26, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(.regularMaterial)
        }
        #else
        background(.regularMaterial)
        #endif
    }
}

/// True when this build has Liquid Glass and the Mac it runs on supports it.
var hasLiquidGlass: Bool {
    #if compiler(>=6.2)
    if #available(macOS 26, iOS 26, *) { return true }
    #endif
    return false
}

/// A pane's title row. With Liquid Glass the row itself stays clear and its
/// controls are glass (like the system toolbar) — glass layered on glass is
/// what Apple's guidance says to avoid. Otherwise it keeps the old divider.
struct GlassHeader<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if hasLiquidGlass {
            HStack(spacing: 8, content: content)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassGroup()
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 8, content: content)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                Divider()
            }
        }
    }
}
