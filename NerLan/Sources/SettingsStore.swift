import Combine
import Foundation

/// User-configurable OpenAI credentials and model choices. The API key is kept
/// in the Keychain (via `Keychain`); model names are plain UserDefaults values.
/// Injected as an `environmentObject` like the other app-state singletons.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    /// Which OpenAI-compatible backend the AI features hit. `custom` lets the
    /// user point transcription and chat at their own (often cheaper or local)
    /// servers; both providers' settings persist, so switching back and forth
    /// keeps each side's configuration. See `transcriptionConfig`/`chatConfig`.
    enum APIProvider: String { case openAIOfficial, custom }

    static let defaultChatModel = "gpt-4o"
    static let defaultTranscriptionModel = "whisper-1"
    static let defaultTranslationLanguage = "繁體中文"

    /// Default value (and placeholder) for the custom server URLs — the official
    /// OpenAI base, so the field starts as a ready-to-edit template.
    static let defaultCustomServerURL = OpenAIService.officialBase.absoluteString

    /// Languages the transcript "translate" button can render into. Display names
    /// are passed straight into the translation prompt, so they're written the way
    /// a native reader expects to see them.
    static let translationLanguageOptions = [
        "繁體中文", "English", "日本語", "한국어", "Español",
        "Français", "Deutsch", "Tiếng Việt", "Bahasa Indonesia", "ภาษาไทย",
    ]

    /// Selectable transcription models. whisper-1 collapses bilingual audio into
    /// the dominant language; the gpt-4o-transcribe models handle code-switching
    /// far better (see OpenAIService.transcribe).
    static let transcriptionModelOptions = ["whisper-1", "gpt-4o-mini-transcribe", "gpt-4o-transcribe"]

    private static let keychainAccount = "openai-api-key"
    private static let chatModelKey = "openaiChatModel"
    private static let transcriptionModelKey = "openaiTranscriptionModel"
    private static let translationLanguageKey = "translationLanguage"
    private static let apiProviderKey = "apiProvider"
    private static let customTranscriptionURLKey = "customTranscriptionURL"
    private static let customTranscriptionModelKey = "customTranscriptionModel"
    private static let customChatURLKey = "customChatURL"
    private static let customChatModelKey = "customChatModel"
    private static let customTranscriptionKeyAccount = "custom-transcription-api-key"
    private static let customChatKeyAccount = "custom-chat-api-key"
    private static let cacheStreamedAudioKey = "cacheStreamedAudio"
    private static let syncToICloudKey = "syncAIContentToICloud"
    private static let syncToDriveKey = "syncToGoogleDrive"

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

    /// `openAIOfficial` (use the OpenAI key + models above) or `custom` (use the
    /// self-hosted server settings below). Drives which `*Config` is handed to
    /// `OpenAIService`.
    @Published var apiProvider: APIProvider {
        didSet { UserDefaults.standard.set(apiProvider.rawValue, forKey: Self.apiProviderKey) }
    }

    /// Custom transcription server: an OpenAI-compatible `/v1` base URL hosting
    /// `POST /audio/transcriptions` (e.g. a LAN whisper.cpp server), its model
    /// name, and an optional bearer key (blank for keyless local servers).
    @Published var customTranscriptionURL: String {
        didSet { UserDefaults.standard.set(customTranscriptionURL, forKey: Self.customTranscriptionURLKey) }
    }

    @Published var customTranscriptionModel: String {
        didSet { UserDefaults.standard.set(customTranscriptionModel, forKey: Self.customTranscriptionModelKey) }
    }

    @Published var customTranscriptionKey: String {
        didSet { Keychain.set(customTranscriptionKey, account: Self.customTranscriptionKeyAccount) }
    }

    /// Custom translation/handout server: an OpenAI-compatible `/v1` base URL
    /// hosting `POST /chat/completions`, the model used for handouts,
    /// translation and sentence segmentation, and an optional bearer key.
    @Published var customChatURL: String {
        didSet { UserDefaults.standard.set(customChatURL, forKey: Self.customChatURLKey) }
    }

    @Published var customChatModel: String {
        didSet { UserDefaults.standard.set(customChatModel, forKey: Self.customChatModelKey) }
    }

    @Published var customChatKey: String {
        didSet { Keychain.set(customChatKey, account: Self.customChatKeyAccount) }
    }

    /// Language the transcript screen's "translate" button renders into.
    @Published var translationLanguage: String {
        didSet { UserDefaults.standard.set(translationLanguage, forKey: Self.translationLanguageKey) }
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
                ListeningStatsStore.shared.enableSync()
                PodcastStore.shared.enableSync()
            } else {
                AIContentStore.shared.disableICloudSync()
                FavoritesStore.shared.disableSync()
                ListeningStatsStore.shared.disableSync()
                PodcastStore.shared.disableSync()
            }
        }
    }

    /// When on, the same local JSON source-of-truth is mirrored to the user's
    /// Google Drive `appDataFolder` (see `DriveSync`) — the bridge to the Android
    /// app. Independent of `syncToICloud`; both can be on at once. Off by default;
    /// requires a Google sign-in (handled by `DriveSync`).
    @Published var syncToDrive: Bool {
        didSet {
            UserDefaults.standard.set(syncToDrive, forKey: Self.syncToDriveKey)
            if syncToDrive { DriveSync.shared.syncNow() }
            else { DriveSync.shared.cancelPending() }
        }
    }

    /// Drives the visibility of the AI action icons: true once the active
    /// provider is configured enough to attempt a transcription (official → a
    /// key is set; custom → a transcription server URL is set).
    var hasAPIKey: Bool {
        switch apiProvider {
        case .openAIOfficial:
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .custom:
            return !customTranscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Endpoint for `OpenAIService.transcribe`, resolved from the active provider.
    var transcriptionConfig: OpenAIService.Config {
        switch apiProvider {
        case .openAIOfficial:
            return .init(baseURL: OpenAIService.officialBase, apiKey: apiKey, model: transcriptionModel)
        case .custom:
            return .init(baseURL: Self.url(customTranscriptionURL),
                         apiKey: customKey(customTranscriptionKey, url: customTranscriptionURL),
                         model: customTranscriptionModel, requiresKey: false)
        }
    }

    /// Endpoint for the chat-based operations (handout, translation, sentence
    /// segmentation), resolved from the active provider.
    var chatConfig: OpenAIService.Config {
        switch apiProvider {
        case .openAIOfficial:
            return .init(baseURL: OpenAIService.officialBase, apiKey: apiKey, model: chatModel)
        case .custom:
            return .init(baseURL: Self.url(customChatURL),
                         apiKey: customKey(customChatKey, url: customChatURL),
                         model: customChatModel, requiresKey: false)
        }
    }

    /// True when a custom server URL still points at the official OpenAI endpoint
    /// (the field's default) — in which case an unset custom key reuses the
    /// OpenAI-mode key rather than sending none.
    func customURLIsOfficial(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines) == Self.defaultCustomServerURL
    }

    /// The effective key for a custom endpoint: the explicitly-entered custom key
    /// if any, otherwise the OpenAI-mode key when the endpoint is unchanged from
    /// OpenAI's, otherwise none (keyless local server).
    private func customKey(_ raw: String, url: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { return key }
        return customURLIsOfficial(url) ? apiKey : ""
    }

    /// Parse a user-entered server URL, trimming whitespace and falling back to
    /// the official base if it's blank/unparseable (the request then fails with
    /// a clear server error rather than a crash).
    private static func url(_ raw: String) -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed) ?? OpenAIService.officialBase
    }

    private init() {
        // Property observers don't fire during init, so these loads don't write back.
        apiKey = Keychain.get(Self.keychainAccount) ?? ""
        chatModel = UserDefaults.standard.string(forKey: Self.chatModelKey) ?? Self.defaultChatModel
        transcriptionModel = UserDefaults.standard.string(forKey: Self.transcriptionModelKey)
            ?? Self.defaultTranscriptionModel
        apiProvider = UserDefaults.standard.string(forKey: Self.apiProviderKey)
            .flatMap(APIProvider.init(rawValue:)) ?? .openAIOfficial
        customTranscriptionURL = UserDefaults.standard.string(forKey: Self.customTranscriptionURLKey)
            ?? Self.defaultCustomServerURL
        customTranscriptionModel = UserDefaults.standard.string(forKey: Self.customTranscriptionModelKey)
            ?? Self.defaultTranscriptionModel
        customTranscriptionKey = Keychain.get(Self.customTranscriptionKeyAccount) ?? ""
        customChatURL = UserDefaults.standard.string(forKey: Self.customChatURLKey)
            ?? Self.defaultCustomServerURL
        customChatModel = UserDefaults.standard.string(forKey: Self.customChatModelKey) ?? Self.defaultChatModel
        customChatKey = Keychain.get(Self.customChatKeyAccount) ?? ""
        translationLanguage = UserDefaults.standard.string(forKey: Self.translationLanguageKey)
            ?? Self.defaultTranslationLanguage
        cacheStreamedAudio = UserDefaults.standard.bool(forKey: Self.cacheStreamedAudioKey)
        syncToICloud = UserDefaults.standard.bool(forKey: Self.syncToICloudKey)
        syncToDrive = UserDefaults.standard.bool(forKey: Self.syncToDriveKey)
    }
}
