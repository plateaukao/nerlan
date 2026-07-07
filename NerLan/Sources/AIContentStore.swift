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

    /// A transcript still being produced, published per ~20-minute audio chunk so
    /// the viewer can show the first chunk while later chunks are still
    /// transcribing. `cues` is either empty or 1:1 with `sentences` (never
    /// partially aligned). In-memory only — never persisted or synced; the finished
    /// transcript file becomes the source of truth once written.
    struct PartialTranscript: Equatable {
        var sentences: [String]
        var cues: [TranscriptCue]
    }

    /// Keyed "transcript:{id}" / "handout:{id}"; absence means idle.
    @Published private(set) var jobs: [String: JobState] = [:]

    /// Translation jobs, keyed by episode id; absence means idle. Translation is
    /// triggered from the transcript screen (not the shared AI action buttons), so
    /// it gets its own published map rather than another `Kind`.
    @Published private(set) var translationJobs: [String: JobState] = [:]

    /// Transcript content streamed while a transcription job runs, keyed by episode
    /// id; absence means no job is in flight (use the saved file). See `PartialTranscript`.
    @Published private(set) var partialTranscripts: [String: PartialTranscript] = [:]

    /// Translation streamed per batch (~40 sentences) while a translation job runs,
    /// keyed by episode id, so the transcript screen fills in top-down. Carries its
    /// target language so a partial for the wrong language is ignored. Cleared on completion.
    @Published private(set) var partialTranslations: [String: StoredTranslation] = [:]

    /// Set when a user-initiated transcript reaches its first chunk (or is already
    /// saved): a stable presenter — `ContentView` on iPhone, the side panel on
    /// iPad — opens the viewer and clears this. Lives on the store, not the action
    /// button, so the auto-open survives the player sheet that started it being
    /// dismissed (e.g. the user swipes the player away to keep listening while the
    /// transcript is still chunking). See `transcribeAndOpen`.
    @Published var presentTranscript: EpisodeRecord?

    /// Episode ids the user asked to view as soon as transcription produces its
    /// first chunk. Drained into `presentTranscript` when that chunk lands.
    private var autoOpenTranscriptIds: Set<String> = []

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
        _ = transcriptTask(record)
    }

    /// In-flight transcriptions by episode id, so concurrent callers — the
    /// transcript button and a handout that needs the transcript — share one job
    /// instead of downloading/transcribing (and paying for) the episode twice.
    private var transcriptTasks: [String: Task<String?, Never>] = [:]

    /// Handout / translation jobs in flight, so delete/clearAll can cancel them —
    /// otherwise a job finishing after the delete rewrites the file and the
    /// "cleared" content resurrects (while still costing OpenAI credit).
    private var handoutTasks: [String: Task<Void, Never>] = [:]
    private var translationTasks: [String: Task<Void, Never>] = [:]

    /// The running transcription for an episode, starting one if needed.
    private func transcriptTask(_ record: EpisodeRecord) -> Task<String?, Never> {
        if let running = transcriptTasks[record.id] { return running }
        let id = record.id
        var task: Task<String?, Never>!
        task = Task { [weak self] () -> String? in
            let text = await self?.runTranscript(record)
            // Only drop our own registration — a cancelled run must not remove
            // the replacement task a regenerate may have installed meanwhile.
            if let self, self.transcriptTasks[id] == task { self.transcriptTasks.removeValue(forKey: id) }
            return text
        }
        transcriptTasks[id] = task
        return task
    }

    /// Start a transcript (if needed) and open the viewer as soon as content is
    /// ready — immediately if it's already saved, else the moment its first chunk
    /// lands (see `presentTranscript`). Used by the action button so the open no
    /// longer depends on that button still being on screen when the chunk arrives.
    func transcribeAndOpen(_ record: EpisodeRecord) {
        if hasTranscript(record.id) { presentTranscript = record; return }
        autoOpenTranscriptIds.insert(record.id)
        // Clear a prior failure so retrying actually re-runs (processTranscript
        // no-ops while any job — including a failed one — is recorded).
        if case .failed = jobs[key(.transcript, record.id)] {
            jobs.removeValue(forKey: key(.transcript, record.id))
        }
        processTranscript(record)
    }

    /// Generate (or regenerate, if the language changed) the translation for an
    /// episode's transcript. No-ops while a job is already running for it.
    func translate(_ record: EpisodeRecord) {
        if case .running = translationJobs[record.id] { return }
        let id = record.id
        var task: Task<Void, Never>!
        task = Task { [weak self] in
            await self?.runTranslation(record)
            if let self, self.translationTasks[id] == task { self.translationTasks.removeValue(forKey: id) }
        }
        translationTasks[id] = task
    }

    func processHandout(_ record: EpisodeRecord) {
        // Clear a prior failure so the error alert's 重試 actually re-runs — the
        // guard below no-ops while any job, including a failed one, is recorded
        // (the transcript path does the same in transcribeAndOpen).
        if case .failed = jobs[key(.handout, record.id)] {
            jobs.removeValue(forKey: key(.handout, record.id))
        }
        guard jobs[key(.handout, record.id)] == nil, !hasHandout(record.id) else { return }
        let id = record.id
        var task: Task<Void, Never>!
        task = Task { [weak self] in
            await self?.runHandout(record)
            if let self, self.handoutTasks[id] == task { self.handoutTasks.removeValue(forKey: id) }
        }
        handoutTasks[id] = task
    }

    func clearAll() {
        // Stop every in-flight generation first: a job that outlived the clear
        // would rewrite its file, re-note the record, and resurrect the content.
        for task in transcriptTasks.values { task.cancel() }
        for task in handoutTasks.values { task.cancel() }
        for task in translationTasks.values { task.cancel() }
        transcriptTasks.removeAll()
        handoutTasks.removeAll()
        translationTasks.removeAll()
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
        partialTranscripts.removeAll()
        partialTranslations.removeAll()
        autoOpenTranscriptIds.removeAll()
        presentTranscript = nil
        DriveSync.requestSync()
    }

    /// Delete one episode's saved content of `kind`. `objectWillChange` fires so
    /// the action button drops back to its idle state.
    func delete(_ kind: Kind, _ id: String) {
        objectWillChange.send()
        // Stop the matching in-flight generation so it can't finish after the
        // delete and rewrite the file. A deleted transcript also takes its
        // translation job with it (the sidecar files below go the same way).
        if kind == .transcript {
            transcriptTasks.removeValue(forKey: id)?.cancel()
            translationTasks.removeValue(forKey: id)?.cancel()
        } else {
            handoutTasks.removeValue(forKey: id)?.cancel()
        }
        let url = kind == .transcript ? transcriptURL(id) : handoutURL(id)
        try? FileManager.default.removeItem(at: url)
        if kind == .transcript {
            // The cue + translation sidecars are derived from this transcript, so
            // they go with it (a regenerated transcript may re-segment differently).
            try? FileManager.default.removeItem(at: cuesURL(id))
            try? FileManager.default.removeItem(at: translationURL(id))
            translationJobs.removeValue(forKey: id)
            partialTranscripts.removeValue(forKey: id)
            partialTranslations.removeValue(forKey: id)
            autoOpenTranscriptIds.remove(id)
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
            // Long episodes are split into ~20-minute chunks (the gpt-4o-transcribe
            // models cap input at 1400 s). Each chunk is transcribed, re-segmented
            // and aligned on its own, then appended and published — so the viewer
            // can show the first chunk while later chunks are still transcribing,
            // rather than waiting for the whole episode. Whisper returns per-segment
            // timestamps (shifted to absolute episode time) to drive highlighting.
            let chunks = await SpeechAudioExporter.exportChunks(source)
            defer { cleanupChunks(chunks, original: source) }
            // A monolingual source (a podcast) carries its locale: force that
            // language and drop the Chinese teaching-program prompt, which would
            // otherwise bias a foreign-language podcast toward Chinese. NER programs
            // are bilingual (Mandarin host + foreign examples), so they keep the
            // priming prompt and no forced language, letting whisper switch per passage.
            let locale = record.audioLocale
            let prompt = locale == nil ? OpenAIService.transcriptionPrompt(for: record.language) : nil
            let txConfig = settings.transcriptionConfig
            let chatConfig = settings.chatConfig
            let multi = chunks.count > 1
            var sentences: [String] = []
            var cues: [TranscriptCue] = []
            // Cues stay usable only while every chunk so far yields timestamps; once
            // one doesn't (e.g. a non-whisper model), the transcript renders without
            // highlighting rather than with cues that drift out of alignment.
            var cuesAligned = true
            for (i, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                jobs[k] = .running(multi ? "轉錄中…（\(i + 1)/\(chunks.count)）" : "轉錄中…")
                let result = try await OpenAIService.transcribe(
                    fileURL: chunk, config: txConfig,
                    prompt: prompt, language: locale)

                // Shift this chunk's timestamps onto the absolute episode timeline.
                // A chunk file is normally 0-based, so add its start offset; but a
                // trimmed chunk can carry a baked-in source-time offset, detected
                // here (times already near the chunk's absolute position) and used
                // as-is. The first chunk is i == 0, so its times pass through.
                let chunkStart = Double(i) * SpeechAudioExporter.maxChunkSeconds
                let minStart = result.segments.map(\.start).min() ?? 0
                let offset = (i > 0 && minStart > chunkStart * 0.5) ? 0 : chunkStart
                let chunkSegments = result.segments.map {
                    OpenAIService.Segment(start: $0.start + offset, text: $0.text)
                }

                // Re-segment just this chunk into one sentence per line with the chat
                // model (adds sentence-ending punctuation only, never alters content);
                // on failure keep the chunk's raw text so the paid transcription isn't
                // lost. Then align its sentences to its own timestamps (B3b).
                jobs[k] = .running(multi ? "整理句子中…（\(i + 1)/\(chunks.count)）" : "整理句子中…")
                let chunkText = (try? await OpenAIService.segmentTranscript(
                    result.text, config: chatConfig)) ?? result.text
                let chunkSentences = Self.displaySentences(chunkText)
                let chunkCues = Self.alignCues(sentences: chunkSentences, segments: chunkSegments)

                sentences.append(contentsOf: chunkSentences)
                if cuesAligned && chunkCues.count == chunkSentences.count {
                    cues.append(contentsOf: chunkCues)
                } else {
                    cuesAligned = false
                }
                // Publish what's ready so an open viewer shows this chunk now. Only
                // attach cues when they still line up 1:1 with the sentences.
                let cuesSoFar = (cuesAligned && cues.count == sentences.count) ? cues : []
                partialTranscripts[record.id] = PartialTranscript(sentences: sentences, cues: cuesSoFar)
                // First chunk is ready — open the viewer now if the user asked to.
                // (Single-chunk episodes hit this too, then finish synchronously;
                // the signal we set here survives that.)
                if i == 0, autoOpenTranscriptIds.remove(record.id) != nil {
                    presentTranscript = record
                }
            }

            try Task.checkCancellation()
            let text = sentences.joined(separator: "\n")
            try text.data(using: .utf8)?.write(to: transcriptURL(record.id))

            // Best effort — no usable timestamps (e.g. a non-whisper model) means no
            // cues file and the transcript simply shows without highlighting.
            let alignedCues = (cuesAligned && cues.count == sentences.count) ? cues : []
            if !alignedCues.isEmpty, let data = try? JSONEncoder().encode(alignedCues) {
                try? data.write(to: cuesURL(record.id))
            } else {
                try? FileManager.default.removeItem(at: cuesURL(record.id))
            }
            // The finished file is now the source of truth; drop the streamed partial.
            partialTranscripts.removeValue(forKey: record.id)
            noteRecord(record)
            if syncOn {
                let name = Self.displayName(record)
                ICloudSync.shared.mirrorUp(.transcript, id: record.id, displayName: name)
                // The cue sidecar rides up alongside its transcript so other devices
                // get the highlighting too.
                if !alignedCues.isEmpty { ICloudSync.shared.mirrorUp(.cues, id: record.id, displayName: name) }
            }
            jobs.removeValue(forKey: k)   // publishes → hasTranscript-driven UI refreshes
            return text
        } catch {
            // Nothing was saved, so drop any streamed partial; the button shows failed.
            partialTranscripts.removeValue(forKey: record.id)
            autoOpenTranscriptIds.remove(record.id)
            // A cancelled run (delete/clearAll) already had its job state cleared —
            // writing .failed would leave a phantom error on the button.
            if !Task.isCancelled { jobs[k] = .failed(error.localizedDescription) }
            return nil
        }
    }

    /// Each handout "Part" covers at most this many seconds of audio (~15 min),
    /// so a long episode is split into digestible Part I/II/III sections.
    private static let handoutPartSeconds = 900

    /// A final part shorter than this (10 min) is considered a stub: the last two
    /// parts are merged and re-split evenly so the episode doesn't end on a sliver.
    private static let handoutMinTailSeconds = 600

    /// Cut points (in seconds) for a `duration`-second episode's handout parts:
    /// `[0, b1, …, duration]`, so part `i` spans `bounds[i]…bounds[i+1]`. Parts cap
    /// at ~15 min, but when the final part would run shorter than 10 min the last
    /// two parts merge and re-split evenly — e.g. 35 min yields `[0, 900, 1500,
    /// 2100]` (0–15, 15–25, 25–35) rather than `[0, 900, 1800, 2100]` (0–15, 15–30,
    /// 30–35). The single source of truth for both `handoutSegments` and
    /// `partTitle`, so the text split and the time labels always agree.
    static func handoutPartBoundaries(duration: Int) -> [Int] {
        let parts = max(1, Int((Double(duration) / Double(handoutPartSeconds)).rounded(.up)))
        guard parts > 1 else { return [0, duration] }
        var bounds = (0..<parts).map { $0 * handoutPartSeconds } + [duration]
        // bounds[parts] == duration; the last part spans bounds[parts-1]…duration.
        if duration - bounds[parts - 1] < handoutMinTailSeconds {
            let mergedStart = bounds[parts - 2]
            bounds[parts - 1] = mergedStart + (duration - mergedStart) / 2
        }
        return bounds
    }

    private func runHandout(_ record: EpisodeRecord) async {
        let k = key(.handout, record.id)
        let settings = SettingsStore.shared
        jobs[k] = .running("準備逐字稿…")
        do {
            // Join any transcription already in flight rather than starting a second.
            guard let transcript = await transcriptTask(record).value else {
                if case .failed(let m)? = jobs[key(.transcript, record.id)] {
                    throw OpenAIService.APIError.server(m)
                }
                throw OpenAIService.APIError.server("逐字稿失敗")
            }

            // Episodes longer than ~15 min are split into time-based parts, each
            // its own Part I/II/III handout section; shorter ones stay a single
            // handout.
            let segments = Self.handoutSegments(transcript, durationSeconds: record.durationSeconds)
            let chatConfig = settings.chatConfig
            var fragments: [String] = []
            for (i, segment) in segments.enumerated() {
                try Task.checkCancellation()
                jobs[k] = segments.count > 1
                    ? .running("生成講義中…（\(i + 1)/\(segments.count)）")
                    : .running("生成講義中…")
                let partTitle = segments.count > 1
                    ? Self.partTitle(index: i, total: segments.count, duration: record.durationSeconds)
                    : nil
                fragments.append(try await OpenAIService.generateHandout(
                    transcript: segment, record: record, partTitle: partTitle,
                    config: chatConfig))
            }
            try Task.checkCancellation()
            let html = Self.wrapHTML(fragments.joined(separator: "\n"), title: record.title)
            try html.data(using: .utf8)?.write(to: handoutURL(record.id))
            noteRecord(record)
            if syncOn { ICloudSync.shared.mirrorUp(.handout, id: record.id, displayName: Self.displayName(record)) }
            jobs.removeValue(forKey: k)
        } catch {
            if !Task.isCancelled { jobs[k] = .failed(error.localizedDescription) }
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
            // Publish each finished batch (~40 sentences) so the transcript screen
            // fills in top-down instead of waiting for the whole transcript.
            let translated = try await OpenAIService.translateSentences(
                sentences, to: language, config: settings.chatConfig,
                onPartial: { [weak self] soFar in
                    self?.partialTranslations[id] = StoredTranslation(language: language, sentences: soFar)
                })
            try Task.checkCancellation()
            let stored = StoredTranslation(language: language, sentences: translated)
            try JSONEncoder().encode(stored).write(to: translationURL(id))
            noteRecord(record)
            if syncOn {
                ICloudSync.shared.mirrorUp(.translation, id: id, displayName: Self.displayName(record))
            }
            // The saved file is now the source of truth; drop the streamed partial.
            partialTranslations.removeValue(forKey: id)
            translationJobs.removeValue(forKey: id)   // publishes → transcript screen reloads
        } catch {
            partialTranslations.removeValue(forKey: id)
            if !Task.isCancelled { translationJobs[id] = .failed(error.localizedDescription) }
        }
    }

    /// Split the transcript into one segment per ~15-minute part. Returns a single
    /// segment when the episode is ≤15 min (or its length is unknown and the
    /// transcript is short). When the duration is known each part's text is sized
    /// in proportion to its `handoutPartBoundaries` time span (assuming a roughly
    /// constant speaking rate), so the segments line up with the Part I/II/III time
    /// labels; with an unknown duration they fall back to equal character counts.
    /// Breaks land only at line (sentence) boundaries, since the transcript is one
    /// sentence per line.
    static func handoutSegments(_ transcript: String, durationSeconds: Int?) -> [String] {
        let total = transcript.count
        // Cumulative character counts at which to cut, one per internal boundary.
        let cutAt: [Int]
        if let dur = durationSeconds, dur > 0 {
            let bounds = handoutPartBoundaries(duration: dur)
            guard bounds.count > 2 else { return [transcript] }   // single part
            cutAt = bounds.dropFirst().dropLast().map {
                Int((Double(total) * Double($0) / Double(dur)).rounded())
            }
        } else {
            // Unknown duration: ~3500 chars ≈ 15 min of speech, split evenly.
            let parts = max(1, Int((Double(total) / 3500.0).rounded(.up)))
            guard parts > 1 else { return [transcript] }
            cutAt = (1..<parts).map { total * $0 / parts }
        }

        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var segments: [String] = []
        var current: [String] = []
        var cumChars = 0
        var next = 0
        for line in lines {
            current.append(line)
            cumChars += line.count + 1
            if next < cutAt.count, cumChars >= cutAt[next] {
                segments.append(current.joined(separator: "\n"))
                current = []
                next += 1
            }
        }
        if !current.isEmpty { segments.append(current.joined(separator: "\n")) }
        return segments
    }

    /// The display sentences of a stored transcript: one trimmed, non-empty
    /// sentence each. Must match how `TranscriptView` splits the same text so the
    /// cues line up one-to-one with the rendered rows.
    ///
    /// We split on newlines *and* on sentence-ending punctuation. The chat
    /// segmenter normally returns one sentence per line, but when it fails (the
    /// raw ASR text is used as-is) or a weaker model returns a run-on paragraph, a
    /// whole ~20-minute chunk can arrive as a single line — splitting on
    /// terminators too keeps the transcript from showing a wall of run-together
    /// sentences. It is idempotent on already-one-per-line text, so cue alignment
    /// stays 1:1.
    static func displaySentences(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .flatMap(splitSentences)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Break one line into sentences at sentence-ending punctuation. Full-width
    /// CJK enders (。！？) always end a sentence; half-width (. ! ?) only when
    /// followed by whitespace or the line end, so decimals (3.14), ellipses
    /// (wait...) and the like stay intact. A run of enders plus any trailing
    /// closing marks (」』”）) is kept with the sentence it closes.
    private static func splitSentences(_ line: String) -> [String] {
        let chars = Array(line)
        let cjkEnders: Set<Character> = ["。", "！", "？"]
        let asciiEnders: Set<Character> = [".", "!", "?"]
        let closers: Set<Character> = ["」", "』", "”", "’", "）", ")", "\"", "'"]
        var result: [String] = []
        var start = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let isEnder: Bool
            if cjkEnders.contains(c) {
                isEnder = true
            } else if asciiEnders.contains(c) {
                // End-of-line counts: the default " " makes the final char split.
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                isEnder = next == " " || next == "\t"
            } else {
                isEnder = false
            }
            if isEnder {
                var j = i + 1
                while j < chars.count,
                      cjkEnders.contains(chars[j]) || asciiEnders.contains(chars[j]) || closers.contains(chars[j]) {
                    j += 1
                }
                result.append(String(chars[start..<j]))
                start = j
                i = j
            } else {
                i += 1
            }
        }
        if start < chars.count { result.append(String(chars[start...])) }
        return result.isEmpty ? [line] : result
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
    /// (range omitted when the duration is unknown). The range comes from
    /// `handoutPartBoundaries`, the same cut points `handoutSegments` splits on.
    static func partTitle(index: Int, total: Int, duration: Int?) -> String {
        let label = "Part \(romanNumeral(index + 1))"
        guard let duration, duration > 0 else { return label }
        let bounds = handoutPartBoundaries(duration: duration)
        guard index + 1 < bounds.count else { return label }
        return "\(label)（\(timeStamp(bounds[index]))–\(timeStamp(bounds[index + 1]))）"
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
