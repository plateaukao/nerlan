import Foundation

/// Stateless client for the OpenAI REST API: transcribe an episode's audio and
/// turn that transcript into a study handout. Holds no state, mirroring
/// `ChannelPlusAPI`; credentials and model names are passed in by the caller.
enum OpenAIService {
    static let base = URL(string: "https://api.openai.com/v1")!

    /// Transcribing a ~30-min episode (and generating a handout from a long
    /// transcript) can take minutes server-side; the default 60s request
    /// timeout is far too short, so use a session with generous timeouts.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300   // up to 5 min between bytes
        config.timeoutIntervalForResource = 1800 // 30 min overall ceiling
        return URLSession(configuration: config)
    }()

    enum APIError: LocalizedError {
        case missingKey
        case server(String)
        case decode

        var errorDescription: String? {
            switch self {
            case .missingKey: return "尚未設定 OpenAI API 金鑰"
            case .server(let m): return m
            case .decode: return "無法解析 OpenAI 回應"
            }
        }
    }

    // MARK: - Transcription

    /// One timed unit of ASR output: the segment's text and the audio time (in
    /// seconds, relative to the file transcribed) at which it begins.
    struct Segment: Equatable {
        let start: Double
        let text: String
    }

    /// Result of a transcription: the full text plus, when the model supports it,
    /// the per-segment timestamps. `segments` is empty for models that return no
    /// timing (see `supportsSegments`), in which case only `text` is meaningful.
    struct TranscriptionResult {
        let text: String
        let segments: [Segment]
    }

    /// Whether a transcription model returns segment timestamps. Only `whisper-1`
    /// supports `response_format=verbose_json`; the `gpt-4o-transcribe` models
    /// accept `json`/`text` only and would reject `verbose_json`.
    static func supportsSegments(model: String) -> Bool {
        model.lowercased().contains("whisper")
    }

    /// Transcribe an audio file via `POST /audio/transcriptions` (multipart).
    /// Whisper models are asked for `verbose_json` so the per-segment timestamps
    /// come back (used to highlight the playing sentence); other models, which
    /// don't support it, get `response_format=text` and yield no segments.
    ///
    /// `prompt` biases Whisper's output script/vocabulary. These are bilingual
    /// teaching programs (Mandarin host + foreign examples); without a prompt
    /// Whisper locks onto the dominant language (Chinese) and collapses the
    /// foreign speech into Chinese characters. Priming it with Traditional Chinese
    /// plus a native-script sample of the target language keeps both intact —
    /// build one with `transcriptionPrompt(for:)`.
    /// `language` (ISO-639-1, e.g. "ko") tells the model the spoken language; set
    /// for monolingual sources (podcasts) so it transcribes in that language
    /// instead of collapsing toward the prompt's. Left nil for bilingual NER
    /// content, which relies on the prompt and per-passage detection instead.
    static func transcribe(fileURL: URL, model: String, apiKey: String,
                           prompt: String? = nil, language: String? = nil) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw APIError.missingKey }
        let wantSegments = supportsSegments(model: model)

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: base.appendingPathComponent("audio/transcriptions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: fileURL)
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        field("response_format", wantSegments ? "verbose_json" : "text")
        if let language, !language.isEmpty { field("language", language) }
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
            .data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let (data, response) = try await session.upload(for: req, from: body)
        try check(response, data)

        guard wantSegments else {
            guard let text = String(data: data, encoding: .utf8) else { throw APIError.decode }
            return TranscriptionResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines), segments: [])
        }
        // verbose_json: { "text": "...", "segments": [ { "start": 0.0, "text": "..." }, ... ] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decode
        }
        let segments: [Segment] = (json["segments"] as? [[String: Any]])?.compactMap { seg in
            guard let start = seg["start"] as? Double, let text = seg["text"] as? String else { return nil }
            return Segment(start: start, text: text)
        } ?? []
        let full = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = full.isEmpty ? segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) : full
        guard !text.isEmpty else { throw APIError.decode }
        return TranscriptionResult(text: text, segments: segments)
    }

    /// A Whisper `prompt` for a program's target `language` (the Chinese name from
    /// `EpisodeRecord.language`, e.g. 日語/英語/韓語). Whisper treats the prompt as
    /// preceding context, not an instruction, so we prime it with actual mixed
    /// text: a Traditional-Chinese teaching sentence plus a short native-script
    /// sample of the language, which nudges the decoder to keep 正體中文 for the
    /// host and the original script for the foreign words.
    static func transcriptionPrompt(for language: String) -> String {
        let base = "這是一段以臺灣繁體中文（正體字）講解的語言教學廣播節目，主持人會穿插示範外語。"
        let sample: String
        if language.contains("日") {
            sample = "日語例句：おはようございます。ありがとうございます。よろしくお願いします。"
        } else if language.contains("英") {
            sample = "English examples: Good morning. How are you today? Thank you very much."
        } else if language.contains("韓") {
            sample = "韓語例句：안녕하세요. 감사합니다. 맛있어요."
        } else if language.contains("法") {
            sample = "Exemples en français : Bonjour. Comment allez-vous ? Merci beaucoup."
        } else if language.contains("德") {
            sample = "Beispiele auf Deutsch: Guten Morgen. Wie geht es Ihnen? Danke schön."
        } else if language.contains("西") {
            sample = "Ejemplos en español: Buenos días. ¿Cómo está usted? Muchas gracias."
        } else if language.contains("越") {
            sample = "Ví dụ tiếng Việt: Xin chào. Bạn có khỏe không? Cảm ơn rất nhiều."
        } else if language.contains("印尼") {
            sample = "Contoh bahasa Indonesia: Selamat pagi. Apa kabar? Terima kasih banyak."
        } else if language.contains("泰") {
            sample = "ตัวอย่างภาษาไทย: สวัสดีครับ สบายดีไหม ขอบคุณมากครับ"
        } else {
            return base + "節目中會穿插「\(language)」教學，請保留該語言文字的原始樣貌。"
        }
        return base + sample
    }

    // MARK: - Handout (chat completion)

    /// Produce an HTML study-handout *fragment* from a transcript via
    /// `POST /chat/completions`. The caller wraps it in a styled HTML document.
    ///
    /// `partTitle` is set when an episode is split into ~15-minute parts: the
    /// fragment is prefixed with a "Part …" heading and its four section headings
    /// drop to `h3` (nested under the part), so the document reads Part I →
    /// 內容說明/文法重點/例句/單字, Part II → …. When nil (≤15 min) the four
    /// sections are top-level `h2`.
    static func generateHandout(transcript: String, record: EpisodeRecord,
                                partTitle: String? = nil,
                                model: String, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else { throw APIError.missingKey }

        let tag = partTitle == nil ? "h2" : "h3"
        let partNote = partTitle == nil ? ""
            : "你收到的是整集節目其中一段（約 15 分鐘）的逐字稿，請只根據這一段的內容製作講義。"
        let system = """
        你是一位專業的語言老師，正在為「\(record.language)」語言學習教材製作複習講義。\
        \(partNote)\
        你會收到一段廣播節目的逐字稿，請根據內容整理出一份適合學生複習的講義。\
        說明文字一律使用「台灣繁體中文（正體字）」，絕對不要使用簡體字；例句與單字中的外語請保留原貌（不要翻譯或改成中文字）。\
        並使用 HTML 格式輸出，依序分成四個區塊：\
        <\(tag)>內容說明</\(tag)>（用幾句話說明這段內容的主題與大意）、\
        <\(tag)>文法重點</\(tag)>（列出出現的文法句型，附簡短解說）、\
        <\(tag)>例句</\(tag)>（從內容中挑選實用例句，逐句附上中文翻譯）、\
        <\(tag)>單字</\(tag)>（重要單字表，含發音或拼音與中文意思，建議用表格呈現）。\
        只輸出 HTML 內容片段（可使用 h2、h3、h4、p、ul、ol、li、table、tr、th、td、strong、em、ruby 等標籤），\
        不要輸出 <html>、<head>、<body> 標籤，也不要使用 Markdown 或程式碼圍欄。
        """
        let user = "節目：\(record.programName)\n單集：\(record.title)\n\n逐字稿：\n\(transcript)"
        let fragment = stripCodeFence(try await chat(system: system, user: user, model: model, apiKey: apiKey))
        guard let partTitle else { return fragment }
        return "<h2>\(partTitle)</h2>\n\(fragment)"
    }

    // MARK: - Sentence segmentation

    /// Re-segment a raw ASR transcript into one sentence per line using the chat
    /// model, without altering the wording — speech recognition (especially for
    /// CJK) often returns text with little punctuation. Long transcripts are
    /// chunked so no single response gets truncated. Returns sentences joined by
    /// newlines.
    static func segmentTranscript(_ raw: String, model: String, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else { throw APIError.missingKey }
        let system = """
        你是一個只負責加上標點與斷句的文字編輯器。你會收到一段語音辨識（ASR）產生的逐字稿，通常缺少標點。\
        規則：\
        1. 加入適當且必要的標點符號（句號、問號、驚嘆號、逗號等；中文用全形「，。？！」，外語用半形「,.?!」），並在每句結束後換行，每句一行。\
        2. 若原文該處已有適當的標點（例如已是「？」或「！」），請保留原樣，不要再額外加上句號或重複的標點。\
        3. 絕對不可更動任何原始內容：不可翻譯、改寫、增刪、調整字詞或更改任何字元。\
        4. 【最重要】原文若含有非中文文字（韓文諺文 한글、日文假名、英文字母、其他外語等），必須一字不差地原樣保留其原始文字與字母，嚴禁將其翻譯、音譯、或轉寫成中文／漢字。例如「안녕하세요」必須維持為「안녕하세요」，絕不可變成「你好」或任何漢字；簡繁字體也一律維持原樣。\
        5. 只輸出處理後的逐字稿，每句一行，不要加編號，也不要任何其他說明文字。
        """
        var segments: [String] = []
        for piece in chunk(raw, maxChars: 4000) {
            // temperature 0: this is a mechanical punctuate-and-split task, so the
            // model must stay faithful and never drift into translating/converting
            // the foreign-language passages.
            let result = try await chat(system: system, user: piece, model: model, apiKey: apiKey, temperature: 0)
            segments.append(result.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return segments.joined(separator: "\n")
    }

    // MARK: - Translation

    /// Translate a transcript's display `sentences` into `language` via the chat
    /// model, returning one translated sentence per input sentence (same count,
    /// same order) so the transcript screen can pair each row with its
    /// translation. Sentences are sent in whole-line batches so the line count is
    /// preserved; each batch's returned line count is reconciled to its input
    /// count (pad/truncate) so a stray dropped/added line never shifts the
    /// alignment of everything after it.
    static func translateSentences(_ sentences: [String], to language: String,
                                   model: String, apiKey: String) async throws -> [String] {
        guard !apiKey.isEmpty else { throw APIError.missingKey }
        guard !sentences.isEmpty else { return [] }
        let system = """
        你是一位專業翻譯。你會收到一段逐字稿，每行一句（內容可能混合中文與外語）。\
        請將每一行都翻譯成「\(language)」。\
        規則：\
        1.【最重要】輸出的行數必須與輸入完全相同，每一行對應一句翻譯，順序一致，不可合併或拆分行。\
        2. 不要加上編號、引號、原文或任何說明文字，只輸出翻譯後的句子，每句一行。\
        3. 若某一行已經是目標語言或無法翻譯（例如僅為標點或語助詞），仍要輸出對應的一行（可原樣保留）。
        """
        var out: [String] = []
        for batch in lineBatches(sentences, maxLines: 40, maxChars: 3000) {
            // temperature 0: keep the mapping faithful and the line count stable.
            let raw = try await chat(system: system, user: batch.joined(separator: "\n"),
                                     model: model, apiKey: apiKey, temperature: 0)
            var lines = raw.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // Reconcile to the batch's line count so indices never drift.
            if lines.count > batch.count { lines = Array(lines.prefix(batch.count)) }
            while lines.count < batch.count { lines.append("") }
            out.append(contentsOf: lines)
        }
        return out
    }

    /// Group whole sentences into batches of at most `maxLines` lines or
    /// `maxChars` characters (whichever comes first), never splitting a sentence —
    /// so each batch's line count equals its sentence count.
    private static func lineBatches(_ sentences: [String], maxLines: Int, maxChars: Int) -> [[String]] {
        var batches: [[String]] = []
        var current: [String] = []
        var chars = 0
        for s in sentences {
            if !current.isEmpty && (current.count >= maxLines || chars + s.count > maxChars) {
                batches.append(current)
                current = []
                chars = 0
            }
            current.append(s)
            chars += s.count + 1
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    // MARK: - Helpers

    /// One round-trip to `POST /chat/completions`, returning the message content.
    /// `temperature` is sent only when provided (0 for faithful, mechanical tasks
    /// like sentence segmentation; omitted to keep the model's default elsewhere).
    private static func chat(system: String, user: String, model: String, apiKey: String,
                             temperature: Double? = nil) async throws -> String {
        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if let temperature { payload["temperature"] = temperature }
        var req = URLRequest(url: base.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: req)
        try check(response, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw APIError.decode }
        return content
    }

    /// Split text into <= maxChars pieces, backing up to a nearby sentence break
    /// so a chunk boundary rarely lands in the middle of a sentence.
    private static func chunk(_ text: String, maxChars: Int) -> [String] {
        let chars = Array(text)
        guard chars.count > maxChars else { return [text] }
        let breakChars: Set<Character> = ["。", "！", "？", ".", "!", "?", "\n", "、", "，", ",", " "]
        var chunks: [String] = []
        var start = 0
        while start < chars.count {
            var end = min(start + maxChars, chars.count)
            if end < chars.count {
                var b = end
                let floor = start + maxChars / 2
                while b > floor, !breakChars.contains(chars[b - 1]) { b -= 1 }
                if b > floor { end = b }
            }
            chunks.append(String(chars[start..<end]))
            start = end
        }
        return chunks
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse,
              !(200..<300).contains(http.statusCode) else { return }
        // OpenAI errors look like { "error": { "message": ... } }.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw APIError.server(message)
        }
        throw APIError.server("OpenAI 請求失敗（HTTP \(http.statusCode)）")
    }

    /// Models sometimes wrap HTML in ```html fences despite instructions.
    private static func stripCodeFence(_ s: String) -> String {
        var text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if text.hasSuffix("```") {
                text = String(text.dropLast(3))
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
