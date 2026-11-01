import SwiftUI

/// A release's notes, as written in CHANGELOG.md: `###` headings and `-`
/// bullets whose text may wrap onto indented lines. Just enough Markdown for
/// that — SwiftUI's own Markdown support is inline-only.
enum ReleaseNotes {

    enum Block: Equatable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    static func blocks(from markdown: String) -> [Block] {
        var blocks: [Block] = []
        var current: Block?

        func flush() {
            if let current { blocks.append(current) }
            current = nil
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                current = .bullet(String(line.dropFirst(2)))
            } else {
                // A continuation of the bullet or paragraph above.
                switch current {
                case .bullet(let text):    current = .bullet(text + " " + line)
                case .paragraph(let text): current = .paragraph(text + " " + line)
                default:                   current = .paragraph(line)
                }
            }
        }
        flush()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// What's new in an update, with the button that installs it.
struct UpdateNotesView: View {
    let update: UpdateChecker.Available
    let canInstallInPlace: Bool
    let install: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.app")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Goodreads \(update.version)")
                        .font(.system(size: 15, weight: .semibold))
                    Text("You have \(Self.currentVersion)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let notes = update.notes {
                        ForEach(Array(ReleaseNotes.blocks(from: notes).enumerated()), id: \.offset) { _, block in
                            view(for: block)
                        }
                    } else {
                        Text("No release notes.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 320)

            HStack {
                Button("Release Page") { NSWorkspace.shared.open(update.url) }
                    .glassButton()
                Spacer()
                Button(canInstallInPlace
                       ? String(localized: "Install and Relaunch")
                       : String(localized: "Download…")) { install() }
                    .keyboardShortcut(.defaultAction)
                    .glassProminentButton()
            }
            if !canInstallInPlace {
                Text("Move the app to Applications to update it in one click.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    @ViewBuilder
    private func view(for block: ReleaseNotes.Block) -> some View {
        switch block {
        case .heading(let text):
            Text(ReleaseNotes.inline(text))
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 4)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(ReleaseNotes.inline(text))
            }
            .font(.system(size: 12))
        case .paragraph(let text):
            Text(ReleaseNotes.inline(text))
                .font(.system(size: 12))
        }
    }

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
