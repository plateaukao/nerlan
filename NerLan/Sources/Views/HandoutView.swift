import SwiftUI
import WebKit

/// Renders the saved HTML handout in a webview, shown in a sheet over the player
/// so the user can read along while the episode keeps playing.
struct HandoutView: View {
    let title: String
    let html: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HandoutWebView(html: html)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("關閉") { dismiss() }
                    }
                }
        }
    }
}

/// Thin wrapper around `WKWebView` that loads a self-contained HTML string once.
private struct HandoutWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loadedHTML: String? }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        view.scrollView.backgroundColor = .systemBackground
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        view.loadHTMLString(html, baseURL: nil)
    }
}
