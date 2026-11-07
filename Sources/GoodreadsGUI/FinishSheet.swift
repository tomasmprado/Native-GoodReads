import SwiftUI

/// Marking something read is the one moment Goodreads actually wants a rating,
/// so ask for it here rather than leaving the book unrated.
struct FinishSheet: View {
    let title: String
    let author: String
    var bookID: String? = nil
    var cover: URL? = nil
    let commit: (Int?, Date?, String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var rating = 0
    @State private var setDate = true
    @State private var dateRead = Date()
    @State private var note = ""
    @State private var letter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .appFont(size: 14, weight: .semibold)
                    .lineLimit(2)
                Text(author)
                    .appFont(size: 12)
                    .foregroundStyle(.secondary)
            }

            StarPicker(rating: $rating)

            Toggle("Finished on", isOn: $setDate)
                .toggleStyle(.checkbox)

            DatePicker("", selection: $dateRead, displayedComponents: .date)
                .datePickerStyle(.compact)
                .labelsHidden()
                .disabled(!setDate)
                .opacity(setDate ? 1 : 0.4)

            TextField("Review (optional)", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            VStack(alignment: .leading, spacing: 4) {
                Label("A letter to yourself", systemImage: "envelope")
                    .appFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                TextField("What do you want to remember? Sealed for a year (optional)", text: $letter, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Mark Read") {
                    commit(rating > 0 ? rating : nil, setDate ? dateRead : nil, note)
                    LetterBox.shared.add(letter, title: title, author: author, bookID: bookID, cover: cover,
                                         opens: Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

struct StarPicker: View {
    @Binding var rating: Int
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    // Tapping the current rating clears it.
                    rating = (rating == star) ? 0 : star
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .appFont(size: size)
                        .foregroundStyle(star <= rating ? Color.yellow : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(star) stars")
            }

            if rating > 0 {
                Text(Self.phrase(rating))
                    .appFont(size: 11)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
        }
    }

    /// Goodreads' own wording for each rating.
    static func phrase(_ rating: Int) -> String {
        switch rating {
        case 1:  return String(localized: "did not like it")
        case 2:  return String(localized: "it was ok")
        case 3:  return String(localized: "liked it")
        case 4:  return String(localized: "really liked it")
        case 5:  return String(localized: "it was amazing")
        default: return ""
        }
    }
}
