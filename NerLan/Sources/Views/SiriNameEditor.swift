import SwiftUI

/// Give a show a name you can actually say out loud.
///
/// Siri transcribes in its own language, so a Korean or Japanese title is never
/// heard as written and an accented French one arrives stripped. This is the
/// escape hatch: whatever the user types here becomes a synonym Siri matches,
/// alongside the automatic romanization and language aliases. The list below the
/// field shows the full set, so it's obvious what will and won't work.
struct SiriNameEditor: View {
    let showId: String
    let title: String
    let language: String
    let isPodcast: Bool

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ShowNicknameStore.shared
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：Didi", text: $text)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { save() }
                } header: {
                    Text("Siri 名稱")
                } footer: {
                    Text("Siri 用它自己的語言聽你說話，聽不出韓文、日文這類原文名稱。設一個你唸得出來的名字，就能說「Play \(text.isEmpty ? "Didi" : text) in NerLan」。")
                }

                Section("Siri 聽得懂的說法") {
                    ForEach(aliases, id: \.self) { alias in
                        Label(alias, systemImage: "quote.bubble")
                            .font(.callout)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { save() }
                }
            }
            .onAppear {
                text = store.nickname(for: showId) ?? ""
                focused = true
            }
        }
    }

    /// Live preview of what Siri will match, recomputed as the field is typed in.
    private var aliases: [String] {
        SiriNaming.aliases(title: title, language: language, isPodcast: isPodcast,
                           nickname: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func save() {
        store.set(text, for: showId)
        dismiss()
    }
}
