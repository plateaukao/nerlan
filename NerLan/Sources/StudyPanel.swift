import Combine
import Foundation
import UIKit

/// Tracks which study artifact is open in the iPad detail (right) panel:
/// a transcript, an AI handout, or a PDF handout (講義). On compact width
/// (iPhone, which is portrait-locked) this stays unused and the artifacts are
/// shown as sheets instead. Injected as an `environmentObject` like the other
/// app-state singletons so the action buttons — wherever they live — can drive
/// the panel.
final class StudyPanel: ObservableObject {
    static let shared = StudyPanel()

    enum Item: Equatable {
        case transcript(EpisodeRecord)
        case handout(EpisodeRecord)
        case attachment(EpisodeRecord)
    }

    @Published var item: Item?

    private init() {}

    func clear() { item = nil }

    /// Whether to show study content in the side panel (iPad / Mac) vs. a sheet
    /// (iPhone, portrait-locked). Decided by device idiom rather than size class:
    /// size class is reported as `.compact` inside an iPad form sheet (the
    /// player) and would route the AI/handout buttons back to a sheet there.
    /// `.mac` is included for Mac Catalyst's "Optimize for Mac" idiom (the
    /// "Scaled to match iPad" idiom already reports `.pad`); the two-pane layout
    /// reads well in a desktop window either way.
    static var usesSidePanel: Bool {
        [.pad, .mac].contains(UIDevice.current.userInterfaceIdiom)
    }
}
