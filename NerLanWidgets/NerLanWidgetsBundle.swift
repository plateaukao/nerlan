import SwiftUI
import WidgetKit

/// NerLan's Home Screen / Lock Screen widgets, modelled on the Apple Podcasts
/// set: Up Next (繼續收聽), Latest Episode (最新單集), Top Shows (我的節目) — plus
/// a listening-streak widget, which is the language-learning equivalent.
///
/// Everything drawn here comes from the `WidgetSnapshot` the app publishes into
/// the shared App Group container; this process never touches the network.
@main
struct NerLanWidgetsBundle: WidgetBundle {
    var body: some Widget {
        UpNextWidget()
        LatestEpisodeWidget()
        ShowsWidget()
        StatsWidget()
    }
}
