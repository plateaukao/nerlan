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

    /// Transcribe an audio file via `POST /audio/transcriptions` (multipart).
    /// `response_format=text` makes the response body the raw transcript.
    static func transcribe(fileURL: URL, model: String, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else { throw APIError.missingKey }

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
        field("response_format", "text")
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
            .data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let (data, response) = try await session.upload(for: req, from: body)
        try check(response, data)
        guard let text = String(data: data, encoding: .utf8) else { throw APIError.decode }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Handout (chat completion)

    /// Produce an HTML study-handout *fragment* from a transcript via
    /// `POST /chat/completions`. The caller wraps it in a styled HTML document.
    static func generateHandout(transcript: String, record: EpisodeRecord,
                                model: String, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else { throw APIError.missingKey }

        let system = """
        你是一位專業的語言老師，正在為「\(record.language)」語言學習教材製作複習講義。\
        你會收到一集廣播節目的逐字稿，請根據內容整理出一份適合學生複習的講義。\
        請用「繁體中文」說明，並使用 HTML 格式輸出，分成三個區塊：\
        <h2>文法重點</h2>（列出本集出現的文法句型，附簡短解說）、\
        <h2>例句</h2>（從內容中挑選實用例句，逐句附上中文翻譯）、\
        <h2>單字</h2>（重要單字表，含發音或拼音與中文意思，建議用表格呈現）。\
        只輸出 HTML 內容片段（可使用 h2、h3、p、ul、ol、li、table、tr、th、td、strong、em、ruby 等標籤），\
        不要輸出 <html>、<head>、<body> 標籤，也不要使用 Markdown 或程式碼圍欄。
        """
        let user = "節目：\(record.programName)\n單集：\(record.title)\n\n逐字稿：\n\(transcript)"
        return stripCodeFence(try await chat(system: system, user: user, model: model, apiKey: apiKey))
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
        你是一個文字編輯器。你會收到一段語音辨識（ASR）產生的逐字稿，可能缺少標點或斷句。\
        請將它重新斷句，每一句一行。規則：\
        1. 不可翻譯、改寫、摘要、增刪或更動內容，只能加入適當的標點符號並斷行。\
        2. 保留原本的語言（內容可能同時包含日文、英文等與中文）。\
        3. 只輸出斷句後的逐字稿，每句一行，不要加編號，也不要任何其他說明文字。
        """
        var segments: [String] = []
        for piece in chunk(raw, maxChars: 4000) {
            let result = try await chat(system: system, user: piece, model: model, apiKey: apiKey)
            segments.append(result.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return segments.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// One round-trip to `POST /chat/completions`, returning the message content.
    private static func chat(system: String, user: String, model: String, apiKey: String) async throws -> String {
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
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
