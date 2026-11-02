import SwiftUI

/// Posts a reading-progress update — the "I'm on page 143" thing that shows up
/// on your updates feed. Percent or page; Goodreads takes either.
struct ProgressSheet: View {
    let entry: ShelfEntry
    /// The book's page count, when known — shows which page a percentage is.
    let totalPages: Int?
    let commit: (Int?, Int?, String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .percent
    @State private var percent: Double
    @State private var page: String = ""
    @State private var note: String = ""

    enum Mode: String, CaseIterable, Identifiable {
        case percent = "Percent"
        case page = "Page"
        var id: String { rawValue }
    }

    init(entry: ShelfEntry, totalPages: Int? = nil, commit: @escaping (Int?, Int?, String) -> Void) {
        self.entry = entry
        self.totalPages = totalPages
        self.commit = commit
        _percent = State(initialValue: Double(entry.progress ?? 50))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .appFont(size: 14, weight: .semibold)
                    .lineLimit(2)
                Text(entry.author)
                    .appFont(size: 12)
                    .foregroundStyle(.secondary)
            }

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0 == .percent ? "Percent" : "Page").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .percent {
                HStack(spacing: 10) {
                    Slider(value: $percent, in: 0...100, step: 1)
                    Text("\(Int(percent))%")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                }
                if let totalPages {
                    Text("Page \(Int((Double(totalPages) * percent / 100).rounded())) of \(totalPages)")
                        .appFont(size: 11)
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField(totalPages.map { String(localized: "Page number (of \($0))") } ?? String(localized: "Page number"),
                          text: $page)
                    .textFieldStyle(.roundedBorder)
                if let totalPages, let typed = Int(page), totalPages > 0 {
                    Text("\(min(100, typed * 100 / totalPages))%")
                        .appFont(size: 11)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Note (optional)", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Update") {
                    if mode == .percent {
                        commit(Int(percent), nil, note)
                    } else {
                        commit(nil, Int(page), note)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(mode == .page && Int(page) == nil)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
