import SwiftUI

/// Paste-a-URL sheet for subscribing to a podcast. Accepts an Apple Podcasts
/// link, an apple.co short link, or a raw RSS feed URL; resolution + parsing run
/// in `PodcastStore.add`, with inline progress and error feedback.
struct AddPodcastView: View {
    @EnvironmentObject var podcasts: PodcastStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var trimmed: String { urlText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("貼上 Apple Podcasts 或 RSS 網址", text: $urlText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .lineLimit(1...3)
                } footer: {
                    Text("支援 Apple Podcasts 連結（podcasts.apple.com）或 RSS feed 網址。")
                }
                Section {
                    Link(destination: URL(string: "https://podcasts.apple.com")!) {
                        Label("到 Apple Podcasts 搜尋節目", systemImage: "magnifyingglass")
                    }
                } footer: {
                    Text("搜尋想聽的節目後，複製節目連結貼回此處。")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("新增 Podcast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Button("新增") { Task { await add() } }
                            .disabled(trimmed.isEmpty)
                    }
                }
            }
        }
    }

    private func add() async {
        // Tolerate a scheme-less paste (e.g. "podcasts.apple.com/...").
        var s = trimmed
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let url = URL(string: s) else {
            errorMessage = "網址格式不正確"
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            _ = try await podcasts.add(from: url)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
