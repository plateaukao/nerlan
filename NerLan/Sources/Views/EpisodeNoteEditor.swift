import SwiftUI

/// Sheet for writing or editing the user's note on an episode (see
/// `EpisodeNotesStore`). Saving empty text clears the note.
struct EpisodeNoteEditor: View {
    let episodeId: String
    let episodeTitle: String

    @EnvironmentObject var notes: EpisodeNotesStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("寫下這一集的內容…", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($focused)
                } footer: {
                    Text("註記會顯示在單集列表，方便辨認每一集的內容。")
                }
                if notes.note(for: episodeId) != nil {
                    Section {
                        Button("刪除註記", role: .destructive) {
                            notes.setNote("", for: episodeId)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(episodeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        notes.setNote(text, for: episodeId)
                        dismiss()
                    }
                }
            }
            .onAppear {
                text = notes.note(for: episodeId) ?? ""
                focused = true
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The note line shown under an episode row's metadata when a note exists.
/// Shared by the program episode list (`EpisodeRow`) and the record lists
/// (`RecordRow`).
struct EpisodeNoteText: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "note.text")
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .lineLimit(2)
    }
}
