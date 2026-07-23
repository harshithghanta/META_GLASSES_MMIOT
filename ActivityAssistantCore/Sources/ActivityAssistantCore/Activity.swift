import Foundation

/// The four activities the Assignment 2 ImageBind model was fine-tuned on.
///
/// The endpoint returns labels as lowercase strings.  We keep the enum closed
/// because the display flow needs a guaranteed-short human label and a glyph
/// for every case — an unknown label coming back from the service is treated
/// as a protocol error rather than silently rendered.
public enum Activity: String, CaseIterable, Sendable, Codable {
    case walking
    case running
    case sitting
    case standing

    /// Label as shown on the glasses. Kept to a single short word: the
    /// Ray-Ban Display is a small monocular HUD and long strings wrap badly.
    public var displayName: String {
        switch self {
        case .walking: "Walking"
        case .running: "Running"
        case .sitting: "Sitting"
        case .standing: "Standing"
        }
    }

    /// Single character shown next to the label. Emoji render on the HUD and
    /// give a glanceable cue that survives being read out of focus.
    public var glyph: String {
        switch self {
        case .walking: "🚶"
        case .running: "🏃"
        case .sitting: "🪑"
        case .standing: "🧍"
        }
    }

    /// Tolerant parse: the service has been seen to return `"Walking"`,
    /// `"walking"` and `"a photo of a person walking"` depending on whether the
    /// zero-shot prompt template was stripped server-side. Accept all three.
    public init?(serviceLabel raw: String) {
        let normalized = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = Activity(rawValue: normalized) {
            self = exact
            return
        }
        // Prompt-template form: find the activity word inside the sentence.
        let match = Activity.allCases.first { normalized.contains($0.rawValue) }
        guard let match else { return nil }
        self = match
    }
}
