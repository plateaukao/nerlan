# NerLan

An iOS language-learning audio player for Taiwan's National Education Radio (國立教育廣播電台) [Channel+](https://channelplus.ner.gov.tw) platform. Browse close to a hundred language-learning radio programs across 19 languages — Japanese, Korean, Vietnamese, Indonesian, Thai, Spanish, French, German, Taiwanese, Hakka, and more — and listen to full episode archives, online or offline.

There is a matching Android app at [plateaukao/nerlan-android](https://github.com/plateaukao/nerlan-android).

## Features

- **Browse programs** — ~96 language-learning programs, filterable with wrapping language chips (19 languages)
- **Full episode archives** — every episode of every program via the Channel+ on-demand archive, with infinite scroll
- **Background playback** — AVPlayer with lock-screen / Control Center controls (play/pause, skip, seek)
- **Playback speed** — 0.5× to 2× in steps, remembered across launches
- **Repeat modes** — off / repeat all / repeat one
- **Offline listening** — download episode MP3s, grouped by program and language
- **Favorites** — bookmark individual episodes and whole programs
- **Mini player** — floating now-playing bar above the tab bar, expandable to a full player sheet

## Architecture

A small SwiftUI app (iOS 17+) with a handful of singletons behind the views:

- **`NERAPI.swift` (`ChannelPlusAPI`)** — thin async/await `URLSession` client for the Channel+ REST API at `https://channelplus.ner.gov.tw/api/v1` (programs list, paginated episode archives, audio/image URL builders). The API is unofficial — endpoints were discovered from the site's network traffic.
- **`PlayerManager`** — app-wide `@MainActor` singleton owning the `AVPlayer` and the current queue. Drives `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` for lock-screen / Control Center integration, and persists rate/repeat settings in `UserDefaults`.
- **`DownloadManager`** — `URLSession` background-configuration downloads into `Documents/audio/{episodeId}.mp3`, with per-episode progress published to the UI.
- **`FavoritesStore`** — favorited episodes and programs.
- **Persistence** — favorites and download records are plain JSON files in the app's Documents directory; no database.

Views live in `NerLan/Sources/Views/`: a three-tab `ContentView` (Programs / Favorites / Downloads) plus program detail, full player sheet, and mini player bar.

## Building

The project is [XcodeGen](https://github.com/yonaskolb/XcodeGen)-based — `project.yml` is the source of truth and `NerLan.xcodeproj` is gitignored, so generate it first:

```bash
brew install xcodegen
xcodegen generate
open NerLan.xcodeproj
```

In Xcode, set your own development team under Signing & Capabilities (or edit `DEVELOPMENT_TEAM` in `project.yml` before generating), then build and run on a device or simulator.

Command line alternative:

```bash
xcodebuild -project NerLan.xcodeproj -scheme NerLan \
    -destination 'generic/platform=iOS' \
    DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates build
```

`Scripts/build_release.sh` archives and exports a development-signed `.ipa` into `.build/export/` (it is hard-wired to the author's team id; adjust `TEAM_ID` for your own use).

The `.ipa` attached to GitHub releases is development-signed, so it only installs on devices registered to the author's team — building from source is the normal way to run the app.

## Disclaimer

This is an **unofficial** client. It is not affiliated with, endorsed by, or sponsored by National Education Radio. All audio content, program metadata, and artwork belong to 國立教育廣播電台 (National Education Radio, Taiwan) and are streamed/downloaded directly from their public Channel+ service for personal listening.
