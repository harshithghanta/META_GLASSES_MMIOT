import Foundation

/// One screenful of content destined for the Ray-Ban Display.
///
/// This is deliberately a *description*, not a view: the core package decides
/// what the glasses should say, and the DAT layer in the iOS app decides how
/// to draw it. That split is what lets the eight test trials assert on exact
/// on-glasses copy without a headset attached.
///
/// The layout budget below was chosen for the monocular HUD, which shows a
/// small amount of text comfortably and truncates aggressively past that.
public struct DisplayFrame: Sendable, Equatable {
    /// Big line. One or two words.
    public let headline: String
    /// Optional supporting line under the headline.
    public let detail: String?
    /// Actions offered to the wearer, in order. The HUD realistically fits
    /// two; the engine never emits more.
    public let actions: [Action]
    /// Drives tint and, on the phone mirror, the progress spinner.
    public let tone: Tone

    /// Hard character budgets for the HUD. Text is truncated to these before
    /// it ever reaches the display API, so a long label can't push the
    /// action buttons off-screen.
    public enum Budget {
        public static let headline = 22
        public static let detail = 34
        public static let maxActions = 2
    }

    public enum Tone: String, Sendable, Equatable {
        case neutral   // Ready
        case working   // Analyzing
        case success   // Confident result
        case caution   // Low-confidence result
        case failure   // Endpoint or capture error
    }

    public struct Action: Sendable, Equatable, Identifiable {
        public let id: Intent
        public let title: String

        public init(id: Intent, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// The only things a wearer can ask the app to do. Kept tiny on purpose —
    /// each maps to one tap target on the glasses.
    public enum Intent: String, Sendable, Equatable {
        case analyze
        case tryAgain
        case dismiss
    }

    public init(headline: String, detail: String? = nil, actions: [Action] = [], tone: Tone = .neutral) {
        self.headline = DisplayFrame.truncate(headline, to: Budget.headline)
        self.detail = detail.map { DisplayFrame.truncate($0, to: Budget.detail) }
        self.actions = Array(actions.prefix(Budget.maxActions))
        self.tone = tone
    }

    /// Truncation that cuts on a word boundary when it can, so the HUD shows
    /// "Can't reach the…" rather than "Can't reach the ser…".
    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let hardCut = text.prefix(limit - 1)
        if let lastSpace = hardCut.lastIndex(of: " "), hardCut.distance(from: hardCut.startIndex, to: lastSpace) > limit / 2 {
            return hardCut[..<lastSpace] + "…"
        }
        return hardCut + "…"
    }
}
