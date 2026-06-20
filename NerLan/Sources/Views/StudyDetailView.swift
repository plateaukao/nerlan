import SwiftUI

/// The iPad right-hand panel. Shows whatever study artifact is currently open —
/// transcript, AI handout, or PDF handout — reusing the very same views that are
/// shown as sheets on iPhone, just with their close button wired to clear the
/// panel instead of dismissing a sheet. A placeholder fills the panel when
/// nothing is open.
struct StudyDetailView: View {
    @EnvironmentObject var study: StudyPanel
    @EnvironmentObject var ai: AIContentStore

    var body: some View {
        Group {
            switch study.item {
            case .transcript(let record):
                TranscriptView(record: record,
                               text: ai.transcriptText(record.id) ?? "",
                               cues: ai.transcriptCues(record.id),
                               onClose: { study.clear() })
                    .id("transcript-\(record.id)")
            case .shadow(let record):
                TranscriptView(record: record,
                               text: ai.transcriptText(record.id) ?? "",
                               cues: ai.transcriptCues(record.id),
                               startShadowing: true,
                               onClose: { study.clear() })
                    .id("shadow-\(record.id)")
            case .handout(let record):
                HandoutView(html: ai.handoutHTML(record.id) ?? "",
                            onClose: { study.clear() })
                    .id("handout-\(record.id)")
            case .attachment(let record):
                AttachmentView(title: record.title,
                               attachments: record.pdfAttachments,
                               onClose: { study.clear() })
                    .id("attachment-\(record.id)")
            case nil:
                ContentUnavailableView("逐字稿與講義",
                                       systemImage: "text.book.closed",
                                       description: Text("點選單集的逐字稿、AI 講義或講義，內容會顯示在這裡。"))
            }
        }
        // Rebuild cleanly when switching episodes (handled by the .id above).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
