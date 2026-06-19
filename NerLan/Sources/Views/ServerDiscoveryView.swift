import SwiftUI

/// A sheet that browses the local network for whisperASR transcription servers
/// (Bonjour `_whisperasr._tcp`) and lets the user pick one to fill the custom
/// transcription server URL. Presented from `SettingsView`'s 自訂 section.
struct ServerDiscoveryView: View {
    @StateObject private var browser = BonjourBrowser()
    @Environment(\.dismiss) private var dismiss
    let onSelect: (BonjourBrowser.Server) -> Void

    var body: some View {
        NavigationStack {
            List {
                if browser.servers.isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("搜尋中…").foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("在區域網路上搜尋 whisperASR 轉錄伺服器（_whisperasr._tcp）。請確認伺服器已啟用 API 服務並開啟區域網路存取，且兩台裝置在同一個 Wi-Fi。")
                    }
                } else {
                    Section("找到的伺服器") {
                        ForEach(browser.servers) { server in
                            Button {
                                onSelect(server)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name)
                                        .foregroundStyle(.primary)
                                    Text(server.baseURL)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("搜尋轉錄伺服器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if browser.isSearching { ProgressView() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear { browser.start() }
            .onDisappear { browser.stop() }
        }
    }
}
