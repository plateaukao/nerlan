import Combine
import SwiftUI
import UIKit

/// Read-only transcript viewer shown in a sheet over the player. The stored
/// transcript has one sentence per line (segmented by the chat model), rendered
/// here as a sentence-by-sentence study list.
///
/// When the transcript was produced with timestamps (`cues`) *and* it belongs to
/// the episode currently playing, the sentence being spoken is highlighted and
/// kept on screen — a karaoke-style follow-along. Transcripts without cues (made
/// before this existed, or with a no-timestamp model) simply render plain.
///
/// Two toolbar controls tune the reading: a font-size button loops through three
/// sizes (remembered across all transcript screens via `@AppStorage`), and a
/// translate button loops the view through three modes — original, original plus
/// per-sentence translation, and translation only — translating into the target
/// language set in Settings. The translation is generated on demand, cached, and
/// mirrored to iCloud by `AIContentStore`. Translate-mode resets to original each
/// time a transcript opens, so opening one never silently starts a paid job.
///
/// Uses `List` (UITableView-backed, with cell reuse) with plain `Text` rows.
/// `.textSelection` is deliberately NOT used per row — it makes every reused
/// cell expensive to configure and causes stutter when flinging through the
/// hundreds of rows a 30-min transcript produces. Copy is offered via a
/// long-press context menu instead, whose content is built lazily on demand.
/// Playback position is read via `.onReceive` (not `@ObservedObject`) so `body`
/// re-renders only when the active sentence changes, not on every 0.5s tick.
struct TranscriptView: View {
    let record: EpisodeRecord
    let text: String
    /// Per-sentence start times, when available. nil ⇒ no highlighting.
    var cues: [TranscriptCue]? = nil
    /// Called by the close button. On iPhone it dismisses the sheet; in the iPad
    /// panel it clears the panel.
    var onClose: () -> Void

    @EnvironmentObject private var ai: AIContentStore
    @EnvironmentObject private var settings: SettingsStore

    /// Reading font size, remembered across all transcript screens:
    /// 0 = default, 1 = larger, 2 = largest.
    @AppStorage("transcriptFontScale") private var fontScale = 0

    /// View mode: 0 = original, 1 = original + translation, 2 = translation only.
    /// Resets to 0 each time a transcript opens.
    @State private var translateMode = 0
    /// The mode to switch to once an in-flight translation finishes.
    @State private var pendingMode: Int?
    /// Translation aligned to the display sentences, for the current target
    /// language. nil ⇒ not loaded / unavailable.
    @State private var translation: [String]?
    @State private var showTranslateError = false
    @State private var translateErrorText = ""

    /// The sentence currently being spoken (index into `lines`), or nil when this
    /// isn't the playing episode / there are no cues / playback is before the first.
    @State private var activeLine: Int?

    private var episodeId: String { record.id }

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
        PlayerManager.shared.current?.id == episodeId
    }

    /// Point sizes for the three font-scale steps.
    private var bodyFontSize: CGFloat { [17.0, 21.0, 26.0][min(max(fontScale, 0), 2)] }

    private var translationJob: AIContentStore.JobState? { ai.translationJob(episodeId) }
    private var isTranslating: Bool {
        if case .running = translationJob { return true } else { return false }
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("關閉") { onClose() }
                }
            }
        }
        .alert("翻譯失敗", isPresented: $showTranslateError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(translateErrorText)
        }
        // Apply a pending mode switch when its translation job finishes, or surface
        // the failure.
        .onChange(of: translationJob) { _, state in
            handleTranslationJobChange(state)
        }
        // Keep the screen awake while the transcript is on screen (player caption
        // mode, the standalone sheet, or the iPad panel) so it doesn't sleep
        // mid-read. Restored as soon as the view goes away.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
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
                    fontScale = (fontScale + 1) % 3
                } label: {
                    Image(systemName: "textformat.size")
                        .foregroundStyle(fontScale == 0 ? Color.secondary : Color.accentColor)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isTranslating {
                    ProgressView()
                } else {
                    Button {
                        cycleTranslate()
                    } label: {
                        Image(systemName: "globe")
                            .foregroundStyle(translateMode == 0 ? Color.secondary : Color.accentColor)
                    }
                }
            }
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
        let translated = translationText(for: line)
        // In translation-only mode, fall back to the original when a line has no
        // translation, so the row is never blank.
        let showOriginal = translateMode != 2 || (translated?.isEmpty ?? true)
        VStack(alignment: .leading, spacing: 4) {
            if showOriginal {
                Text(line.text)
                    .font(.system(size: bodyFontSize))
                    .fontWeight(active ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if translateMode != 0, let translated, !translated.isEmpty {
                Text(translated)
                    .font(.system(size: translateMode == 2 ? bodyFontSize : bodyFontSize - 2))
                    .fontWeight(active && translateMode == 2 ? .semibold : .regular)
                    .foregroundStyle(translateMode == 2 ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

    /// The translation for a line, when one is loaded and aligned.
    private func translationText(for line: Line) -> String? {
        guard let translation, line.id < translation.count else { return nil }
        return translation[line.id]
    }

    // MARK: - Translate cycling

    /// Loop original → original+translation → translation-only → original.
    /// Switching into a translated mode loads the cached translation if it matches
    /// the current target language, otherwise kicks off generation (needs a key).
    private func cycleTranslate() {
        let next = (translateMode + 1) % 3
        if next == 0 {
            translateMode = 0
            return
        }
        if let stored = ai.translation(episodeId), stored.language == settings.translationLanguage {
            translation = stored.sentences
            translateMode = next
            return
        }
        guard settings.hasAPIKey else {
            translateErrorText = "尚未設定 OpenAI API 金鑰，無法翻譯。"
            showTranslateError = true
            return
        }
        pendingMode = next
        ai.translate(record)
    }

    private func handleTranslationJobChange(_ state: AIContentStore.JobState?) {
        switch state {
        case .none:
            // Finished: apply the pending switch if the result is now available.
            guard let pending = pendingMode else { return }
            if let stored = ai.translation(episodeId), stored.language == settings.translationLanguage {
                translation = stored.sentences
                translateMode = pending
            }
            pendingMode = nil
        case .failed(let message):
            if pendingMode != nil {
                pendingMode = nil
                translateErrorText = message
                showTranslateError = true
            }
        case .running:
            break
        }
    }

    // MARK: - Highlight

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
