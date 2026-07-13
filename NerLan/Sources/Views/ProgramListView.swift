import SwiftUI

/// Browse language-learning programs, filterable by language.
/// The full Channel+ catalog (~96 programs) loads in one request and is
/// grouped by language client-side, so the chips filter instantly.
struct ProgramListView: View {
    @EnvironmentObject var podcasts: PodcastStore
    @State private var groups: [LanguageGroup] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var showAddPodcast = false
    @State private var chipsExpanded = false
    /// Last chosen language filter, restored across launches ("" = 全部).
    @AppStorage("programLanguageFilter") private var storedLanguageFilter = ""

    private var selectedLanguage: String? {
        storedLanguageFilter.isEmpty ? nil : storedLanguageFilter
    }

    /// Chips lead with the most-studied languages so they stay on the visible
    /// first row when the chip section is folded; the rest keep catalog order.
    private static let priorityLanguages = ["英語", "日語", "韓語", "法語"]

    private var languages: [String] {
        let all = groups.map(\.language)
        let priority = Self.priorityLanguages.filter { all.contains($0) }
        return priority + all.filter { !Self.priorityLanguages.contains($0) }
    }

    private var visibleGroups: [LanguageGroup] {
        guard let selectedLanguage else { return groups }
        return groups.filter { $0.language == selectedLanguage }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let errorMessage {
                    VStack(spacing: 0) {
                        // On Mac the sidebar's segmented header replaces the title.
                        #if !targetEnvironment(macCatalyst)
                        TopTitle(text: "語言學習")
                        #endif
                        ContentUnavailableView("載入失敗", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    list
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await loadInitial() }
            .refreshable { await reload() }
            // The nav bar is hidden so the title can live in the scroll content;
            // float the add-podcast and settings buttons in the top-trailing
            // safe area instead. (On Mac both live elsewhere: + in the sidebar
            // header, Settings in the app menu.)
            #if !targetEnvironment(macCatalyst)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 2) {
                    Button { showAddPodcast = true } label: {
                        Image(systemName: "plus")
                            .font(.title3)
                            .padding(10)
                            .contentShape(Rectangle())
                    }
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                            .font(.title3)
                            .padding(10)
                            .contentShape(Rectangle())
                    }
                }
                .padding(.trailing, 6)
                .padding(.top, 6)
            }
            #endif
            .sheet(isPresented: $showSettings) { SettingsView().appEnvironment() }
            .sheet(isPresented: $showAddPodcast) { AddPodcastView().appEnvironment() }
            .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
                showSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .addPodcast)) { _ in
                showAddPodcast = true
            }
        }
    }

    private var list: some View {
        List {
            #if !targetEnvironment(macCatalyst)
            ScrollAwayTitle(text: "語言學習")
            #endif
            Section {
                // Collapsed: one scrollable line of chips. Expanded: full wrap
                // layout. (Don't hide overflow chips by parking them offscreen
                // inside the Layout — List cells grow to enclose them.)
                HStack(alignment: .top, spacing: 4) {
                    if chipsExpanded {
                        FlowLayout(spacing: 8) {
                            chipContent
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                chipContent
                            }
                        }
                    }
                    Button {
                        chipsExpanded.toggle()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(chipsExpanded ? 180 : 0))
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
            }

            // Subscribed podcasts pinned above the NER catalog, shown only in the
            // unfiltered ("全部") view so a language filter stays clean.
            if selectedLanguage == nil, !podcasts.feeds.isEmpty {
                Section("我的 Podcast") {
                    ForEach(podcasts.feeds) { feed in
                        NavigationLink(value: feed) {
                            PodcastRow(feed: feed)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                podcasts.unsubscribe(id: feed.id)
                            } label: {
                                Label("取消訂閱", systemImage: "minus.circle")
                            }
                        }
                    }
                }
            }

            ForEach(visibleGroups) { group in
                Section(group.language) {
                    ForEach(group.programs) { program in
                        NavigationLink(value: program) {
                            ProgramRow(program: program)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // Remove the grouped list's default top inset so the title sits right
        // under the status bar instead of floating below it.
        .contentMargins(.top, tabListTopMargin, for: .scrollContent)
        .navigationDestination(for: Program.self) { program in
            ProgramDetailView(program: program)
        }
        .navigationDestination(for: PodcastFeed.self) { feed in
            PodcastDetailView(feed: feed)
        }
        .overlay {
            if isLoading && groups.isEmpty { ProgressView() }
        }
    }

    @ViewBuilder
    private var chipContent: some View {
        ForEach(languages, id: \.self) { lang in
            languageChip(lang, label: lang)
        }
        languageChip(nil, label: "全部")
    }

    private func languageChip(_ lang: String?, label: String) -> some View {
        let isSelected = selectedLanguage == lang
        return Button {
            storedLanguageFilter = lang ?? ""
        } label: {
            Text(label)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(.systemGray5))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// On first appearance, render the cached catalog if we have one (no network);
    /// only fetch when there's nothing cached. Pull-to-refresh uses `reload()`.
    private func loadInitial() async {
        guard groups.isEmpty else { return }
        if let cached = CatalogCache.loadPrograms(), !cached.isEmpty {
            groups = group(cached)
            validateFilter()
            return
        }
        await reload()
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        do {
            let programs = try await ChannelPlusAPI.programs()
            groups = group(programs)
            CatalogCache.savePrograms(programs)
            validateFilter()
        } catch {
            // Keep any cached catalog already on screen; only surface the error
            // when we have nothing to show.
            if groups.isEmpty { errorMessage = error.localizedDescription }
        }
        isLoading = false
    }

    /// Drop a restored filter that no longer matches any catalog language,
    /// which would otherwise leave the list permanently empty.
    private func validateFilter() {
        guard !groups.isEmpty, let selectedLanguage, !languages.contains(selectedLanguage) else { return }
        storedLanguageFilter = ""
    }

    private func group(_ programs: [Program]) -> [LanguageGroup] {
        var order: [String] = []
        var byLanguage: [String: [Program]] = [:]
        for program in programs {
            let lang = program.language
            if byLanguage[lang] == nil { order.append(lang) }
            byLanguage[lang, default: []].append(program)
        }
        return order.map { LanguageGroup(language: $0, programs: byLanguage[$0]!) }
    }
}

/// Wraps subviews into as many rows as needed, like tags in a tag cloud.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    /// Subview sizes measured once per layout pass. Without the cache each pass
    /// measured every chip twice (sizeThatFits + placeSubviews) and then once
    /// more per placement.
    struct Cache {
        var sizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        // Inside an HStack the layout gets zero/infinity flexibility probes
        // (a bare List row only ever proposes a finite width); answer them
        // with the widest row instead of echoing a non-finite width back.
        let maxWidth = proposal.width ?? .infinity
        let rows = layoutRows(maxWidth: maxWidth, sizes: cache.sizes)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let widestRow = rows.map(\.width).max() ?? 0
        let width = maxWidth.isFinite ? maxWidth : widestRow
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let rows = layoutRows(maxWidth: bounds.width, sizes: cache.sizes)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = cache.sizes[index]
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layoutRows(maxWidth: CGFloat, sizes: [CGSize]) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        for (i, size) in sizes.enumerated() {
            if x > 0, x + size.width > maxWidth {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
                x = 0
            }
            current.indices.append(i)
            x += size.width + spacing
            current.width = x - spacing
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

struct ProgramRow: View {
    let program: Program

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(urlString: program.coverURL?.absoluteString, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(program.name)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let level = program.level {
                        Text(level)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    if let count = program.episodeCount {
                        Text("共 \(count) 集")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Row for a subscribed podcast in the "我的 Podcast" section (mirrors ProgramRow).
struct PodcastRow: View {
    let feed: PodcastFeed

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(urlString: feed.coverURL, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(feed.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let author = feed.author, !author.isEmpty {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text("共 \(feed.episodes.count) 集")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
