import SwiftUI

/// Browse language-learning programs, filterable by language.
/// The full Channel+ catalog (~96 programs) loads in one request and is
/// grouped by language client-side, so the chips filter instantly.
struct ProgramListView: View {
    @EnvironmentObject var podcasts: PodcastStore
    @State private var groups: [LanguageGroup] = []
    @State private var selectedLanguage: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var showAddPodcast = false

    private var languages: [String] {
        groups.map(\.language)
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
                        TopTitle(text: "語言學習")
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
            // safe area instead.
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
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showAddPodcast) { AddPodcastView() }
        }
    }

    private var list: some View {
        List {
            ScrollAwayTitle(text: "語言學習")
            Section {
                FlowLayout(spacing: 8) {
                    languageChip(nil, label: "全部")
                    ForEach(languages, id: \.self) { lang in
                        languageChip(lang, label: lang)
                    }
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
        .contentMargins(.top, 0, for: .scrollContent)
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

    private func languageChip(_ lang: String?, label: String) -> some View {
        let isSelected = selectedLanguage == lang
        return Button {
            selectedLanguage = lang
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
        } catch {
            // Keep any cached catalog already on screen; only surface the error
            // when we have nothing to show.
            if groups.isEmpty { errorMessage = error.localizedDescription }
        }
        isLoading = false
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

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = layoutRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layoutRows(maxWidth: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
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

    private func layoutRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
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
