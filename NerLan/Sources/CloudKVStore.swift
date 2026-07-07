import Foundation

/// Thin shared wrapper over `NSUbiquitousKeyValueStore` for syncing small,
/// mutable per-item records across the user's devices: favorited episodes and
/// programs, and the AI tab's per-episode metadata. Each item is stored under
/// its own key (e.g. `fav-ep-<id>`), so independent add/remove on different
/// devices don't clobber each other the way a single whole-list blob would.
///
/// This is deliberately separate from `ICloudSync`, which mirrors the large,
/// write-once transcript/handout *files* through the iCloud Documents container.
/// KVS fits small key-value data (Apple caps it at ~1 MB total / 1024 keys).
final class CloudKVStore {
    static let shared = CloudKVStore()

    private let store = NSUbiquitousKeyValueStore.default
    private init() {}

    func synchronize() { store.synchronize() }

    func set(_ data: Data, forKey key: String) {
        store.set(data, forKey: key)
        store.synchronize()
    }

    /// Write without the per-key `synchronize()` — for bulk pushes (reconcile
    /// loops), where flushing once per key is redundant work. Call
    /// `synchronize()` once after the batch.
    func setDeferred(_ data: Data, forKey key: String) {
        store.set(data, forKey: key)
    }

    func remove(_ key: String) {
        store.removeObject(forKey: key)
        store.synchronize()
    }

    func data(forKey key: String) -> Data? { store.data(forKey: key) }

    /// All (key, data) pairs whose key starts with `prefix`.
    func entries(prefix: String) -> [(key: String, data: Data)] {
        store.dictionaryRepresentation.compactMap { key, value in
            guard key.hasPrefix(prefix), let data = value as? Data else { return nil }
            return (key, data)
        }
    }

    /// Observe external (other-device) changes. `target`'s `selector` receives the
    /// `NSUbiquitousKeyValueStore.didChangeExternallyNotification`; inspect its
    /// `changedKeysKey` userInfo to see what moved.
    func observe(_ target: Any, selector: Selector) {
        NotificationCenter.default.addObserver(
            target, selector: selector,
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store)
    }

    func unobserve(_ target: Any) {
        NotificationCenter.default.removeObserver(
            target, name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store)
    }
}
