import Combine
import Foundation

/// User-configurable OpenAI credentials and model choices. The API key is kept
/// in the Keychain (via `Keychain`); model names are plain UserDefaults values.
/// Injected as an `environmentObject` like the other app-state singletons.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    static let defaultChatModel = "gpt-4o"
    static let defaultTranscriptionModel = "whisper-1"

    /// Selectable transcription models. whisper-1 collapses bilingual audio into
    /// the dominant language; the gpt-4o-transcribe models handle code-switching
    /// far better (see OpenAIService.transcribe).
    static let transcriptionModelOptions = ["whisper-1", "gpt-4o-mini-transcribe", "gpt-4o-transcribe"]

    private static let keychainAccount = "openai-api-key"
    private static let chatModelKey = "openaiChatModel"
    private static let transcriptionModelKey = "openaiTranscriptionModel"
    private static let cacheStreamedAudioKey = "cacheStreamedAudio"
    private static let syncToICloudKey = "syncAIContentToICloud"

    /// Nonisolated read of the persisted toggle, for stores that aren't on the
    /// main actor (e.g. `FavoritesStore`) and need it during their own init.
    nonisolated static var syncToICloudEnabled: Bool {
        UserDefaults.standard.bool(forKey: syncToICloudKey)
    }

    @Published var apiKey: String {
        didSet { Keychain.set(apiKey, account: Self.keychainAccount) }
    }

    @Published var chatModel: String {
        didSet { UserDefaults.standard.set(chatModel, forKey: Self.chatModelKey) }
    }

    @Published var transcriptionModel: String {
        didSet { UserDefaults.standard.set(transcriptionModel, forKey: Self.transcriptionModelKey) }
    }

    /// When on, an episode streamed to completion is saved for offline replay
    /// (see `CachingPlayerItem`). Off by default so it never silently uses data
    /// or storage the user didn't ask for.
    @Published var cacheStreamedAudio: Bool {
        didSet { UserDefaults.standard.set(cacheStreamedAudio, forKey: Self.cacheStreamedAudioKey) }
    }

    /// When on, AI transcripts and handouts are mirrored to the app's iCloud
    /// container (see `ICloudSync`) so they survive reinstalls and sync across
    /// the user's devices. Off by default; audio is never synced.
    @Published var syncToICloud: Bool {
        didSet {
            UserDefaults.standard.set(syncToICloud, forKey: Self.syncToICloudKey)
            // AIContentStore owns the readable names, so it drives enable (which
            // both starts the watcher and uploads existing content) / disable.
            if syncToICloud {
                AIContentStore.shared.enableICloudSync()
                FavoritesStore.shared.enableSync()
            } else {
                AIContentStore.shared.disableICloudSync()
                FavoritesStore.shared.disableSync()
            }
        }
    }

    /// Drives the visibility of the AI action icons.
    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private init() {
        // Property observers don't fire during init, so these loads don't write back.
        apiKey = Keychain.get(Self.keychainAccount) ?? ""
        chatModel = UserDefaults.standard.string(forKey: Self.chatModelKey) ?? Self.defaultChatModel
        transcriptionModel = UserDefaults.standard.string(forKey: Self.transcriptionModelKey)
            ?? Self.defaultTranscriptionModel
        cacheStreamedAudio = UserDefaults.standard.bool(forKey: Self.cacheStreamedAudioKey)
        syncToICloud = UserDefaults.standard.bool(forKey: Self.syncToICloudKey)
    }
}
