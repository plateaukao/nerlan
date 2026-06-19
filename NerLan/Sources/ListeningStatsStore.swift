import Combine
import Foundation

/// Tracks listening *behavior* — time spent, completed episodes, and per-day /
/// per-hour / per-program buckets — to power the 使用統計 screen. Persisted as
/// plain JSON in Documents (like `downloads.json`), and when iCloud sync is on,
/// each device mirrors its own blob to `CloudKVStore` under a per-device key.
///
/// Cross-device merge is a conflict-free **G-counter**: a device only ever
/// increments its *own* partition, and the displayed numbers are the sum across
/// every device's blob. Partitions never overlap, so summation can't double-count
/// or clobber the way a single shared total would when two devices listen offline.
@MainActor
final class ListeningStatsStore: ObservableObject {
    static let shared = ListeningStatsStore()

    /// One device's listening tallies.
    struct Stats: Codable {
        var dailySeconds: [String: Double] = [:]   // "yyyy-MM-dd" -> seconds
        var hourlyDate: String = ""                // the day `hourlySeconds` describes
        var hourlySeconds: [Int: Double] = [:]     // hour 0...23 -> seconds (that day only)
        var completedCount: Int = 0
        var programSeconds: [String: Double] = [:] // programId -> seconds
        var programNames: [String: String] = [:]   // programId -> display name
    }

    /// Plottable shapes for the charts / lists (Identifiable so they avoid
    /// tuple key-paths, which Swift can't form).
    struct DayStat: Identifiable, Hashable { let date: Date; let seconds: Double; var id: Date { date } }
    struct HourStat: Identifiable, Hashable { let hour: Int; let seconds: Double; var id: Int { hour } }
    struct ProgramStat: Identifiable, Hashable { let id: String; let name: String; let seconds: Double }

    /// Bumped on every change so observing views recompute the merged view.
    @Published private(set) var revision = 0

    /// This device's contribution — the only blob this instance writes.
    private var local = Stats()

    private let fileURL: URL
    /// Other devices' blobs pulled from Google Drive, one `stats-{deviceId}.json`
    /// per device. The KVS path keeps its peers in the key-value store; Drive can't
    /// see those, so it mirrors here instead. Merged together (deduped by device) on
    /// read, so a device syncing via both backends is never double-counted.
    private let peersDir: URL
    private let deviceId: String
    private static let kvsPrefix = "stats-"
    private static let deviceIdKey = "listeningStatsDeviceId"

    private var syncing = false
    /// Listening accumulated since the last disk write, to throttle persistence.
    private var unsavedSeconds: Double = 0

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("listening-stats.json")
        peersDir = docs.appendingPathComponent("stats-peers", isDirectory: true)

