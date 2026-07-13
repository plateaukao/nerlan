import SwiftUI

/// A large page title rendered as the first row of a List's content, so it sits
/// flush at the very top and scrolls away with the content — replacing the
/// system navigation large title (which collapses into a pinned inline title).
///
/// No `scrollTransition` fade: the first row is pinned at the scroll's top edge,
/// so a scroll transition would treat it as permanently "in transition" and fade
/// it to zero even at rest. On iOS 26 the List's built-in top scroll-edge effect
/// already softens the title as it scrolls up under the status bar.
///
/// Pair with `.toolbar(.hidden, for: .navigationBar)` on the list so no inline
/// title / header bar is left behind.
/// Top scroll margin for the tab lists' content. Zero on iOS so the
/// scroll-away titles sit flush at the very top; on Mac the titles are removed
/// (the sidebar's segmented header replaces them) and this keeps the first
/// card from hugging the header.
#if targetEnvironment(macCatalyst)
let tabListTopMargin: CGFloat = 12
#else
let tabListTopMargin: CGFloat = 0
#endif

struct ScrollAwayTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.largeTitle.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
    }
}

/// Static large title pinned at the top of an empty state (nothing to scroll),
/// so empty tabs still show their title flush at the top like the populated list.
struct TopTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.largeTitle.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}
