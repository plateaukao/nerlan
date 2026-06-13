# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

NerLan is an unofficial iOS (SwiftUI, iOS 17+) audio player for language-learning programs from Taiwan's National Education Radio Channel+ platform. No external dependencies, no database, no test target — the whole app is ~12 Swift files under `NerLan/Sources/`.

## Build commands

The project is XcodeGen-based: `project.yml` is the source of truth and `NerLan.xcodeproj` is gitignored. After editing `project.yml` **or adding/removing source files**, regenerate before building:

```bash
xcodegen generate
```

Build for a device (signing uses team `3WD42GF27D` from `project.yml`):

```bash
xcodebuild -project NerLan.xcodeproj -scheme NerLan \
    -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

Deploy to a connected device: build with `-destination 'platform=iOS,id=<xcodebuild-dest-id>'`, then `xcrun devicectl device install app --device <devicectl-id> <path-to-.app>` and `xcrun devicectl device process launch`. (IDs via `xcrun devicectl list devices`.) The user prefers to verify changes on his real phone himself — install and let him check rather than relying on simulator interaction.

Release `.ipa` (archive + development-signed export into `.build/export/`):

```bash
bash Scripts/build_release.sh
```

There are no tests and no linter configured.

## Architecture

The API layer is stateless and called statically; three `ObservableObject` singletons own all app state and are injected as `environmentObject`s in `NerLanApp.swift` (`PlayerManager.shared`, `DownloadManager.shared`, `FavoritesStore.shared`).

- **`ChannelPlusAPI`** (`NERAPI.swift`) — stateless `enum` (no instance, not an `environmentObject`) wrapping the unofficial Channel+ REST API at `https://channelplus.ner.gov.tw/api/v1`. Endpoints were reverse-engineered from the site's network traffic; responses use an `APIResponse<T>` envelope where `rtnCode == "0000"` means success. Language programs are `programType=2`; episodes are fetched ascending by episode number (sequential courses). Audio and cover images are fetched through `audio?key=` / `image?key=` URL builders.
- **`PlayerManager`** — `@MainActor` singleton owning the `AVPlayer` and the playback queue; drives lock-screen/Control Center via `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`. Playback rate and repeat mode persist in `UserDefaults`. When loading an episode it asks `DownloadManager` for a local copy first and falls back to the remote URL.
- **`DownloadManager`** — background-configuration `URLSession` downloading MP3s to `Documents/audio/{episodeId}.mp3`, with per-episode progress published to the UI. When an episode is downloaded it also pulls any attachments (PDF handouts) into `Documents/attachments/{attachmentKey}.{ext}` so they're available offline; attachment downloads ride along silently (no progress UI) and are removed when the episode is deleted.
- **`FavoritesStore`** — favorited episodes and programs.

The pivot type is **`EpisodeRecord`** (`Models.swift`): a self-contained snapshot of an episode plus its program context (name, language, cover URL, and any `Attachment`s). Favorites, downloads, and the player queue all hold `EpisodeRecord`s so they render and play without re-fetching the API. Views convert API `Episode`s to records at the point of playing/favoriting/downloading. (When adding a field to `EpisodeRecord`, keep it optional — old `favorites.json`/`downloads.json` must still decode.)

Episodes may carry **attachments** — PDF handouts (講義) served from the API's `file?key=` endpoint. When a record has a PDF attachment, an info icon appears in the full player and in the downloads/favorites rows (deliberately not on the program's episode list, which is long); tapping it opens `AttachmentView` (a PDFKit reader) in a sheet over the player so the user can read along while the episode plays. The reader uses the offline copy when present, else fetches the PDF on demand.

Persistence is plain JSON files in Documents (`favorites.json`, `favorite-programs.json`, `downloads.json`) — keep it that way; there is deliberately no database layer.

UI: `ContentView` is a three-tab `TabView` (Programs / Favorites / Downloads) with the mini player floated above the tab bar as a bottom `.overlay` — not `safeAreaInset`, which doesn't receive touches reliably over a `List`. Note: simulator tap injection (mobile-mcp) misattributes hits around this overlay; on-device behavior is correct, so don't diagnose hit-testing issues from synthetic simulator taps.

There is a matching Android app at `plateaukao/nerlan-android`; feature changes here often mirror it.
