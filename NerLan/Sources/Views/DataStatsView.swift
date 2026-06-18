import SwiftUI

/// 資料統計 — an inventory of what the app has stored on this device: favorites,
/// downloads, streamed cache, AI content, and the language breakdown of downloads.
/// Everything is read live from the existing stores, so it works retroactively.
struct DataStatsView: View {
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var favorites: FavoritesStore
    @EnvironmentObject var ai: AIContentStore

    // Filesystem-derived values are loaded once in onAppear rather than on every
    // render (they walk the Documents/Caches directories).
    @State private var downloadBytes: Int64 = 0
    @State private var cacheBytes: Int64 = 0
    @State private var attachmentCount = 0
    @State private var cachedCount = 0
    @State private var transcriptCount = 0
    @State private var handoutCount = 0
    @State private var translationCount = 0

    var body: some View {
        Form {
            Section("收藏") {
                LabeledContent("收藏單集", value: "\(favorites.favorites.count)")
                LabeledContent("收藏節目", value: "\(favorites.programs.count)")
            }

            Section("下載") {
                LabeledContent("已下載單集", value: "\(downloads.records.count)")
                LabeledContent("佔用空間", value: Self.byteText(downloadBytes))
                LabeledContent("講義附件", value: "\(attachmentCount)")
            }

            Section("串流快取") {
                LabeledContent("快取單集", value: "\(cachedCount)")
                LabeledContent("快取大小", value: Self.byteText(cacheBytes))
            }

            Section("AI 內容") {
                LabeledContent("逐字稿", value: "\(transcriptCount)")
                LabeledContent("AI 講義", value: "\(handoutCount)")
                LabeledContent("翻譯", value: "\(translationCount)")
            }

            if !languageRows.isEmpty {
                Section("語言分布（已下載）") {
                    ForEach(languageRows, id: \.language) { row in
                        LabeledContent(row.language, value: "\(row.count)")
                    }
                }
            }
        }
        .navigationTitle("資料統計")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private var languageRows: [(language: String, count: Int)] {
        Dictionary(grouping: downloads.records, by: \.language)
            .map { (language: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    private func load() {
        downloadBytes = downloads.downloadedAudioByteSize()
        cacheBytes = downloads.cachedAudioByteSize()
        attachmentCount = downloads.attachmentCount()
        cachedCount = downloads.cachedEpisodeCount()
        transcriptCount = ai.transcriptCount
        handoutCount = ai.handoutCount
        translationCount = ai.translationCount
    }

    static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
