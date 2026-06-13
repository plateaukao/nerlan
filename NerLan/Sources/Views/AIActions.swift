import SwiftUI

/// Shared transcript / AI-handout action button. Shows an idle icon, a spinner
/// while its OpenAI job runs, and opens the saved content in a sheet when ready;
/// tapping when nothing is saved kicks off processing and auto-opens the result.
/// Used in the full player (with a caption) and in list rows (`compact`).
struct AIActionButton: View {
    enum Kind { case transcript, handout }

    let kind: Kind
    let record: EpisodeRecord
    var compact: Bool = false

    @EnvironmentObject var ai: AIContentStore
    @State private var pendingOpen = false
    @State private var showSheet = false
    @State private var showError = false
    @State private var errorText = ""

    private var storeKind: AIContentStore.Kind { kind == .transcript ? .transcript : .handout }
    private var title: String { kind == .transcript ? "逐字稿" : "AI 講義" }

    var body: some View {
        let job = ai.jobState(storeKind, record.id)
        let ready = kind == .transcript ? ai.hasTranscript(record.id) : ai.hasHandout(record.id)
        let running: Bool = { if case .running = job { return true } else { return false } }()
        let failure: String? = { if case .failed(let m) = job { return m } else { return nil } }()

        Button {
            if running { return }
            if let failure { errorText = failure; showError = true; return }
            if ready {
                showSheet = true
            } else {
                pendingOpen = true
                start()
            }
        } label: {
            label(running: running, ready: ready, failed: failure != nil)
        }
        .buttonStyle(.borderless)
        .contextMenu {
            if ready || failure != nil {
                Button {
                    pendingOpen = false
                    ai.regenerate(storeKind, record)
                } label: { Label("重新產生", systemImage: "arrow.clockwise") }
                Button(role: .destructive) {
                    ai.delete(storeKind, record.id)
                } label: { Label("刪除\(title)", systemImage: "trash") }
            }
        }
        .onChange(of: ready) { _, isReady in
            if isReady, pendingOpen { pendingOpen = false; showSheet = true }
        }
        .onChange(of: failure) { _, message in
            if let message, pendingOpen { pendingOpen = false; errorText = message; showError = true }
        }
        .sheet(isPresented: $showSheet) { sheet }
        .alert("處理失敗", isPresented: $showError) {
            Button("重試") { pendingOpen = true; start() }
            Button("好", role: .cancel) {}
        } message: {
            Text(errorText)
        }
    }

    @ViewBuilder
    private func label(running: Bool, ready: Bool, failed: Bool) -> some View {
        if compact {
            icon(running: running, ready: ready, failed: failed)
        } else {
            VStack(spacing: 4) {
                icon(running: running, ready: ready, failed: failed).font(.title3)
                Text(title).font(.caption2)
            }
        }
    }

    @ViewBuilder
    private func icon(running: Bool, ready: Bool, failed: Bool) -> some View {
        if running {
            ProgressView()
        } else {
            Image(systemName: symbol(ready: ready, failed: failed))
                .foregroundStyle(failed ? Color.red : (ready ? Color.accentColor : Color.secondary))
        }
    }

    private func symbol(ready: Bool, failed: Bool) -> String {
        if failed { return "exclamationmark.circle" }
        switch kind {
        case .transcript: return ready ? "captions.bubble.fill" : "captions.bubble"
        case .handout: return ready ? "doc.richtext" : "sparkles"
        }
    }

    @ViewBuilder
    private var sheet: some View {
        switch kind {
        case .transcript:
            TranscriptView(title: record.title, text: ai.transcriptText(record.id) ?? "")
        case .handout:
            HandoutView(title: record.title, html: ai.handoutHTML(record.id) ?? "")
        }
    }

    private func start() {
        switch kind {
        case .transcript: ai.processTranscript(record)
        case .handout: ai.processHandout(record)
        }
    }
}
