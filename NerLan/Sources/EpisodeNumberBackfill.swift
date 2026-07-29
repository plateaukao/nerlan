import Foundation

/// One-time-per-record migration: records persisted before `EpisodeRecord.episodeNo`
/// existed decode with it nil, which leaves the Downloads/AI lists sorted by
/// release date — meaningless for bulk-published courses that share one date.
/// At launch this fills the number in from the on-disk catalog cache when the
/// program's episode pages are there, else with one API fetch per affected
/// program, then persists — so each record is fixed exactly once.
enum EpisodeNumberBackfill {
    @MainActor
    static func run() async {
        // NER records missing a number, by program. Podcasts (audioLocale != nil)
        // have no episode numbers and no NER program to ask.
        var neededIds = Set<String>()
        var programIds = Set<String>()
        let stores: [[EpisodeRecord]] = [
            DownloadManager.shared.records,
            DownloadManager.shared.cachedRecords,
            FavoritesStore.shared.favorites,
            Array(AIContentStore.shared.records.values),
        ]
        for record in stores.joined()
            where record.episodeNo == nil && record.audioLocale == nil {
            neededIds.insert(record.id)
            programIds.insert(record.programId)
        }
        guard !neededIds.isEmpty else { return }

        var numbers: [String: Int] = [:]
        func harvest(_ episodes: [Episode]) {
            for ep in episodes {
                if let n = ep.episodeNumber { numbers[ep.episodeId] = n }
            }
        }

        // Cached catalog pages first — free and offline.
        for programId in programIds {
            if let page = CatalogCache.loadEpisodes(programId: programId) {
                harvest(page.episodes)
            }
        }

        // Fetch programs that still have unresolved ids. Missing numbers cost at
        // most a page sweep per program per launch; once resolved and persisted
        // the whole backfill short-circuits above.
        let unresolved = Set(
            stores.joined()
                .filter { neededIds.contains($0.id) && numbers[$0.id] == nil }
                .map(\.programId))
        for programId in unresolved {
            var page = 1
            var totalPages = 1
            repeat {
                guard let result = try? await ChannelPlusAPI.episodes(
                    programId: programId, page: page, pageSize: 500) else { break }
                harvest(result.episodes)
                totalPages = result.totalPages
                page += 1
            } while page <= totalPages
        }

        guard !numbers.isEmpty else { return }
        DownloadManager.shared.applyEpisodeNumbers(numbers)
        FavoritesStore.shared.applyEpisodeNumbers(numbers)
        AIContentStore.shared.applyEpisodeNumbers(numbers)
    }

    /// Fill nil `episodeNo`s from the map. Returns true when anything changed,
    /// so callers persist only then.
    static func apply(_ numbers: [String: Int], to records: inout [EpisodeRecord]) -> Bool {
        var changed = false
        for i in records.indices where records[i].episodeNo == nil {
            if let n = numbers[records[i].id] {
                records[i].episodeNo = n
                changed = true
            }
        }
        return changed
    }
}