        if let saved = UserDefaults.standard.string(forKey: Self.deviceIdKey) {
            deviceId = saved
        } else {
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: Self.deviceIdKey)
            deviceId = id
        }

        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(Stats.self, from: data) {
            local = saved
        }

        if SettingsStore.syncToICloudEnabled { enableSync() }
    }

    // MARK: - Recording (called from PlayerManager)

    /// Add wall-clock listening time to the current day/hour and program.
    func addListening(seconds: Double, program record: EpisodeRecord?) {
        guard seconds > 0 else { return }
        let now = Date()
        let day = Self.dayKey(now)
        let hour = Calendar.current.component(.hour, from: now)

        local.dailySeconds[day, default: 0] += seconds
        if local.hourlyDate != day {
            local.hourlyDate = day
            local.hourlySeconds = [:]
        }
        local.hourlySeconds[hour, default: 0] += seconds

        if let record {
            local.programSeconds[record.programId, default: 0] += seconds
            local.programNames[record.programId] = record.programName
        }

        unsavedSeconds += seconds
        // Flush after ~5s of accumulated listening to keep disk writes cheap.
        if unsavedSeconds >= 5 { persistLocal() }
        revision += 1
    }

    /// Record an episode played through to the end.
    func noteCompleted(_ record: EpisodeRecord?) {
        local.completedCount += 1
        persistLocal()
        pushToKVS()
        DriveSync.requestSync()
        revision += 1
    }

    /// Persist and push to iCloud now — call on pause / when leaving an episode.
    func flush() {
        persistLocal()
        pushToKVS()
        DriveSync.requestSync()
    }

    /// Recompute the merged view after a Google Drive pull refreshed the peer blobs
    /// in `stats-peers/`. The peers are read live from disk, so this just nudges the
    /// observing screen.
    func reloadDrivePeers() { revision += 1 }

    // MARK: - Persistence

    private func persistLocal() {
        unsavedSeconds = 0
        prune()
        try? JSONEncoder().encode(local).write(to: fileURL)
    }

    /// Drop daily buckets older than ~400 days so the blob stays tiny for KVS.
    private func prune() {
        guard local.dailySeconds.count > 400 else { return }
        let old = Calendar.current.date(byAdding: .day, value: -400, to: Date()) ?? Date()
        let cutoff = Self.dayKey(old)
        local.dailySeconds = local.dailySeconds.filter { $0.key >= cutoff }
    }

    // MARK: - iCloud KVS sync (per-device G-counter)

    func enableSync() {
        guard !syncing else { return }
        syncing = true
        CloudKVStore.shared.observe(self, selector: #selector(kvsChanged))
        pushToKVS()
        CloudKVStore.shared.synchronize()
        revision += 1
    }

    func disableSync() {
        guard syncing else { return }
        syncing = false
        CloudKVStore.shared.unobserve(self)
        revision += 1
    }

    private func pushToKVS() {
        guard syncing, let data = try? JSONEncoder().encode(local) else { return }
        CloudKVStore.shared.set(data, forKey: Self.kvsPrefix + deviceId)
    }

    @objc private func kvsChanged() {
        Task { @MainActor in self.revision += 1 }
    }

    // MARK: - Merged read accessors (this device + other devices)

    /// This device's blob plus every other device's blob, from both backends. Peers
    /// are keyed by device id so a device present in both iCloud KVS and Drive is
    /// counted once (the G-counter only stays conflict-free if partitions don't
    /// overlap).
    private func mergedStats() -> [Stats] {
        var peers: [String: Stats] = [:]
        if syncing {
            let ownKey = Self.kvsPrefix + deviceId
            for entry in CloudKVStore.shared.entries(prefix: Self.kvsPrefix) where entry.key != ownKey {
                if let s = try? JSONDecoder().decode(Stats.self, from: entry.data) {
                    peers[String(entry.key.dropFirst(Self.kvsPrefix.count))] = s
                }
            }
        }
        if SettingsStore.shared.syncToDrive {
            let files = (try? FileManager.default.contentsOfDirectory(at: peersDir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                // "stats-{deviceId}.json" -> deviceId
                let name = file.deletingPathExtension().lastPathComponent
                guard name.hasPrefix(Self.kvsPrefix) else { continue }
                let id = String(name.dropFirst(Self.kvsPrefix.count))
                guard id != deviceId else { continue }
                if let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Stats.self, from: data) {
                    peers[id] = s
                }
            }
        }
        return [local] + Array(peers.values)
    }

    private func mergedDaily() -> [String: Double] {
        var out: [String: Double] = [:]
        for s in mergedStats() {
            for (day, secs) in s.dailySeconds { out[day, default: 0] += secs }
        }
        return out
    }

    var totalSeconds: Double { mergedDaily().values.reduce(0, +) }

    var completedCount: Int { mergedStats().reduce(0) { $0 + $1.completedCount } }

    var secondsToday: Double { mergedDaily()[Self.dayKey(Date())] ?? 0 }

    var secondsThisWeek: Double {
        guard let start = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start else { return 0 }
        return sumDaily(since: start)
    }

    var secondsThisMonth: Double {
        guard let start = Calendar.current.dateInterval(of: .month, for: Date())?.start else { return 0 }
        return sumDaily(since: start)
    }

    private func sumDaily(since start: Date) -> Double {
        let startKey = Self.dayKey(start)
        return mergedDaily().filter { $0.key >= startKey }.values.reduce(0, +)
    }

    /// Consecutive days with listening, ending today (or yesterday if today is
    /// still empty, so the streak holds until the day is actually missed).
    var currentStreak: Int {
        let daily = mergedDaily()
        let cal = Calendar.current
        var day = Date()
        if (daily[Self.dayKey(day)] ?? 0) <= 0 {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var streak = 0
        while (daily[Self.dayKey(day)] ?? 0) > 0 {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    /// Today's listening split into 24 hourly buckets.
    func hourlyTodayStats() -> [HourStat] {
        let today = Self.dayKey(Date())
        var hours = [Double](repeating: 0, count: 24)
        for s in mergedStats() where s.hourlyDate == today {
            for (hour, secs) in s.hourlySeconds where (0..<24).contains(hour) { hours[hour] += secs }
        }
        return hours.enumerated().map { HourStat(hour: $0.offset, seconds: $0.element) }
    }

    /// Listening per day for the last `days` days (oldest first), zero-filled.
    func dailySeries(lastDays days: Int) -> [DayStat] {
        let daily = mergedDaily()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<days).reversed().compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayStat(date: date, seconds: daily[Self.dayKey(date)] ?? 0)
        }
    }

    /// Programs ranked by listening time, descending.
    func topPrograms(_ limit: Int) -> [ProgramStat] {
        var secs: [String: Double] = [:]
        var names: [String: String] = [:]
        for s in mergedStats() {
            for (pid, v) in s.programSeconds { secs[pid, default: 0] += v }
            for (pid, n) in s.programNames where names[pid] == nil { names[pid] = n }
        }
        return secs.sorted { $0.value > $1.value }
            .prefix(limit)
            .map { ProgramStat(id: $0.key, name: names[$0.key] ?? $0.key, seconds: $0.value) }
    }

    var hasData: Bool { completedCount > 0 || totalSeconds > 0 }

    // MARK: - Helpers

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }
}
