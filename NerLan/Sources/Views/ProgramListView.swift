import SwiftUI

/// Browse language-learning programs, filterable by language.
/// The full catalog (~68 programs) loads in one request; the language
/// chips come from the loaded data, so filtering is instant and every
/// chip is guaranteed to have programs.
struct ProgramListView: View {
    @State private var groups: [LanguageGroup] = []
    @State private var selectedLanguage: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

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
                    ContentUnavailableView("載入失敗", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                } else {
                    list
                }
            }
            .navigationTitle("語言學習")
            .task { if groups.isEmpty { await reload() } }
            .refreshable { await reload() }
        }
    }

    private var list: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        languageChip(nil, label: "全部")
                        ForEach(languages, id: \.self) { lang in
                            languageChip(lang, label: lang)
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
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: Program.self) { program in
            ProgramDetailView(program: program)
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

    private func reload() async {
        isLoading = true
        errorMessage = nil
        do {
            // The API can return the same language in multiple groups; merge them.
            var merged: [LanguageGroup] = []
            for group in try await NERAPI.programList() {
                if let i = merged.firstIndex(where: { $0.language == group.language }) {
                    let known = Set(merged[i].programs.map(\.id))
                    let added = group.programs.filter { !known.contains($0.id) }
                    merged[i] = LanguageGroup(language: group.language, programs: merged[i].programs + added)
                } else {
                    merged.append(group)
                }
            }
            groups = merged
        } catch {
            groups = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
