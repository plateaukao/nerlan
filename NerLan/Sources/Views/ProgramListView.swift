import SwiftUI

/// Browse language-learning programs, filterable by language.
struct ProgramListView: View {
    @State private var categories: [LanguageCategory] = []
    @State private var groups: [LanguageGroup] = []
    @State private var selectedLanguage: LanguageCategory?
    @State private var page = 1
    @State private var totalPage = 1
    @State private var isLoading = false
    @State private var errorMessage: String?

    /// The API's languageId filter is unreliable, so filter client-side too.
    private var visibleGroups: [LanguageGroup] {
        guard let selected = selectedLanguage else { return groups }
        return groups.filter { $0.language == selected.name }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let errorMessage {
                    ContentUnavailableView("載入失敗", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                } else {
                    list
                }
            }
            .navigationTitle("語言學習")
            .task { await initialLoad() }
            .refreshable { await reload() }
        }
    }

    private var list: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        languageChip(nil, label: "全部")
                        ForEach(categories) { cat in
                            languageChip(cat, label: cat.name)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
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

            if page < totalPage && selectedLanguage == nil {
                Section {
                    HStack {
                        Spacer()
                        if isLoading { ProgressView() } else {
                            Button("載入更多") { Task { await loadMore() } }
                        }
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: Program.self) { program in
            ProgramDetailView(program: program)
        }
        .overlay {
            if isLoading && groups.isEmpty { ProgressView() }
        }
    }

    private func languageChip(_ cat: LanguageCategory?, label: String) -> some View {
        let isSelected = selectedLanguage == cat
        return Button {
            selectedLanguage = cat
            Task { await reload() }
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

    private func initialLoad() async {
        guard groups.isEmpty else { return }
        await reload()
        categories = (try? await NERAPI.languageCategories()) ?? []
    }

    private func reload() async {
        page = 1
        await fetch(reset: true)
    }

    private func loadMore() async {
        page += 1
        await fetch(reset: false)
    }

    private func fetch(reset: Bool) async {
        isLoading = true
        errorMessage = nil
        do {
            // When filtering, fetch all pages so client-side filter sees everything.
            let pageSize = selectedLanguage == nil ? 10 : 100
            let result = try await NERAPI.programList(languageId: selectedLanguage?.id ?? "",
                                                      page: page, pageSize: pageSize)
            totalPage = result.totalPage
            let merged = reset ? result.groups : mergeGroups(groups, result.groups)
            groups = merged
        } catch {
            if reset { groups = [] }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Later pages can repeat a language section; merge programs into existing groups.
    private func mergeGroups(_ existing: [LanguageGroup], _ new: [LanguageGroup]) -> [LanguageGroup] {
        var result = existing
        for group in new {
            if let i = result.firstIndex(where: { $0.language == group.language }) {
                let known = Set(result[i].programs.map(\.id))
                let added = group.programs.filter { !known.contains($0.id) }
                result[i] = LanguageGroup(language: group.language, programs: result[i].programs + added)
            } else {
                result.append(group)
            }
        }
        return result
    }
}

struct ProgramRow: View {
    let program: Program

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(urlString: program.cover, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(program.name)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    if let level = program.level {
                        Text(level)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Text(program.scheduleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let hosts = program.hosts, !hosts.isEmpty {
                    Text(hosts.map(\.name).joined(separator: "、"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
