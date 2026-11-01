import SwiftUI

// Liquid Glass on macOS 26+, with the old material look as a fallback — the
// app still runs on macOS 13, so every glass call goes through these helpers
// instead of being sprinkled behind `#available` checks across the views.

extension View {

    /// A floating glass surface — cards, panels, the Read Next pick.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 14) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .shadow(radius: 4)
        }
    }

    /// A capsule of glass behind a small control — filter fields, tags.
    @ViewBuilder
    func glassCapsule(interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: Capsule())
        } else {
            background(Color.secondary.opacity(0.1), in: Capsule())
        }
    }

    /// Round glass icon buttons for pane headers (refresh, export, clear).
    @ViewBuilder
    func glassIconButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
        } else {
            buttonStyle(.plain)
        }
    }

    /// Ordinary glass buttons (status bar, secondary actions).
    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.automatic)
        }
    }

    /// The one primary action in a group.
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// Groups nearby glass shapes so they blend and morph together, which is
    /// how Liquid Glass expects a row of controls to be drawn.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 8) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

/// A pane's title row. On macOS 26+ the row itself stays clear and its
/// controls are glass (like the system toolbar) — glass layered on glass is
/// what Apple's guidance says to avoid. Older systems keep the divider.
struct GlassHeader<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26, *) {
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
