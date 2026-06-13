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

    private let transcriptsDir: URL
    private let handoutsDir: URL
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
        indexURL = aiDir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: handoutsDir, withIntermediateDirectories: true)

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
        if changed { persistIndex() }
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

    func hasTranscript(_ id: String) -> Bool { FileManager.default.fileExists(atPath: transcriptURL(id).path) }
    func hasHandout(_ id: String) -> Bool { FileManager.default.fileExists(atPath: handoutURL(id).path) }

    func transcriptText(_ id: String) -> String? { try? String(contentsOf: transcriptURL(id), encoding: .utf8) }
    func handoutHTML(_ id: String) -> String? { try? String(contentsOf: handoutURL(id), encoding: .utf8) }

    func jobState(_ kind: Kind, _ id: String) -> JobState? { jobs[key(kind, id)] }

    // MARK: - Triggers

    func processTranscript(_ record: EpisodeRecord) {
        guard jobs[key(.transcript, record.id)] == nil, !hasTranscript(record.id) else { return }
        Task { await runTranscript(record) }
    }

    func processHandout(_ record: EpisodeRecord) {
        guard jobs[key(.handout, record.id)] == nil, !hasHandout(record.id) else { return }
        Task { await runHandout(record) }
    }

    func clearAll() {
        let ids = Array(records.keys)
        for dir in [transcriptsDir, handoutsDir] {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for item in items { try? FileManager.default.removeItem(at: item) }
        }
        if syncOn { ICloudSync.shared.removeAllUp() }
        if syncingRecords { for id in ids { CloudKVStore.shared.remove(Self.kvsPrefix + id) } }
        records.removeAll()
        persistIndex()
        jobs.removeAll()
    }

    /// Delete one episode's saved content of `kind`. `objectWillChange` fires so
    /// the action button drops back to its idle state.
    func delete(_ kind: Kind, _ id: String) {
        objectWillChange.send()
        let url = kind == .transcript ? transcriptURL(id) : handoutURL(id)
        try? FileManager.default.removeItem(at: url)
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
            // cap input at 1400 s); transcribe each and join.
            let chunks = await SpeechAudioExporter.exportChunks(source)
            defer { cleanupChunks(chunks, original: source) }
            let prompt = OpenAIService.transcriptionPrompt(for: record.language)
            var parts: [String] = []
            for (i, chunk) in chunks.enumerated() {
                if chunks.count > 1 { jobs[k] = .running("轉錄中…（\(i + 1)/\(chunks.count)）") }
                parts.append(try await OpenAIService.transcribe(
                    fileURL: chunk, model: settings.transcriptionModel, apiKey: settings.apiKey,
                    prompt: prompt))
            }
            let raw = parts.joined(separator: "\n")

            // Re-segment into one sentence per line with the chat model (adds
            // sentence-ending punctuation only, never alters content). If that
            // step fails, keep the raw transcript so the paid transcription isn't lost.
            jobs[k] = .running("整理句子中…")
            let text = (try? await OpenAIService.segmentTranscript(
                raw, model: settings.chatModel, apiKey: settings.apiKey)) ?? raw

            try text.data(using: .utf8)?.write(to: transcriptURL(record.id))
            noteRecord(record)
            if syncOn { ICloudSync.shared.mirrorUp(.transcript, id: record.id, displayName: Self.displayName(record)) }
            jobs.removeValue(forKey: k)   // publishes → hasTranscript-driven UI refreshes
            return text
        } catch {
            jobs[k] = .failed(error.localizedDescription)
            return nil
        }
    }

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
            jobs[k] = .running("生成講義中…")
            let fragment = try await OpenAIService.generateHandout(
                transcript: transcript, record: record,
                model: settings.chatModel, apiKey: settings.apiKey)
            let html = Self.wrapHTML(fragment, title: record.title)
            try html.data(using: .utf8)?.write(to: handoutURL(record.id))
            noteRecord(record)
            if syncOn { ICloudSync.shared.mirrorUp(.handout, id: record.id, displayName: Self.displayName(record)) }
            jobs.removeValue(forKey: k)
        } catch {
            jobs[k] = .failed(error.localizedDescription)
        }
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
