# Android companion app — reference for cross-platform work

The Android port lives in a **separate repo**: `~/src/nerlan-android`
(GitHub `plateaukao/nerlan-android`). This iOS repo and that one are kept in
feature parity — most changes here are mirrored there. This doc captures the
Android app's structure and the iOS↔Android mapping so future features can be
ported without re-discovering it each time.

## TL;DR conventions

- **Language/UI:** Kotlin + Jetpack Compose (Material 3, incl. *expressive* APIs).
  Package root `com.example.nerlan` (applicationId `com.danielkao.nerlan`).
- **No DI framework.** Stores are manual singletons created in
  `NerLanApp.onCreate()` and reached via `NerLanApp.instance.<store>`. Add a new
  store the same way.
- **No database.** Persistence is JSON files via `kotlinx.serialization` in
  `filesDir` (user data) or `cacheDir` (re-fetchable). Same files/688 names as iOS
  (`favorites.json`, `downloads.json`, `podcasts.json`, …).
- **Networking:** raw **OkHttp** (`ChannelPlusApi.client`), no Retrofit. JSON via
  `Json { ignoreUnknownKeys = true }`.
- **Player:** media3 (ExoPlayer + MediaSession) behind the `PlayerManager` object;
  it consumes `EpisodeRecord.audio` exactly like iOS (offline copy preferred).
- **Navigation:** **manual**, not Navigation-Compose. `MainScreen` keeps a tab
  index plus per-tab nullable "detail" state; a detail screen is overlaid on its
  tab and dismissed by setting the state back to null. (navigation3 libs are on
  the classpath but unused.)
- **Models live in one file** (`data/Models.kt`), unlike iOS's split files.

## Layout (`app/src/main/java/com/example/nerlan/`)

| Area | Android | iOS counterpart |
|------|---------|-----------------|
| App / DI | `NerLanApp.kt` (Application, holds all stores) | `NerLanApp.swift` (`@main`, `environmentObject`s) |
| Models | `data/Models.kt` (all types) | `Models.swift` |
| NER API | `data/ChannelPlusApi.kt` (`object`, OkHttp) | `NERAPI.swift` (`enum`) |
| Catalog cache | `data/CatalogCache.kt` | `CatalogCache.swift` |
| Downloads | `data/DownloadManager.kt` | `DownloadManager.swift` |
| Favorites | `data/FavoritesStore.kt` | `FavoritesStore.swift` |
| Stats | `data/ListeningStatsStore.kt` | `ListeningStatsStore.swift` |
| Settings | `data/SettingsStore.kt` | `SettingsStore.swift` |
| AI content | `data/AIContentStore.kt` | `AIContentStore.swift` |
| OpenAI client | `data/OpenAIService.kt` | `OpenAIService.swift` |
| Audio transcode/chunk | `data/AudioTranscoder.kt` (media3 Transformer) | `SpeechAudioExporter.swift` (AVAssetReader/Writer) |
| Cloud sync | `data/DriveSync.kt` (Google Drive appDataFolder) | `ICloudSync.swift` + `CloudKVStore.swift` |
| Player | `player/PlayerManager.kt`, `player/PlaybackService.kt`, `player/AudioCache.kt` | `PlayerManager.swift`, `CachingPlayerItem.swift` |
| Podcasts | `data/PodcastApi.kt`, `data/PodcastFeedParser.kt`, `data/PodcastStore.kt`; `data/Models.kt` `PodcastFeed`; `ui/PodcastDetailScreen.kt`, `ui/AddPodcastDialog.kt` | `PodcastAPI/FeedParser/Store/Feed.swift`, `Views/PodcastDetailView.swift`, `Views/AddPodcastView.swift` |
| Root scaffold / tabs | `ui/MainScreen.kt` | `Views/ContentView.swift` |
| Program list | `ui/ProgramListScreen.kt` (+ `ProgramRow`) | `Views/ProgramListView.swift` |
| Program detail | `ui/ProgramDetailScreen.kt` (+ `EpisodeRow`) | `Views/ProgramDetailView.swift` |
| Shared record row | `ui/FavoritesScreen.kt` → `RecordRow` (also used by Downloads/AI) | `Views/DownloadsView.swift` → `RecordRow` |
| Downloads / AI tabs | `ui/DownloadsScreen.kt`, `ui/AiTabScreen.kt` | `Views/DownloadsView.swift`, `AITabView.swift` |
| AI buttons | `ui/AiActions.kt` (`AiActionButton`) | `Views/AIActions.swift` (`AIActionButton`) |
| Handout / transcript readers | `ui/HandoutDialog.kt` (WebView), `ui/TranscriptDialog.kt` | `Views/HandoutView.swift`, `TranscriptView.swift` |
| Two-pane study panel | `ui/StudyPanel.kt` (`StudyItem`, `LocalStudyPanel`) | `StudyPanel.swift`, `Views/StudyDetailView.swift` |
| Attachment (PDF) viewer | `ui/AttachmentViewer.kt` (`PdfRenderer`) | `Views/AttachmentView.swift` (PDFKit) |

