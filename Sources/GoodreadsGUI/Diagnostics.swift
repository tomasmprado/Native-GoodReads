import Foundation
import SwiftUI

/// A log of every script call. Debugging this app from error strings alone was
/// painful enough to justify building this.
@MainActor
final class Diagnostics: ObservableObject {

    static let shared = Diagnostics()

    struct Entry: Identifiable {
        let id = UUID()
        let time = Date()
        let label: String
        let detail: String
        let ok: Bool
    }

    @Published private(set) var entries: [Entry] = []

    private let limit = 400

    func log(_ label: String, _ detail: String, ok: Bool = true) {
        entries.append(Entry(label: label, detail: detail, ok: ok))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    func clear() { entries.removeAll() }

    /// Plain text for the Copy button — this is what to paste when something breaks.
    var plainText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        return entries.map { entry in
            "\(formatter.string(from: entry.time)) [\(entry.ok ? "ok " : "FAIL")] \(entry.label): \(entry.detail)"
        }.joined(separator: "\n")
    }
}

struct DiagnosticsSheet: View {
    @ObservedObject private var log = Diagnostics.shared
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Diagnostics")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(log.entries.count) entries")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.plainText, forType: .string)
                }
                Button("Clear") { log.clear() }
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)

            Divider()

            if log.entries.isEmpty {
                VStack {
                    Spacer()
                    Text("Nothing logged yet.").foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(log.entries) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(entry.ok ? Color.green : Color.orange)
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 5)

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entry.label)
                                            .font(.system(size: 11, weight: .medium))
                                        Text(entry.detail)
                                            .font(.system(size: 11).monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .id(entry.id)

                                Divider()
                            }
                        }
                    }
                    .onChange(of: log.entries.count) { _ in
                        if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(width: 640, height: 480)
    }
}
