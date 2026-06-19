import Combine
import Foundation

/// Owns OpenAI-derived study material for episodes: transcripts and AI handouts.
/// Content is saved as plain files under Documents/ai/ (no DB, matching the rest
/// of the app) keyed by episode id, and per-episode job state is published so the
/// action icons can show progress. Jobs run on this singleton, so they continue
/// even if the player sheet is dismissed mid-processing.
@MainActor
final class AIContentStore: ObservableObject {
    static let shared = AIContentStore()

    enum Kind: String { case transcript, handout }

    enum JobState: Equatable {
        case running(String)   // status note for the UI
        case failed(String)    // error message
    }

    /// Keyed "transcript:{id}" / "handout:{id}"; absence means idle.
    @Published private(set) var jobs: [String: JobState] = [:]

    /// Translation jobs, keyed by episode id; absence means idle. Translation is
    /// triggered from the transcript screen (not the shared AI action buttons), so
    /// it gets its own published map rather than another `Kind`.
    @Published private(set) var translationJobs: [String: JobState] = [:]

    private let transcriptsDir: URL
    private let handoutsDir: URL
    /// Sidecar timestamp cues for transcripts, keyed by episode id. Kept in their
    /// own directory (not alongside the `.txt`) so the transcript/handout file
    /// enumeration and counts stay clean. Local-only: not mirrored to iCloud, so a
    /// transcript synced from another device shows without highlighting.
    private let cuesDir: URL
    /// Per-episode transcript translations (one display sentence per line, in the
    /// target language). Keyed by episode id like the other AI content; mirrored
    /// to iCloud as a `translation.json` sidecar alongside the transcript.
    private let translationsDir: URL
    private let indexURL: URL
    /// episode id -> the episode's record, for every episode that has a
    /// transcript or handout. Powers the AI tab, supplies readable iCloud folder
    /// names (even for content generated while sync was off, when the in-memory
    /// record is gone), and is mirrored to iCloud KVS so the AI tab restores on
    /// other devices / after reinstall.
    @Published private(set) var records: [String: EpisodeRecord] = [:]