## The pivot type — `EpisodeRecord` (data/Models.kt)

`@Serializable data class` with the same fields as iOS: `id, title, playDate?,
audio?, programId, programName, language, coverUrl?, attachments?,
durationSeconds?, audioExt?`. New fields **must** be nullable with a default
(`= null`) so old JSON still decodes (kotlinx uses the default for missing keys;
`ignoreUnknownKeys = true` covers the reverse). Built from API episodes via
`EpisodeRecord.from(episode, program)`. Everything downstream (player, downloads,
favorites, AI, stats) consumes only `EpisodeRecord` — so a feature that can
*produce* records (e.g. podcasts) gets all of it for free, same as iOS.

## Store pattern

```kotlin
class FooStore(filesDir: File) {
  private val file = File(filesDir, "foo.json")
  private val json = Json { ignoreUnknownKeys = true }
  private val _items = MutableStateFlow(load() ?: emptyList())
  val items: StateFlow<List<Foo>> = _items
  private fun persist() = runCatching { file.writeText(json.encodeToString(_items.value)) }
}
```
Register in `NerLanApp.onCreate()` (`lateinit var foo: FooStore; private set`) and
read in Composables via `NerLanApp.instance.foo`, collecting flows with
`collectAsState()`. Cross-device sync (if needed) goes through `DriveSync` (it
mirrors the iOS iCloud KVS approach: per-key files in Drive appDataFolder).

## OpenAI / handout flow (data/AIContentStore.kt + OpenAIService.kt)

`processHandout` → `runHandout`: gets the transcript (`runTranscript`, cached as
`ai/transcripts/{id}.txt`), then `OpenAIService.generateHandout` → HTML fragment
saved to `ai/handouts/{id}.html`, rendered by `HandoutDialog` in a `WebView`.
Audio for transcription is chunked by `AudioTranscoder` (media3 Transformer →
mono 16 kHz m4a, `MAX_CHUNK_SECONDS = 1200`). Handout chunking into ~15-min
`Part I/II/III` sections is done in `runHandout` by splitting the transcript
(`handoutSegments`) — mirrors iOS `AIContentStore.handoutSegments` /
`OpenAIService.generateHandout(partTitle:)`.

## Podcasts (RSS) — Android specifics

- **RSS parsing:** use the built-in `android.util.Xml.newPullParser()`
  (`XmlPullParser`, namespaces OFF so `itunes:duration` etc. arrive as raw
  qualified names). No third-party XML dep needed. iOS uses `XMLParser`.
- **Apple URL → feed:** `PodcastApi.resolveFeedUrl` extracts the numeric id from
  `…/id(\d+)` and calls `https://itunes.apple.com/lookup?id=…&entity=podcast` for
  `feedUrl`; `apple.co` short links resolve via OkHttp redirect
  (`response.request.url`). Set a browser-ish `User-Agent` on feed fetches.
- **Stable ids/hash:** `"pod-" + sha256(guid ?: enclosureUrl)` via
  `java.security.MessageDigest` (iOS uses CryptoKit) — keeps download filenames
  safe and dedups favorites/AI.
- **Extension-aware downloads:** `DownloadManager` probes `{id}.{ext}` (mp3 first)
  instead of hardcoding `.mp3`, so AAC/`.m4a` podcasts play. media3's streamed
  cache is keyed by URL (not filename), so no cache-naming change is needed
  (unlike iOS, which had to thread the extension through `CachingPlayerItem`).

## Build & deploy

- Source of truth: Gradle (`app/build.gradle.kts`, `gradle/libs.versions.toml`).
  `compileSdk/targetSdk 36`, `minSdk 24`, Kotlin/JVM 17, Compose BOM, media3,
  OkHttp, kotlinx-serialization, Coil, play-services-auth.
- Build debug: `cd ~/src/nerlan-android && ./gradlew :app:assembleDebug`.
- Install to the real phone uses the **signed release** flow — see the
  `nerlan-android-deploy` memory (and **never uninstall without permission**, per
  that memory). CI builds a snapshot APK via GitHub Actions (`nerlan-android-ci-release`).
- Key gotcha: on the GoColor7 color e-ink tablet, two-pane kicks in at ≥800dp;
  keep controls icon-only and mind window insets (`nerlan-android-eink-tablet`).

## Porting checklist (what to touch for a record-producing feature like podcasts)

1. `data/Models.kt` — new `@Serializable` model + any `EpisodeRecord` fields
   (nullable + default).
2. New `data/*.kt` for API/parsing/store; register the store in `NerLanApp`.
3. `DownloadManager` if audio format varies (extension probing).
4. `ui/FavoritesScreen.kt` `RecordRow` — gate new affordances behind params so the
   existing tabs are unchanged; collect new flows only in sub-composables that are
   conditionally included (avoids recomposition regressions).
5. New `ui/*Screen.kt` / dialog; wire navigation in `ui/MainScreen.kt`
   (add a nullable detail state + overlay in the relevant `TabContainer`).
