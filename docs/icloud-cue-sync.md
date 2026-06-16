# NerLan — iCloud sync for transcript cue files

## Summary

The transcript sentence-highlight cues (`Documents/ai/cues/{id}.json`) now sync
through the app's iCloud container, so highlighting follows the user to their
other devices. Previously cues were local-only: a transcript would sync, but a
second device showed it without the karaoke highlight. Cue start times are
absolute audio time, so a cue file produced on one device applies unchanged on
any device that plays the same episode.

## Approach

`ICloudSync` already mirrored two write-once artifacts — `transcript.txt` and
`handout.html` — into a readable per-episode folder. Cues are modeled as a third
member of the same machinery rather than a parallel path:

- **A third `Kind` case (`.cues` → `cues.json`).** The `Kind` enum's
  `localSub`/`localExt`/`cloudFile` were binary ternaries assuming exactly two
  cases; they became `switch`es, and `Kind` is now `CaseIterable`. The
  `NSMetadataQuery` predicate and `parseCloudURL` were rewritten to derive from
  `Kind.allCases`, so any future kind is picked up automatically. The cloud folder
  for an episode now reads `transcript.txt` / `handout.html` / `cues.json`.

- **Upload points mirror the transcript's.** `AIContentStore.runTranscript`
  mirrors the cue sidecar up right after the transcript (only when cues were
  produced), and `enableICloudSync` sweeps existing `cues/*.json` on toggle-on /
  launch — so cues generated before this change still propagate. Because cues
  live outside `AIContentStore.Kind` (which is transcript/handout), they're
  referenced as `ICloudSync.Kind.cues` directly rather than through `cloudKind`.

- **Deletion stays consistent.** Deleting a transcript already removed the local
  cue file; it now also removes the cloud copy (`removeUp(.cues)`). `clearAll`
  needed no change — it removes whole episode folders, `cues.json` included.

- **Pull is already kind-agnostic.** The incoming path keys off the filename and
  copies to `localFile(kind, id)` = `ai/cues/{id}.json`, so adding the kind was
  enough; `onDidPull` refreshes the cue-driven UI as before. A cue file that
  arrives before its transcript simply waits in `cues/` until the transcript
  shows.

## Trade-offs

- **No new toggle.** Cues follow the existing "sync AI content to iCloud"
  switch; they aren't independently controllable. They're small and derived, so a
  separate control would be noise.

- **Independent, eventually-consistent files.** Transcript and cue are synced as
  separate files, so a device can briefly have the transcript but not yet the
  cues (or vice-versa). Both are write-once and the UI degrades gracefully
  (transcript without highlight), so no coordination was added.

- **Open-view staleness.** If cues arrive while their transcript is already open,
  the highlight appears on next open rather than mid-view. Acceptable for a rare
  timing window.

## Key Files

- `NerLan/Sources/ICloudSync.swift` — `Kind` gains `.cues`, becomes
  `CaseIterable`, ternaries → switches; query predicate and `parseCloudURL`
  derive from `Kind.allCases`; header doc updated for the new folder layout.
- `NerLan/Sources/AIContentStore.swift` — mirror cues up in `runTranscript` and
  `enableICloudSync`; remove the cloud cue copy in `delete`.
