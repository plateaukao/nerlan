import SwiftUI

/// OpenAI credentials & model configuration, presented as a sheet from the 節目
/// tab. The API key is stored in the Keychain via `SettingsStore`.
struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var ai: AIContentStore
    @Environment(\.dismiss) private var dismiss

    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Form {
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
                    LabeledContent("轉錄模型") {
                        TextField(SettingsStore.defaultTranscriptionModel, text: $settings.transcriptionModel)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
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

                Section {
                    Button("清除所有 AI 內容", role: .destructive) {
                        showClearConfirm = true
                    }
                } footer: {
                    Text("刪除已儲存的逐字稿與 AI 講義。")
                }
            }
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
        }
    }
}
