# NerLan — Podcast & program detail header tidy

## Summary

Three UI corrections to the program and podcast detail screens, on iPhone and
iPad:

1. **Podcast subscribe heart removed.** The podcast detail header's pink heart was
   the *subscribe* toggle but looked identical to the *favorite* heart used for
   NER programs and episodes — so a subscribed show appeared "favorited" yet never
   showed in the Favorites tab (subscriptions live in Programs → 我的 Podcast).
   The heart is gone; unsubscribe is now a swipe action on the 我的 Podcast list
   rows, symmetric with adding via the "+".
2. **Full podcast title.** The title next to the cover wraps to as many lines as
   needed instead of truncating to one line.
3. **No redundant nav-bar title.** Both detail screens showed the program/show
   name twice at the top — once as the inline navigation title and again next to
   the cover in the header. The nav-bar title is dropped; the header is the single
   source of the name.

## Approach

- **Heart vs. favorite was an icon-overload, not a logic bug.** The podcast heart
  drove `PodcastStore.subscribe`/`unsubscribe`, never `FavoritesStore`. Rather than
  fold subscriptions into the Favorites tab, the heart was removed so the heart
  icon means only "favorite" everywhere. Unsubscribe moved to a `swipeActions`
  button ("取消訂閱") on the list row, mirroring how `FavoritesView` removes
  favorites by swipe.
- **Title wrapping** uses `.fixedSize(horizontal: false, vertical: true)` plus
  full-width framing so the `Text` takes its full ideal height inside the
  self-sizing `List` row instead of being clipped to one line.
- **Redundant title** removed by setting `.navigationTitle("")` while keeping
  `.navigationBarTitleDisplayMode(.inline)`, so the bar stays compact (back button
  + the NER program's favorite heart) with no duplicated text.

## Trade-offs

- **Title context on scroll.** With the nav-bar title gone, scrolling past the
  header leaves no program name in the bar. Accepted: the duplication at the top
  was the bigger annoyance, and the header carries the name.
- **In-detail unsubscribe removed.** Unsubscribe is now only in the list (swipe),
  not the detail screen. Adding is via the "+", removing via swipe — a symmetric,
  uncluttered model.

## Key Files

- `NerLan/Sources/Views/PodcastDetailView.swift` — removed the subscribe-heart
  toolbar item; title wraps full; empty nav title.
- `NerLan/Sources/Views/ProgramListView.swift` — swipe-to-取消訂閱 on 我的 Podcast
  rows.
- `NerLan/Sources/Views/ProgramDetailView.swift` — empty nav title.
