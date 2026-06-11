import SwiftUI

/// Browse language-learning programs, filterable by language.
/// The full Channel+ catalog (~96 programs) loads in one request and is
/// grouped by language client-side, so the chips filter instantly.
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
            let programs = try await ChannelPlusAPI.programs()
            var order: [String] = []
            var byLanguage: [String: [Program]] = [:]
            for program in programs {
                let lang = program.language
                if byLanguage[lang] == nil { order.append(lang) }
                byLanguage[lang, default: []].append(program)
            }
            groups = order.map { LanguageGroup(language: $0, programs: byLanguage[$0]!) }
        } catch {
            groups = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
