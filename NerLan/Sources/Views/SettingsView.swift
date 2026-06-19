import SwiftUI

/// OpenAI credentials & model configuration, presented as a sheet from the 節目
/// tab. The API key is stored in the Keychain via `SettingsStore`.
struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var ai: AIContentStore
    @EnvironmentObject var drive: DriveSync
    @Environment(\.dismiss) private var dismiss

    @State private var showClearConfirm = false
    @State private var showClearCacheConfirm = false
    @State private var cacheBytes: Int64 = 0
    @State private var signingIn = false
    @State private var transcriptionProbe: ProbeState = .idle
    @State private var chatProbe: ProbeState = .idle
    @State private var showServerDiscovery = false

    /// Result of a custom-server readiness check (see `verifyRow`).
    enum ProbeState: Equatable {
        case idle, checking, ok
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("API 來源", selection: $settings.apiProvider) {
                        Text("OpenAI 官方").tag(SettingsStore.APIProvider.openAIOfficial)
                        Text("自訂").tag(SettingsStore.APIProvider.custom)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("API 來源")
                } footer: {
                    Text("選擇 AI 逐字稿與講義要使用的伺服器。「自訂」可指向你自己（通常較便宜或本機）的 OpenAI 相容伺服器。兩組設定都會分別保存，可隨時切換。")
                }

                if settings.apiProvider == .openAIOfficial {
                    officialSections
                } else {
                    customSections
                }

                Section {
                    Picker("翻譯語言", selection: $settings.translationLanguage) {
                        ForEach(SettingsStore.translationLanguageOptions, id: \.self) { lang in
                            Text(lang).tag(lang)
                        }
                    }
                } header: {
                    Text("翻譯")
                } footer: {
                    Text("逐字稿畫面的「翻譯」按鈕會把內容翻譯成這個語言（使用你的 OpenAI 額度，並會同步到 iCloud）。")
                }

                Section {
                    Toggle("串流時自動快取", isOn: $settings.cacheStreamedAudio)
                    Button("清除快取音檔", role: .destructive) {
                        showClearCacheConfirm = true
                    }
                    .disabled(cacheBytes == 0)
                } header: {
                    Text("串流快取")
                } footer: {
                    Text("開啟後，串流完整播放過的音檔會自動保存，下次播放免再下載（不會顯示在「下載」分頁）。\(cacheSizeText)")
                }

                Section {
                    Toggle("同步到 iCloud", isOn: $settings.syncToICloud)
                } header: {
                    Text("iCloud 同步")
                } footer: {
                    Text("開啟後，逐字稿與 AI 講義會備份到 iCloud，並同步到你登入相同 Apple ID 的其他裝置（重新安裝後也會自動復原）。音檔不會同步。需登入 iCloud 並開啟 iCloud 雲碟。")
                }

                driveSection

                Section {
                    Button("清除所有 AI 內容", role: .destructive) {
                        showClearConfirm = true
                    }
                } footer: {
                    Text("刪除已儲存的逐字稿與 AI 講義。")
                }

                Section("統計") {
                    NavigationLink {
                        UsageStatsView()
                    } label: {
                        Label("使用統計", systemImage: "chart.bar.xaxis")
                    }
                    NavigationLink {
                        DataStatsView()
                    } label: {
                        Label("資料統計", systemImage: "internaldrive")
                    }
                }
            }
            .onAppear { cacheBytes = DownloadManager.shared.cachedAudioByteSize() }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog("確定要清除所有 AI 內容嗎？", isPresented: $showClearConfirm,
                                titleVisibility: .visible) {
                Button("清除", role: .destructive) { ai.clearAll() }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("確定要清除快取音檔嗎？", isPresented: $showClearCacheConfirm,
                                titleVisibility: .visible) {
                Button("清除", role: .destructive) {
                    DownloadManager.shared.clearAudioCache()
                    cacheBytes = 0
                }
                Button("取消", role: .cancel) {}
            }
            .sheet(isPresented: $showServerDiscovery) {
                ServerDiscoveryView { server in
                    settings.customTranscriptionURL = server.baseURL
                }
            }
        }
    }

    /// OpenAI-official provider: the API key plus the model pickers, billed to
    /// the user's OpenAI account.
    @ViewBuilder private var officialSections: some View {
        Section {
            SecureField("sk-…", text: $settings.apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("OpenAI API 金鑰")
        } footer: {
            Text("金鑰會安全地儲存在裝置的鑰匙圈中。逐字稿與 AI 講義會使用你的 OpenAI 額度。")
        }

        Section("模型") {
            Picker("轉錄模型", selection: $settings.transcriptionModel) {
                ForEach(SettingsStore.transcriptionModelOptions, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            LabeledContent("講義模型") {
                TextField(SettingsStore.defaultChatModel, text: $settings.chatModel)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Button("恢復預設模型") {
                settings.transcriptionModel = SettingsStore.defaultTranscriptionModel
                settings.chatModel = SettingsStore.defaultChatModel
            }
        }
    }

    /// Custom provider: two independent OpenAI-compatible endpoints — one for
    /// transcription, one for handout/translation — each with its own URL,
    /// model, and optional key (blank for keyless local servers).
    @ViewBuilder private var customSections: some View {
        Section {
            HStack {
                TextField(SettingsStore.defaultCustomServerURL, text: $settings.customTranscriptionURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button {
                    showServerDiscovery = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("搜尋區域網路伺服器")
            }
            LabeledContent("轉錄模型") {
                TextField(SettingsStore.defaultTranscriptionModel, text: $settings.customTranscriptionModel)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            SecureField(customKeyPlaceholder(for: settings.customTranscriptionURL),
                        text: $settings.customTranscriptionKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            verifyRow(title: "驗證轉錄伺服器", state: transcriptionProbe) {
                runProbe(settings.transcriptionConfig,
                         set: { transcriptionProbe = $0 },
                         probe: OpenAIService.verifyTranscription)
            }
        } header: {
            Text("轉錄伺服器")
        } footer: {
            Text("與 OpenAI 相容的伺服器網址（到 /v1 為止），用於 /audio/transcriptions。本機伺服器通常不需金鑰。")
        }
        .onChange(of: settings.customTranscriptionURL) { transcriptionProbe = .idle }
        .onChange(of: settings.customTranscriptionModel) { transcriptionProbe = .idle }
        .onChange(of: settings.customTranscriptionKey) { transcriptionProbe = .idle }

        Section {
            TextField(SettingsStore.defaultCustomServerURL, text: $settings.customChatURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            LabeledContent("講義／翻譯模型") {
                TextField(SettingsStore.defaultChatModel, text: $settings.customChatModel)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            SecureField(customKeyPlaceholder(for: settings.customChatURL),
                        text: $settings.customChatKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            verifyRow(title: "驗證講義／翻譯伺服器", state: chatProbe) {
                runProbe(settings.chatConfig,
                         set: { chatProbe = $0 },
                         probe: OpenAIService.verifyChat)
            }
        } header: {
            Text("講義／翻譯伺服器")
        } footer: {
            Text("與 OpenAI 相容的伺服器網址（到 /v1 為止），用於 /chat/completions。講義、翻譯與句子斷句都會使用這個伺服器。")
        }
        .onChange(of: settings.customChatURL) { chatProbe = .idle }
        .onChange(of: settings.customChatModel) { chatProbe = .idle }
        .onChange(of: settings.customChatKey) { chatProbe = .idle }
    }

    /// A tappable "verify" row that sends a tiny live request to the server and
    /// shows the outcome inline: a spinner while checking, a green check on
    /// success, or a red mark plus the server's error message on failure.
    @ViewBuilder
    private func verifyRow(title: String, state: ProbeState, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                switch state {
                case .idle: EmptyView()
                case .checking: ProgressView()
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
        }
        .disabled(state == .checking)
        if case .failed(let message) = state {
            Text(message).font(.footnote).foregroundStyle(.red)
        }
    }

    /// Placeholder for a custom key field: when the endpoint is still OpenAI's,
    /// an empty key falls back to the OpenAI-mode key, so say so; otherwise it's
    /// optional (keyless local servers).
    private func customKeyPlaceholder(for url: String) -> String {
        settings.customURLIsOfficial(url) ? "與 OpenAI 模式相同（可留空）" : "API 金鑰（可留空）"
    }

    /// Run a readiness probe: flip the row to `.checking`, await the live request,
    /// then record `.ok` or `.failed(message)`. The `config` is resolved on the
    /// main actor by the caller and passed in (a `Sendable` value), so the async
    /// `probe` never touches main-actor state. `set` writes the matching `@State`.
    private func runProbe(_ config: OpenAIService.Config,
                          set: @escaping (ProbeState) -> Void,
                          probe: @escaping (OpenAIService.Config) async throws -> Void) {
        set(.checking)
        Task {
            do {
                try await probe(config)
                set(.ok)
            } catch {
                set(.failed(error.localizedDescription))
            }
        }
    }

    /// Google Drive — the bridge to the Android app. Signed-out shows a sign-in
    /// button; signed-in shows the account, the sync toggle, a manual "sync now",
    /// and sign-out.
    @ViewBuilder private var driveSection: some View {
        Section {
            if drive.accountEmail == nil {
                Button {
                    signingIn = true
                    Task {
                        await drive.signIn()
                        signingIn = false
                    }
                } label: {
                    HStack {
                        Label("登入 Google 並開啟同步", systemImage: "person.crop.circle.badge.plus")
                        if signingIn { Spacer(); ProgressView() }
                    }
                }
                .disabled(signingIn)
            } else {
                LabeledContent("Google 帳戶", value: drive.accountEmail ?? "")
                Toggle("同步到 Google Drive", isOn: $settings.syncToDrive)
                Button("立即同步") { drive.syncNow() }
                    .disabled(!settings.syncToDrive)
                Button("登出 Google", role: .destructive) { drive.signOut() }
            }
            if let status = drive.status {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Google Drive 同步")
        } footer: {
            Text("開啟後，最愛、AI 逐字稿與講義、收聽統計與 Podcast 訂閱會備份到你的 Google Drive（隱藏的應用程式資料夾），並與 Android 版 App 互通。可與 iCloud 同步並用。音檔不會同步。")
        }
    }

    private var cacheSizeText: String {
        guard cacheBytes > 0 else { return "" }
        let size = ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
        return "目前已快取 \(size)。"
    }
}
