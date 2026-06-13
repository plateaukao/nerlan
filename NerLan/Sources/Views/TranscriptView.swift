import SwiftUI
import UIKit

/// Read-only transcript viewer shown in a sheet over the player. The stored
/// transcript has one sentence per line (segmented by the chat model), rendered
/// here as a numbered, sentence-by-sentence study list.
///
/// Uses `List` (UITableView-backed, with cell reuse) with plain `Text` rows.
/// `.textSelection` is deliberately NOT used per row — it makes every reused
/// cell expensive to configure and causes stutter when flinging through the
/// hundreds of rows a 30-min transcript produces. Copy is offered via a
/// long-press context menu instead, whose content is built lazily on demand.
struct TranscriptView: View {
    let title: String
    let text: String

    @Environment(\.dismiss) private var dismiss

    private var sentences: [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sentences.isEmpty {
                    ContentUnavailableView("沒有逐字稿內容", systemImage: "captions.bubble")
                } else {
                    List(Array(sentences.enumerated()), id: \.offset) { index, sentence in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 26, alignment: .trailing)
                            Text(sentence)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = sentence
                            } label: {
                                Label("複製", systemImage: "doc.on.doc")
                            }
                        }
                    }
                    .listStyle(.plain)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                UIPasteboard.general.string = sentences.joined(separator: "\n")
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("關閉") { dismiss() }
                }
            }
        }
    }
}
