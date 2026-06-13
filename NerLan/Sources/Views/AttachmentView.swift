import PDFKit
import SwiftUI

/// Reader for an episode's PDF handout (講義). Shown in a sheet over the player
/// so the user can read along while the episode keeps playing. Prefers the
/// downloaded copy; otherwise fetches the PDF on demand.
struct AttachmentView: View {
    let title: String
    let attachments: [Attachment]

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Attachment?

    private var current: Attachment? { selected ?? attachments.first }

    var body: some View {
        NavigationStack {
            Group {
                if let attachment = current {
                    PDFAttachmentReader(attachment: attachment)
                        .id(attachment.id)
                } else {
                    ContentUnavailableView("沒有附件", systemImage: "doc")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("關閉") { dismiss() }
                }
                // Let the user switch between handouts when an episode has several.
                if attachments.count > 1, let current {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ForEach(attachments) { attachment in
                                Button {
                                    selected = attachment
                                } label: {
                                    if attachment.id == current.id {
                                        Label(attachment.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(attachment.displayName)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                }
            }
        }
    }
}

/// Loads and renders a single PDF attachment.
private struct PDFAttachmentReader: View {
    let attachment: Attachment

    @EnvironmentObject var downloads: DownloadManager
    @State private var document: PDFDocument?
    @State private var failed = false

    var body: some View {
        Group {
            if let document {
                PDFKitView(document: document)
                    .ignoresSafeArea(edges: .bottom)
            } else if failed {
                ContentUnavailableView(
                    "無法載入附件",
                    systemImage: "doc.questionmark",
                    description: Text(attachment.displayName))
            } else {
                ProgressView("載入中…")
            }
        }
        .task(id: attachment.id) { await load() }
    }

    private func load() async {
        if let local = downloads.localAttachmentURL(attachment),
           let doc = PDFDocument(url: local) {
            document = doc
            return
        }
        guard let url = attachment.remoteURL else { failed = true; return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let doc = PDFDocument(data: data) {
                document = doc
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }
}

/// Thin wrapper around PDFKit's `PDFView`.
private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
    }
}
