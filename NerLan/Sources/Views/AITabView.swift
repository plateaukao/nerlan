import SwiftUI

/// Every episode that has a generated transcript or AI handout, grouped by
/// program or language. Rows reuse `RecordRow` in "AI ready-only" mode, so each
/// row plays the episode and opens its existing transcript/handout (no API key
/// required just to read what's already there).
struct AITabView: View {
    @EnvironmentObject var ai: AIContentStore
    /// AppStorage (not @State) so the Mac sidebar header's toggle — which owns
    /// this control's spot up there — drives the same value.
    @AppStorage("aiGrouping") private var grouping: RecordGrouping = .program

    private var grouped: [(key: String, records: [EpisodeRecord])] {
        groupRecords(ai.aiRecords, by: grouping)
    }

    var body: some View {
        NavigationStack {
            Group {
                if ai.aiRecords.isEmpty {
                    VStack(spacing: 0) {
                        // On Mac the sidebar's segmented header replaces the title.
                        #if !targetEnvironment(macCatalyst)
                        TopTitle(text: "AI")
                        #endif
                        ContentUnavailableView("沒有 AI 內容",
                                               systemImage: "wand.and.stars",
                                               description: Text("在播放器或單集列表點選逐字稿或 AI 講義圖示來產生內容，就會出現在這裡。"))
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    List {
                        #if !targetEnvironment(macCatalyst)
                        ScrollAwayTitle(text: "AI")
                        #endif
                        ForEach(grouped, id: \.key) { group in
                            Section(group.key) {
                                ForEach(group.records) { record in
                                    RecordRow(record: record, queue: group.records, aiReadyOnly: true)
                                }
                            }
                        }
                    }
                    .contentMargins(.top, tabListTopMargin, for: .scrollContent)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // Pin the grouping switch in the top-trailing corner, aligned with
            // the title — only when there's something to group. (On Mac it
            // lives in the sidebar header instead.)
            #if !targetEnvironment(macCatalyst)
            .overlay(alignment: .topTrailing) {
                if !ai.aiRecords.isEmpty {
                    GroupingToggle(selection: $grouping)
                        .padding(.trailing, 12)
                        .padding(.top, 8)
                }
            }
            #endif
        }
    }
}