    private static let kvsPrefix = "ai-rec-"
    /// Whether to write records through to / adopt them from iCloud KVS.
    private var syncingRecords = false

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let aiDir = docs.appendingPathComponent("ai", isDirectory: true)
        transcriptsDir = aiDir.appendingPathComponent("transcripts", isDirectory: true)
        handoutsDir = aiDir.appendingPathComponent("handouts", isDirectory: true)
        cuesDir = aiDir.appendingPathComponent("cues", isDirectory: true)
        translationsDir = aiDir.appendingPathComponent("translations", isDirectory: true)
        indexURL = aiDir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: handoutsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cuesDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: translationsDir, withIntermediateDirectories: true)

        cleanupMalformedLocalContent()
        loadIndex()
        backfillIndex()

        // Files pulled from iCloud appear/disappear under us; refresh the
        // hasTranscript/hasHandout-driven UI when that happens.
        ICloudSync.shared.onDidPull = { [weak self] in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        if SettingsStore.shared.syncToICloud { enableICloudSync() }
    }

    /// Records of episodes that have a transcript or handout — the AI tab's list.
    var aiRecords: [EpisodeRecord] {
        records.values.filter { hasTranscript($0.id) || hasHandout($0.id) }
    }

    /// Whether the user has opted into mirroring AI content to iCloud.
    private var syncOn: Bool { SettingsStore.shared.syncToICloud }

    private func cloudKind(_ kind: Kind) -> ICloudSync.Kind {
        kind == .transcript ? .transcript : .handout
    }

    // MARK: - iCloud sync

    /// Start watching for incoming files and push everything we already have up
    /// (with readable names), and bring the record index into KVS sync. Called at
    /// launch when enabled and when the user flips the toggle on.
    func enableICloudSync() {
        ICloudSync.shared.start()
        for kind in [Kind.transcript, .handout] {
            let dir = kind == .transcript ? transcriptsDir : handoutsDir
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == cloudKind(kind).localExt {
                let id = file.deletingPathExtension().lastPathComponent
                ICloudSync.shared.mirrorUp(cloudKind(kind), id: id, displayName: records[id].map(Self.displayName))
            }
        }
        // Cue + translation sidecars sync as their own ICloudSync kinds (neither
        // has an AIContentStore.Kind of its own).
        for (dir, kind) in [(cuesDir, ICloudSync.Kind.cues), (translationsDir, .translation)] {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                let id = file.deletingPathExtension().lastPathComponent
                ICloudSync.shared.mirrorUp(kind, id: id, displayName: records[id].map(Self.displayName))
            }
        }
        enableRecordSync()
    }

    func disableICloudSync() {
        ICloudSync.shared.stop()
        syncingRecords = false
        CloudKVStore.shared.unobserve(self)
    }

    // MARK: - Record index (powers the AI tab + readable iCloud names)

    private func loadIndex() {
        if let data = try? Data(contentsOf: indexURL),
           let map = try? JSONDecoder().decode([String: EpisodeRecord].self, from: data) {
            records = map
        }
    }

    private func persistIndex() {
        try? JSONEncoder().encode(records).write(to: indexURL)
    }

    /// Record that an episode now has AI content; persist and (if syncing) push up.
    private func noteRecord(_ record: EpisodeRecord) {
        records[record.id] = record
        persistIndex()
        if syncingRecords, let data = try? JSONEncoder().encode(record) {
            CloudKVStore.shared.set(data, forKey: Self.kvsPrefix + record.id)
        }
        // Newly generated content (transcript/handout/cues/translation files +
        // index) rides up to Drive on the next debounced sync.
        DriveSync.requestSync()
    }

    /// Re-read the record index after a Google Drive pull rewrote `ai/index.json`,
    /// and refresh the content-file-driven UI (a pull may have added transcript or
    /// handout files even when the index didn't change).
    func reloadIndex() {
        if let data = try? Data(contentsOf: indexURL),
           let map = try? JSONDecoder().decode([String: EpisodeRecord].self, from: data) {
            records = map
        }
        objectWillChange.send()
    }

    /// Build records for content generated before the index stored them, using
    /// whatever episode records downloads/favorites still hold.
    private func backfillIndex() {
        var known: [String: EpisodeRecord] = [:]
        for r in DownloadManager.shared.records { known[r.id] = r }
        for r in FavoritesStore.shared.favorites { known[r.id] = r }
        var changed = false
        for id in storedContentIds() where records[id] == nil {
            if let record = known[id] { records[id] = record; changed = true }
        }
        if changed { persistIndex() }
    }

    /// Delete locally-stored content whose id is malformed — junk an earlier bug
    /// created by pulling truncated iCloud folders under their (unparseable) folder
    /// name instead of an episode id. A real id is a UUID or "pod-<hex>": ASCII
    /// letters, digits and hyphens only, so anything containing a space, bracket or
    /// other character is junk. Removing it also stops it being mirrored back up.
    private func cleanupMalformedLocalContent() {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
        for dir in [transcriptsDir, handoutsDir, cuesDir, translationsDir] {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for item in items {
                let id = item.deletingPathExtension().lastPathComponent
                if id.isEmpty || id.rangeOfCharacter(from: allowed.inverted) != nil {
                    try? FileManager.default.removeItem(at: item)
                }
            }
        }
    }

    // MARK: - Record KVS sync

    private func enableRecordSync() {
        guard !syncingRecords else { return }
        syncingRecords = true
        CloudKVStore.shared.observe(self, selector: #selector(recordsChangedInKVS))
        // Push any local records KVS is missing, then adopt anything new from KVS.
        for (id, record) in records where CloudKVStore.shared.data(forKey: Self.kvsPrefix + id) == nil {
            if let data = try? JSONEncoder().encode(record) {
                CloudKVStore.shared.set(data, forKey: Self.kvsPrefix + id)
            }
        }
        adoptRecordsFromKVS()
        CloudKVStore.shared.synchronize()
    }

    @objc private func recordsChangedInKVS() {
        Task { @MainActor in self.adoptRecordsFromKVS() }
    }

    /// Additively adopt records from KVS (the AI tab itself is gated on the
    /// content files actually being present, so extra records are harmless and we
    /// never drop a record that has local files).
    private func adoptRecordsFromKVS() {
        var changed = false
        for entry in CloudKVStore.shared.entries(prefix: Self.kvsPrefix) {
            if let record = try? JSONDecoder().decode(EpisodeRecord.self, from: entry.data),
               records[record.id] == nil {
                records[record.id] = record
                changed = true
            }
        }
        if changed {
            persistIndex()
            DriveSync.requestSync()   // keep the Drive mirror in step with iCloud
        }
    }

    private func storedContentIds() -> Set<String> {
        var ids = Set<String>()
        for dir in [transcriptsDir, handoutsDir] {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for item in items { ids.insert(item.deletingPathExtension().lastPathComponent) }
        }
        return ids
    }

    static func displayName(_ record: EpisodeRecord) -> String {
        let program = record.programName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (program.isEmpty, title.isEmpty) {
        case (false, false): return "\(program) - \(title)"
        case (false, true): return program
        case (true, false): return title
        case (true, true): return record.id
        }
    }

    // MARK: - Storage queries

    private func transcriptURL(_ id: String) -> URL { transcriptsDir.appendingPathComponent("\(id).txt") }
    private func handoutURL(_ id: String) -> URL { handoutsDir.appendingPathComponent("\(id).html") }
    private func cuesURL(_ id: String) -> URL { cuesDir.appendingPathComponent("\(id).json") }
    private func translationURL(_ id: String) -> URL { translationsDir.appendingPathComponent("\(id).json") }

    func hasTranscript(_ id: String) -> Bool { FileManager.default.fileExists(atPath: transcriptURL(id).path) }
    func hasHandout(_ id: String) -> Bool { FileManager.default.fileExists(atPath: handoutURL(id).path) }

    /// The saved translation for an episode, if any. Carries its target language
    /// so the transcript screen can tell whether it matches the current setting.
    func translation(_ id: String) -> StoredTranslation? {
        guard let data = try? Data(contentsOf: translationURL(id)) else { return nil }
        return try? JSONDecoder().decode(StoredTranslation.self, from: data)
    }

    /// Counts of saved content, for the 資料統計 screen.
    var transcriptCount: Int { fileCount(transcriptsDir) }
    var handoutCount: Int { fileCount(handoutsDir) }
    var translationCount: Int { fileCount(translationsDir) }

    private func fileCount(_ dir: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.count ?? 0
    }

    func transcriptText(_ id: String) -> String? { try? String(contentsOf: transcriptURL(id), encoding: .utf8) }
    func handoutHTML(_ id: String) -> String? { try? String(contentsOf: handoutURL(id), encoding: .utf8) }

    /// Timestamp cues for an episode's transcript, when present. Returns nil for
    /// transcripts made before cues existed (or with a no-timestamp model), which
    /// the transcript screen renders without highlighting.
    func transcriptCues(_ id: String) -> [TranscriptCue]? {
        guard let data = try? Data(contentsOf: cuesURL(id)) else { return nil }
        return try? JSONDecoder().decode([TranscriptCue].self, from: data)
    }

    func jobState(_ kind: Kind, _ id: String) -> JobState? { jobs[key(kind, id)] }

    func translationJob(_ id: String) -> JobState? { translationJobs[id] }

    // MARK: - Triggers

    func processTranscript(_ record: EpisodeRecord) {
        guard jobs[key(.transcript, record.id)] == nil, !hasTranscript(record.id) else { return }
        Task { await runTranscript(record) }
    }

    /// Generate (or regenerate, if the language changed) the translation for an
    /// episode's transcript. No-ops while a job is already running for it.
    func translate(_ record: EpisodeRecord) {
        if case .running = translationJobs[record.id] { return }
        Task { await runTranslation(record) }
    }

    func processHandout(_ record: EpisodeRecord) {
        guard jobs[key(.handout, record.id)] == nil, !hasHandout(record.id) else { return }
        Task { await runHandout(record) }
    }

    func clearAll() {
        let ids = Array(records.keys)
        for dir in [transcriptsDir, handoutsDir, cuesDir, translationsDir] {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for item in items { try? FileManager.default.removeItem(at: item) }
        }
        if syncOn { ICloudSync.shared.removeAllUp() }
        if syncingRecords { for id in ids { CloudKVStore.shared.remove(Self.kvsPrefix + id) } }
        records.removeAll()
        persistIndex()
        jobs.removeAll()
        translationJobs.removeAll()
        DriveSync.requestSync()
    }

    /// Delete one episode's saved content of `kind`. `objectWillChange` fires so
    /// the action button drops back to its idle state.
    func delete(_ kind: Kind, _ id: String) {
        objectWillChange.send()
        let url = kind == .transcript ? transcriptURL(id) : handoutURL(id)
        try? FileManager.default.removeItem(at: url)
        if kind == .transcript {
            // The cue + translation sidecars are derived from this transcript, so
            // they go with it (a regenerated transcript may re-segment differently).
            try? FileManager.default.removeItem(at: cuesURL(id))
            try? FileManager.default.removeItem(at: translationURL(id))
            translationJobs.removeValue(forKey: id)
            if syncOn {
                ICloudSync.shared.removeUp(.cues, id: id)
                ICloudSync.shared.removeUp(.translation, id: id)
            }
        }
        if syncOn { ICloudSync.shared.removeUp(cloudKind(kind), id: id) }
        jobs.removeValue(forKey: key(kind, id))
        // If nothing is left for this episode, drop its record (and its KVS copy).
        if !hasTranscript(id) && !hasHandout(id) {
            records.removeValue(forKey: id)
            persistIndex()
            if syncingRecords { CloudKVStore.shared.remove(Self.kvsPrefix + id) }
        }
    }

    /// Delete the saved content and immediately re-run it with current settings.
    func regenerate(_ kind: Kind, _ record: EpisodeRecord) {
        delete(kind, record.id)
        switch kind {
        case .transcript: processTranscript(record)
        case .handout: processHandout(record)
        }
    }

    // MARK: - Work

    /// Transcribe (idempotent). Returns the transcript text, or nil on failure
    /// (in which case the transcript job carries the error message).
    @discardableResult
    private func runTranscript(_ record: EpisodeRecord) async -> String? {
        if let existing = transcriptText(record.id) { return existing }
        let k = key(.transcript, record.id)
        let settings = SettingsStore.shared
        jobs[k] = .running("處理音訊中…")
        do {
            guard let source = try await audioFileURL(for: record) else {
                throw OpenAIService.APIError.server("找不到音訊檔")
            }
            jobs[k] = .running("轉錄中…")
            // Long episodes are split into chunks (the gpt-4o-transcribe models
            // cap input at 1400 s); transcribe each and join. Whisper also returns
            // per-segment timestamps, collected (in absolute episode time) to drive
            // sentence highlighting.
            let chunks = await SpeechAudioExporter.exportChunks(source)
            defer { cleanupChunks(chunks, original: source) }
            // A monolingual source (a podcast) carries its locale: force that
            // language and drop the Chinese teaching-program prompt, which would
            // otherwise bias a foreign-language podcast toward Chinese. NER programs
            // are bilingual (Mandarin host + foreign examples), so they keep the
            // priming prompt and no forced language, letting whisper switch per passage.
            let locale = record.audioLocale
            let prompt = locale == nil ? OpenAIService.transcriptionPrompt(for: record.language) : nil
            var parts: [String] = []
            var segments: [OpenAIService.Segment] = []
            for (i, chunk) in chunks.enumerated() {
                if chunks.count > 1 { jobs[k] = .running("轉錄中…（\(i + 1)/\(chunks.count)）") }
                let result = try await OpenAIService.transcribe(
                    fileURL: chunk, model: settings.transcriptionModel, apiKey: settings.apiKey,
                    prompt: prompt, language: locale)
                parts.append(result.text)
                if !result.segments.isEmpty {
                    // Shift each chunk's timestamps onto the absolute episode
                    // timeline. A chunk file is normally 0-based, so add its start
                    // offset; but a trimmed chunk can carry a baked-in source-time
                    // offset, detected here (times already near the chunk's absolute
                    // position) and then used as-is. Single-chunk episodes — the
                    // common case — are i == 0, so times pass through unchanged.
                    let chunkStart = Double(i) * SpeechAudioExporter.maxChunkSeconds
                    let minStart = result.segments.map(\.start).min() ?? 0
                    let offset = (i > 0 && minStart > chunkStart * 0.5) ? 0 : chunkStart
                    segments.append(contentsOf: result.segments.map {
                        OpenAIService.Segment(start: $0.start + offset, text: $0.text)
                    })
                }
            }
            let raw = parts.joined(separator: "\n")

            // Re-segment into one sentence per line with the chat model (adds
            // sentence-ending punctuation only, never alters content). If that
            // step fails, keep the raw transcript so the paid transcription isn't lost.
            jobs[k] = .running("整理句子中…")
            let text = (try? await OpenAIService.segmentTranscript(
                raw, model: settings.chatModel, apiKey: settings.apiKey)) ?? raw

            try text.data(using: .utf8)?.write(to: transcriptURL(record.id))

            // B3b: map each cleaned display sentence back to the ASR segment that
            // covers its first content character, so each gets a start time. Best
            // effort — no segments (e.g. a non-whisper model) means no cues file
            // and the transcript simply shows without highlighting.
            let sentences = Self.displaySentences(text)
            let cues = Self.alignCues(sentences: sentences, segments: segments)
            if !cues.isEmpty, let data = try? JSONEncoder().encode(cues) {
                try? data.write(to: cuesURL(record.id))
            } else {
                try? FileManager.default.removeItem(at: cuesURL(record.id))
            }
            noteRecord(record)
            if syncOn {
                let name = Self.displayName(record)
                ICloudSync.shared.mirrorUp(.transcript, id: record.id, displayName: name)
                // The cue sidecar rides up alongside its transcript so other devices
                // get the highlighting too.
                if !cues.isEmpty { ICloudSync.shared.mirrorUp(.cues, id: record.id, displayName: name) }
            }
            jobs.removeValue(forKey: k)   // publishes → hasTranscript-driven UI refreshes
            return text
        } catch {
            jobs[k] = .failed(error.localizedDescription)
            return nil
        }
    }

    /// Each handout "Part" covers at most this many seconds of audio (~15 min),
    /// so a long episode is split into digestible Part I/II/III sections.
    private static let handoutPartSeconds = 900

    private func runHandout(_ record: EpisodeRecord) async {
        let k = key(.handout, record.id)
        let settings = SettingsStore.shared
        jobs[k] = .running("準備逐字稿…")
        do {
            guard let transcript = await runTranscript(record) else {
                if case .failed(let m)? = jobs[key(.transcript, record.id)] {
                    throw OpenAIService.APIError.server(m)
                }
                throw OpenAIService.APIError.server("逐字稿失敗")
            }

            // Episodes longer than ~15 min are split into time-based parts, each
            // its own Part I/II/III handout section; shorter ones stay a single
            // handout.
            let segments = Self.handoutSegments(transcript, durationSeconds: record.durationSeconds)
            var fragments: [String] = []
            for (i, segment) in segments.enumerated() {
                jobs[k] = segments.count > 1
                    ? .running("生成講義中…（\(i + 1)/\(segments.count)）")
                    : .running("生成講義中…")
                let partTitle = segments.count > 1
                    ? Self.partTitle(index: i, total: segments.count, duration: record.durationSeconds)
                    : nil
                fragments.append(try await OpenAIService.generateHandout(
                    transcript: segment, record: record, partTitle: partTitle,
                    model: settings.chatModel, apiKey: settings.apiKey))
            }
            let html = Self.wrapHTML(fragments.joined(separator: "\n"), title: record.title)
            try html.data(using: .utf8)?.write(to: handoutURL(record.id))
            noteRecord(record)
            if syncOn { ICloudSync.shared.mirrorUp(.handout, id: record.id, displayName: Self.displayName(record)) }
            jobs.removeValue(forKey: k)
        } catch {
            jobs[k] = .failed(error.localizedDescription)
        }
    }

    /// Translate an episode's transcript into the current target language and save
    /// it sentence-aligned. Overwrites any existing translation (e.g. when the
    /// target language changed). Requires the transcript to already exist.
    private func runTranslation(_ record: EpisodeRecord) async {
        let id = record.id
        let settings = SettingsStore.shared
        let language = settings.translationLanguage
        guard let text = transcriptText(id) else {
            translationJobs[id] = .failed("找不到逐字稿")
            return
        }
        translationJobs[id] = .running("翻譯中…")
        do {
            let sentences = Self.displaySentences(text)
            let translated = try await OpenAIService.translateSentences(
                sentences, to: language, model: settings.chatModel, apiKey: settings.apiKey)
            let stored = StoredTranslation(language: language, sentences: translated)
            try JSONEncoder().encode(stored).write(to: translationURL(id))
            noteRecord(record)
            if syncOn {
                ICloudSync.shared.mirrorUp(.translation, id: id, displayName: Self.displayName(record))
            }
            translationJobs.removeValue(forKey: id)   // publishes → transcript screen reloads
        } catch {
            translationJobs[id] = .failed(error.localizedDescription)
        }
    }

    /// Split the transcript into one segment per ~15-minute part. Returns a single
    /// segment when the episode is ≤15 min (or its length is unknown and the
    /// transcript is short). Segments are balanced by character count and broken
    /// only at line (sentence) boundaries, since the transcript is one sentence
    /// per line.
    static func handoutSegments(_ transcript: String, durationSeconds: Int?) -> [String] {
        let parts: Int
        if let dur = durationSeconds, dur > 0 {
            parts = max(1, Int((Double(dur) / Double(handoutPartSeconds)).rounded(.up)))
        } else {
            // Unknown duration: ~3500 chars ≈ 15 min of speech.
            parts = max(1, Int((Double(transcript.count) / 3500.0).rounded(.up)))
        }
        guard parts > 1 else { return [transcript] }

        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let target = max(1, transcript.count / parts)
        var segments: [String] = []
        var current: [String] = []
        var currentChars = 0
        for line in lines {
            current.append(line)
            currentChars += line.count + 1
            if currentChars >= target, segments.count < parts - 1 {
                segments.append(current.joined(separator: "\n"))
                current = []
                currentChars = 0
            }
        }
        if !current.isEmpty { segments.append(current.joined(separator: "\n")) }
        return segments
    }

    /// The display sentences of a stored transcript: one trimmed, non-empty line
    /// each. Must match how `TranscriptView` splits the same text so the cues line
    /// up one-to-one with the rendered rows.
    static func displaySentences(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Map each cleaned display `sentence` to a start time by aligning it to the
    /// timed ASR `segments` (B3b). The chat re-segmentation only adds punctuation
    /// and line breaks — it never changes the underlying content characters — so a
    /// sentence's content (letters/digits, ignoring spaces and punctuation) appears
    /// in order within the segment stream. We walk both monotonically and read off
    /// each sentence's start from the segment covering its first content character.
    /// Returns [] if there are no segments to align against.
    static func alignCues(sentences: [String], segments: [OpenAIService.Segment]) -> [TranscriptCue] {
        guard !segments.isEmpty, !sentences.isEmpty else { return [] }
        func isContent(_ c: Character) -> Bool { c.isLetter || c.isNumber }

        // Flatten segment text into a stream of content characters, each tagged
        // with its segment's start time.
        var chars: [Character] = []
        var times: [Double] = []
        for seg in segments {
            for c in seg.text where isContent(c) {
                chars.append(c)
                times.append(seg.start)
            }
        }
        guard !chars.isEmpty else { return [] }

        var cues: [TranscriptCue] = []
        cues.reserveCapacity(sentences.count)
        var idx = 0
        var lastStart = times[0]
        for sentence in sentences {
            let content = sentence.filter(isContent)
            if let first = content.first {
                // Resync: find this sentence's first content char at/after the
                // cursor, scanning a small window to absorb any minor ASR/chat drift.
                let limit = min(chars.count, idx + 32)
                var probe = idx
                while probe < limit && chars[probe] != first { probe += 1 }
                if probe < limit { idx = probe }
            }
            let start = idx < times.count ? times[idx] : lastStart
            lastStart = start
            cues.append(TranscriptCue(start: start, text: sentence))
            idx = min(chars.count, idx + max(1, content.count))
        }
        return cues
    }

    /// "Part I（00:00–15:00）" — Roman numeral plus the part's audio time range
    /// (range omitted when the duration is unknown).
    static func partTitle(index: Int, total: Int, duration: Int?) -> String {
        let label = "Part \(romanNumeral(index + 1))"
        guard let duration, duration > 0 else { return label }
        let start = index * handoutPartSeconds
        let end = (index == total - 1) ? duration : (index + 1) * handoutPartSeconds
        return "\(label)（\(timeStamp(start))–\(timeStamp(end))）"
    }

    private static func timeStamp(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func romanNumeral(_ value: Int) -> String {
        let table: [(Int, String)] = [(10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = value, result = ""
        for (v, r) in table { while n >= v { result += r; n -= v } }
        return result
    }

    /// Local download if present, otherwise fetch the remote audio to a temp file.
    private func audioFileURL(for record: EpisodeRecord) async throws -> URL? {
        if let local = DownloadManager.shared.localAssetURL(episodeId: record.id) {
            return local
        }
        guard let remote = record.audio.flatMap(URL.init(string:)) else { return nil }
        var request = URLRequest(url: remote)
        request.timeoutInterval = 300
        let (tmp, _) = try await URLSession.shared.download(for: request)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-\(record.id)-\(UUID().uuidString).mp3")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Remove the transcoded chunk temp files and any audio we downloaded to temp,
    /// leaving the persistent offline download (if that's what we used) intact.
    private func cleanupChunks(_ chunks: [URL], original: URL) {
        let tmp = FileManager.default.temporaryDirectory.path
        for chunk in chunks where chunk != original && chunk.path.hasPrefix(tmp) {
            try? FileManager.default.removeItem(at: chunk)
        }
        if original.path.hasPrefix(tmp) {
            try? FileManager.default.removeItem(at: original)
        }
    }

    private func key(_ kind: Kind, _ id: String) -> String { "\(kind.rawValue):\(id)" }

    /// Wrap the model's HTML fragment in a styled, dark-mode-aware document.
    static func wrapHTML(_ fragment: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="zh-Hant">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>
          :root { color-scheme: light dark; }
          body {
            font-family: -apple-system, "PingFang TC", system-ui, sans-serif;
            font-size: 17px;
            line-height: 1.7;
            margin: 0;
            padding: 16px max(16px, env(safe-area-inset-right)) calc(28px + env(safe-area-inset-bottom)) max(16px, env(safe-area-inset-left));
            color: #1c1c1e;
            background: #ffffff;
            -webkit-text-size-adjust: 100%;
            word-wrap: break-word;
          }
          h1 { font-size: 1.4em; margin: 0 0 .6em; }
          h2 {
            font-size: 1.2em;
            margin-top: 1.6em;
            padding-bottom: .3em;
            border-bottom: 2px solid #0a84ff;
            color: #0a84ff;
          }
          h3 { font-size: 1.05em; }
          table { border-collapse: collapse; width: 100%; margin: .6em 0; }
          th, td { border: 1px solid #d1d1d6; padding: 6px 8px; text-align: left; vertical-align: top; }
          th { background: rgba(10,132,255,0.1); }
          ul, ol { padding-left: 1.3em; }
          li { margin: .25em 0; }
          ruby rt { font-size: .6em; }
          code { background: rgba(120,120,128,0.16); padding: .1em .3em; border-radius: 4px; }
          @media (prefers-color-scheme: dark) {
            body { color: #f2f2f7; background: #1c1c1e; }
            th, td { border-color: #3a3a3c; }
            code { background: rgba(120,120,128,0.32); }
          }
        </style>
        </head>
        <body>
        <h1>\(escapeHTML(title))</h1>
        \(fragment)
        </body>
        </html>
        """
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
