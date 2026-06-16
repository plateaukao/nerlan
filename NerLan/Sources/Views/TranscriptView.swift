import Combine
import SwiftUI
import UIKit

/// Read-only transcript viewer shown in a sheet over the player. The stored
/// transcript has one sentence per line (segmented by the chat model), rendered
/// here as a numbered, sentence-by-sentence study list.
///
/// When the transcript was produced with timestamps (`cues`) *and* it belongs to
/// the episode currently playing, the sentence being spoken is highlighted and
/// kept on screen — a karaoke-style follow-along. Transcripts without cues (made
/// before this existed, or with a no-timestamp model) simply render plain.
///
/// Uses `List` (UITableView-backed, with cell reuse) with plain `Text` rows.
/// `.textSelection` is deliberately NOT used per row — it makes every reused
/// cell expensive to configure and causes stutter when flinging through the
/// hundreds of rows a 30-min transcript produces. Copy is offered via a
/// long-press context menu instead, whose content is built lazily on demand.
/// Playback position is read via `.onReceive` (not `@ObservedObject`) so `body`
/// re-renders only when the active sentence changes, not on every 0.5s tick.
struct TranscriptView: View {
    let title: String
    let text: String
    /// Episode id this transcript belongs to; highlighting only engages when this
    /// matches the episode currently playing.
    var episodeId: String? = nil
    /// Per-sentence start times, when available. nil ⇒ no highlighting.
    var cues: [TranscriptCue]? = nil
    /// Called by the close button. On iPhone it dismisses the sheet; in the iPad
    /// panel it clears the panel.
    var onClose: () -> Void

    /// The sentence currently being spoken (index into `lines`), or nil when this
    /// isn't the playing episode / there are no cues / playback is before the first.
    @State private var activeLine: Int?

    private struct Line: Identifiable {
        let id: Int
        let text: String
        let start: Double?
    }

    /// Fallback split for transcripts without cues — must match
    /// `AIContentStore.displaySentences` so row numbering stays consistent.
    private var sentences: [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var lines: [Line] {
        if let cues, !cues.isEmpty {
            return cues.enumerated().map { Line(id: $0.offset, text: $0.element.text, start: $0.element.start) }
        }
        return sentences.enumerated().map { Line(id: $0.offset, text: $0.element, start: nil) }
    }

    private var isCurrentEpisode: Bool {
        guard let episodeId else { return false }
        return PlayerManager.shared.current?.id == episodeId
    }

    var body: some View {
        NavigationStack {
            Group {
                if lines.isEmpty {
                    ContentUnavailableView("沒有逐字稿內容", systemImage: "captions.bubble")
                } else {
                    transcriptList
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("關閉") { onClose() }
                }
            }
        }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            List(lines) { line in
                row(line)
            }
            .listStyle(.plain)
            .onChange(of: activeLine) { _, idx in
                guard let idx else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(idx, anchor: .center) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = lines.map(\.text).joined(separator: "\n")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
        .onAppear { updateActiveLine(PlayerManager.shared.clock.currentTime) }
        .onReceive(PlayerManager.shared.clock.$currentTime) { updateActiveLine($0) }
        .onReceive(PlayerManager.shared.$current) { _ in
            updateActiveLine(PlayerManager.shared.clock.currentTime)
        }
    }

    @ViewBuilder
    private func row(_ line: Line) -> some View {
        let active = (line.id == activeLine)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(line.id + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(minWidth: 26, alignment: .trailing)
            Text(line.text)
                .font(.body)
                .fontWeight(active ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
        .listRowBackground(active ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = line.text
            } label: {
                Label("複製", systemImage: "doc.on.doc")
            }
            if isCurrentEpisode, let start = line.start {
                Button {
                    PlayerManager.shared.seek(to: start)
                } label: {
                    Label("從這裡播放", systemImage: "play.circle")
                }
            }
        }
    }

    /// Recompute which sentence is active for playback time `t`. No-ops (clears the
    /// highlight) unless this is the playing episode and we have cues. Writes the
    /// `@State` only on change, so equal ticks don't re-render.
    private func updateActiveLine(_ t: Double) {
        guard isCurrentEpisode, let cues, !cues.isEmpty else {
            if activeLine != nil { activeLine = nil }
            return
        }
        // Last cue whose start is at/before now (cues are sorted ascending).
        var lo = 0, hi = cues.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= t + 0.05 {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        let idx: Int? = found >= 0 ? found : nil
        if idx != activeLine { activeLine = idx }
    }
}
