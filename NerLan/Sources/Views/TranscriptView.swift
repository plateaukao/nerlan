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
/// mirrored to iCloud by `AIContentStore`. Translate-mode is remembered across
/// screens; on open it's reapplied only when a matching translation is already
/// cached, so opening one never silently starts a paid job.
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
    /// When true, shadowing turns on as the view appears (the player's one-tap 跟讀
    /// entry). Other entry points leave it off.
    var startShadowing = false
    /// Called by the close button. On iPhone it dismisses the sheet; in the iPad
    /// panel it clears the panel.
    var onClose: () -> Void

    @EnvironmentObject private var ai: AIContentStore
    @EnvironmentObject private var settings: SettingsStore

    /// Reading font size, remembered across all transcript screens:
    /// 0 = default, 1 = larger, 2 = largest.
    @AppStorage("transcriptFontScale") private var fontScale = 0

    /// View mode: 0 = original, 1 = original + translation, 2 = translation only.
    /// On open it's restored from `translatePreference` only when a matching
    /// translation is already cached (see `restoreTranslatePreference`).
    @State private var translateMode = 0
    /// Remembered view-mode preference across transcript screens. Drives the mode
    /// on open, but only takes effect when the cached translation exists — opening
    /// never triggers a (paid) translation.
    @AppStorage("transcriptTranslateMode") private var translatePreference = 0
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

    /// Transcript content actually rendered: the live partial while a transcription
    /// job streams in per ~20-min chunk, then the saved file once written, falling
    /// back to the snapshot passed in. Cached in @State (refreshed on appear and
    /// when the partial changes) so the per-tick highlight never re-reads files.
    @State private var loadedSentences: [String] = []
    @State private var loadedCues: [TranscriptCue]?

    /// Shadowing mode: when on, the targeted sentence loops and a sentence-transport
    /// bar appears so the learner can repeat each line. Only offered when this is
    /// the playing episode and the transcript has timestamp cues. Reset per open.
    @State private var shadowing = false
    /// The sentence armed for looping (index into cues). Tracked independently of
    /// `activeLine` so the highlight and prev/next stepping stay stable across the
    /// loop's lead-in instead of racing the playback clock.
    @State private var shadowIndex: Int?
    /// Repeat count per sentence: 0 = loop forever, else play it N times then
    /// stop. Remembered across transcript screens.
    @AppStorage("shadowLoopCount") private var loopCount = 0

    /// Voice recording for shadowing: record yourself reading the sentence, then
    /// play it back against the original.
    @ObservedObject private var recorder = ShadowRecorder.shared
    @State private var showMicDenied = false
    /// Whether a segment is currently repeating, mirrored from `PlayerManager`. The
    /// replay button becomes a pause while this is true so the loop can be stopped.
    @State private var isLooping = false

    private var episodeId: String { record.id }

    private struct Line: Identifiable {
        let id: Int
        let text: String
        let start: Double?
    }

    /// Fallback split for transcripts without cues — routed through
    /// `AIContentStore.displaySentences` so row numbering stays consistent.
    private var sentences: [String] {
        AIContentStore.displaySentences(text)
    }

    private var lines: [Line] {
        if let loadedCues, !loadedCues.isEmpty {
            return loadedCues.enumerated().map { Line(id: $0.offset, text: $0.element.text, start: $0.element.start) }
        }
        return loadedSentences.enumerated().map { Line(id: $0.offset, text: $0.element, start: nil) }
    }

    /// Pull the current transcript content from the store: prefer the streaming
    /// partial, then the saved file, then the snapshot props captured at open.
    private func refreshTranscriptContent() {
        if let partial = ai.partialTranscripts[episodeId] {
            loadedSentences = partial.sentences
            loadedCues = partial.cues.isEmpty ? nil : partial.cues
        } else if let fileText = ai.transcriptText(episodeId) {
            loadedSentences = AIContentStore.displaySentences(fileText)
            loadedCues = ai.transcriptCues(episodeId) ?? cues
        } else {
            loadedSentences = sentences
            loadedCues = cues
        }
    }

    private var isCurrentEpisode: Bool {
        PlayerManager.shared.current?.id == episodeId
    }

    /// Shadowing needs the playing episode plus timestamp cues to loop by.
    private var shadowingAvailable: Bool {
        isCurrentEpisode && !(loadedCues?.isEmpty ?? true)
    }

    /// Index used for row highlight/scroll: the loop target while shadowing, else
    /// the sentence being spoken.
    private var highlightIndex: Int? { shadowing ? shadowIndex : activeLine }

    /// The `[start, end)` span of sentence `index`: its cue start to the next cue's
    /// start (the episode duration for the last sentence).
    private func region(for index: Int) -> (start: Double, end: Double)? {
        guard let cues = loadedCues, index >= 0, index < cues.count else { return nil }
        let start = cues[index].start
        let end = index + 1 < cues.count ? cues[index + 1].start
                                         : PlayerManager.shared.clock.duration
        return (start, end)
    }

    /// Arm the loop on sentence `index` and remember it as the shadow target.
    /// Stops any in-progress recording / playback first, so stepping to another
    /// sentence (or replaying) interrupts a take and plays the segment.
    private func loopSentence(_ index: Int?) {
        guard let index, let r = region(for: index) else { return }
        recorder.reset()
        shadowIndex = index
        PlayerManager.shared.loopSegment(start: r.start, end: r.end,
                                         times: loopCount == 0 ? nil : loopCount)
    }

    private func toggleShadowing() {
        shadowing.toggle()
        if shadowing {
            loopSentence(activeLine ?? 0)   // start repeating the current line
        } else {
            shadowIndex = nil
            PlayerManager.shared.clearLoop()
            recorder.reset()
        }
    }

    private var loopCountLabel: String { loopCount == 0 ? "∞" : "×\(loopCount)" }

    // MARK: - Voice recording

    /// Per-sentence key for the learner's recording.
    private func recordKey(_ index: Int) -> String { "\(record.id)-\(index)" }

    private func toggleRecord() async {
        guard let i = shadowIndex else { return }
        if recorder.isRecording {
            recorder.stopRecording(thenPlay: true)   // hear your take right after
        } else if recorder.permissionDenied {
            showMicDenied = true
        } else if await recorder.startRecording(key: recordKey(i)) == false {
            showMicDenied = true
        }
    }

    /// After a finite sentence loop finishes its repeats, automatically start
    /// recording the learner's turn (∞ loops never finish, so they don't trigger it).
    private func autoStartRecord() async {
        guard shadowing, let i = shadowIndex,
              !recorder.isRecording, !recorder.isPlaying else { return }
        if recorder.permissionDenied { showMicDenied = true; return }
        if await recorder.startRecording(key: recordKey(i)) == false { showMicDenied = true }
    }

    private func togglePlayMine() {
        guard let i = shadowIndex else { return }
        if recorder.isPlaying {
            recorder.stopPlayback()
        } else {
            recorder.playRecording(key: recordKey(i))
        }
    }

    /// Point sizes for the three font-scale steps.
    private var bodyFontSize: CGFloat { [17.0, 21.0, 26.0][min(max(fontScale, 0), 2)] }

    /// The transcription job's status note while it's still running for this
    /// episode (drives the streaming footer), else nil.
    private var transcriptRunningNote: String? {
        if case .running(let note)? = ai.jobState(.transcript, episodeId) { return note }
        return nil
    }

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
        .alert("無法使用麥克風", isPresented: $showMicDenied) {
            Button("好", role: .cancel) {}
        } message: {
            Text("請到「設定 → NerLan」開啟麥克風權限，才能錄下你的朗讀。")
        }
        // Apply a pending mode switch when its translation job finishes, or surface
        // the failure.
        .onChange(of: translationJob) { _, state in
            handleTranslationJobChange(state)
        }
        // The transcript streams in per chunk (and clears to the saved file when
        // done); re-read the rendered content whenever it changes.
        .onChange(of: ai.partialTranscripts[episodeId]) { _, _ in
            refreshTranscriptContent()
        }
        // Switch into the requested translated mode as soon as the first batch
        // lands, so the rows visibly fill in instead of waiting for the whole job.
        .onChange(of: streamingTranslation) { _, partial in
            guard partial != nil, let pending = pendingMode, translateMode != pending else { return }
            translateMode = pending
        }
        // Keep the screen awake while the transcript is on screen (player caption
        // mode, the standalone sheet, or the iPad panel) so it doesn't sleep
        // mid-read. Restored as soon as the view goes away.
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            refreshTranscriptContent()   // before restore/shadowing, which read the cues
            restoreTranslatePreference()
            if startShadowing && shadowingAvailable && !shadowing { toggleShadowing() }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            if shadowing {
                PlayerManager.shared.clearLoop()
                recorder.reset()
            }
        }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(lines) { line in
                    row(line)
                }
                // While the transcript is still streaming in, a footer shows the
                // job's progress so the partial doesn't look like the whole episode.
                if let note = transcriptRunningNote {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .bottom) {
                if shadowing { shadowControlBar }
            }
            .onChange(of: activeLine) { _, idx in
                guard !shadowing, let idx else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(idx, anchor: .center) }
            }
            .onChange(of: shadowIndex) { _, idx in
                guard shadowing, let idx else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(idx, anchor: .center) }
            }
            .onChange(of: loopCount) { _, _ in
                if shadowing { loopSentence(shadowIndex) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if shadowingAvailable {
                    Button { toggleShadowing() } label: {
                        Image(systemName: shadowing ? "repeat.circle.fill" : "repeat.circle")
                            .foregroundStyle(shadowing ? Color.accentColor : Color.secondary)
                    }
                }
            }
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
        // `dropFirst` skips the value delivered at subscription, so only a real
        // finite-loop completion (not entering the view) triggers auto-record.
        .onReceive(PlayerManager.shared.$loopRegion) { isLooping = ($0 != nil) }
        .onReceive(PlayerManager.shared.$loopFinishedSignal.dropFirst()) { _ in
            Task { await autoStartRecord() }
        }
    }

    @ViewBuilder
    private func row(_ line: Line) -> some View {
        let active = (line.id == highlightIndex)
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
        .onTapGesture {
            if shadowing { loopSentence(line.id) }
        }
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
            if shadowingAvailable {
                Button {
                    if !shadowing { shadowing = true }
                    loopSentence(line.id)
                } label: {
                    Label("重複這句", systemImage: "repeat")
                }
            }
        }
    }

    /// Sentence-grained transport shown at the bottom while shadowing: step
    /// between sentences and replay the current one (left), record your read and
    /// play it back (middle), and pick the repeat count (right).
    private var shadowControlBar: some View {
        let count = loadedCues?.count ?? 0
        let i = shadowIndex
        let key = recordKey(i ?? -1)
        return HStack(spacing: 18) {
            Button { loopSentence((i ?? 0) - 1) } label: {
                Image(systemName: "backward.end.fill")
            }
            .disabled((i ?? 0) <= 0)

            Button {
                if isLooping {
                    PlayerManager.shared.clearLoop()
                    PlayerManager.shared.pause()
                } else {
                    loopSentence(i ?? activeLine ?? 0)
                }
            } label: {
                Image(systemName: isLooping ? "pause.circle.fill" : "arrow.counterclockwise")
            }

            Button { loopSentence((i ?? -1) + 1) } label: {
                Image(systemName: "forward.end.fill")
            }
            .disabled(i == nil || (i! + 1) >= count)

            Spacer()

            // Record your read, then play it back to compare with the original.
            Button { Task { await toggleRecord() } } label: {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .foregroundStyle(recorder.isRecording ? Color.red : Color.accentColor)
            }
            .disabled(i == nil)

            Button { togglePlayMine() } label: {
                Image(systemName: recorder.isPlaying ? "stop.circle.fill" : "play.circle.fill")
            }
            .disabled(i == nil || !recorder.hasRecording(for: key))

            Spacer()

            Menu {
                Picker("重複次數", selection: $loopCount) {
                    Text("1 次").tag(1)
                    Text("2 次").tag(2)
                    Text("3 次").tag(3)
                    Text("5 次").tag(5)
                    Text("無限").tag(0)
                }
            } label: {
                Label(loopCountLabel, systemImage: "repeat")
                    .font(.subheadline)
            }
        }
        .font(.title2)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// In-flight translation for the current target language, streamed per batch —
    /// a growing prefix the view shows filling in. nil when none is running for this
    /// episode/language.
    private var streamingTranslation: [String]? {
        guard let partial = ai.partialTranslations[episodeId],
              partial.language == settings.translationLanguage else { return nil }
        return partial.sentences
    }

    /// The translation for a line: the live streaming partial while a job runs, else
    /// the loaded (cached/finished) translation.
    private func translationText(for line: Line) -> String? {
        let source = streamingTranslation ?? translation
        guard let source, line.id < source.count else { return nil }
        return source[line.id]
    }

    // MARK: - Translate cycling

    /// Loop original → original+translation → translation-only → original.
    /// Switching into a translated mode loads the cached translation if it matches
    /// the current target language, otherwise kicks off generation (needs a key).
    private func cycleTranslate() {
        let next = (translateMode + 1) % 3
        if next == 0 {
            translateMode = 0
            translatePreference = 0
            return
        }
        if let stored = ai.translation(episodeId), stored.language == settings.translationLanguage {
            translation = stored.sentences
            translateMode = next
            translatePreference = next
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

    /// On open, apply the remembered view-mode preference only if a matching
    /// translation is already cached; otherwise stay on the original. Never starts
    /// a translation job.
    private func restoreTranslatePreference() {
        if translatePreference != 0,
           let stored = ai.translation(episodeId),
           stored.language == settings.translationLanguage {
            translation = stored.sentences
            translateMode = translatePreference
        } else if translatePreference != 0, streamingTranslation != nil {
            // Reopened mid-translation: keep filling into the remembered mode.
            pendingMode = translatePreference
            translateMode = translatePreference
        } else {
            translateMode = 0
        }
    }

    private func handleTranslationJobChange(_ state: AIContentStore.JobState?) {
        switch state {
        case .none:
            // Finished: apply the pending switch if the result is now available.
            guard let pending = pendingMode else { return }
            if let stored = ai.translation(episodeId), stored.language == settings.translationLanguage {
                translation = stored.sentences
                translateMode = pending
                translatePreference = pending
            }
            pendingMode = nil
        case .failed(let message):
            if pendingMode != nil {
                pendingMode = nil
                // Nothing committed (we may have optimistically switched while
                // streaming) — fall back to the original.
                if translation == nil { translateMode = 0 }
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
        guard isCurrentEpisode, let cues = loadedCues, !cues.isEmpty else {
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
