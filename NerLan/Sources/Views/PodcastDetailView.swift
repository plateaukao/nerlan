import SwiftUI

/// A subscribed podcast: show info plus its episodes. Episodes are already
/// `EpisodeRecord`s, so the row reuses `RecordRow` (with inline favorite +
/// download turned on) and everything downstream — playback, offline download,
/// favoriting, AI transcript/handout — is the existing code path.
struct PodcastDetailView: View {
    let feed: PodcastFeed

    @EnvironmentObject var podcasts: PodcastStore
    @State private var showFullIntro = false

    /// Prefer the freshest stored copy (pull-to-refresh updates the store);
    /// fall back to the passed feed if it was just unsubscribed.
    private var current: PodcastFeed { podcasts.feed(id: feed.id) ?? feed }

    var body: some View {
        List {
            Section {
                header
                    .listRowSeparator(.hidden)
            }
            Section {
                ForEach(current.episodes) { record in
                    RecordRow(record: record,
                              queue: current.episodes,
                              showFavorite: true,
                              showDownload: true,
                              subtitleOverride: subtitle(for: record),
                              showAI: false)
                }
            } header: {
                Text("單集列表（共 \(current.episodes.count) 集）")
            }
        }
        .listStyle(.plain)
        .refreshable { try? await podcasts.refresh(feed.id) }
        // The header already shows the title next to the cover, so don't repeat it
        // as the nav-bar title.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // No favorite/subscribe heart here: a podcast is added from the "+" and
        // removed by swiping its row in the 我的 Podcast list. A heart would read as
        // a Favorites-tab favorite, which podcast subscriptions are not.
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                CoverImage(urlString: current.coverURL, size: 88)
                VStack(alignment: .leading, spacing: 4) {
                    Text(current.title)
                        .font(.headline)
                        // Show the whole title (wrap to as many lines as needed)
                        // instead of truncating it to one line in the list row.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let author = current.author, !author.isEmpty {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("共 \(current.episodes.count) 集")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            let intro = current.descriptionText
            if !intro.isEmpty {
                Text(intro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(showFullIntro ? nil : 3)
                    .onTapGesture { showFullIntro.toggle() }
            }
        }
        .padding(.vertical, 4)
    }

    /// Date · duration; falls back to the language label if neither is known.
    private func subtitle(for record: EpisodeRecord) -> String {
        let parts = [record.releaseDateText, record.durationText].filter { !$0.isEmpty }
        return parts.isEmpty ? record.language : parts.joined(separator: " · ")
    }
}
