import SwiftUI
import WidgetKit

/// NerLan's Home Screen / Lock Screen widgets, modelled on the Apple Podcasts
/// set: Up Next (繼續收聽), Latest Episode (最新單集), Top Shows (我的節目) — plus
/// two that fit a language course rather than a podcast feed: 最近播放, which
/// resumes a whole course as a playlist, and a listening-streak widget.
///
/// Everything drawn here comes from the `WidgetSnapshot` the app publishes into
/// the shared App Group container; this process never touches the network.
@main
struct NerLanWidgetsBundle: WidgetBundle {
    var body: some Widget {
        UpNextWidget()
        RecentWidget()
        LatestEpisodeWidget()
        ShowsWidget()
        StatsWidget()
    }
}
