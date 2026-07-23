import Foundation

/// The five states named in the assignment's Required Interaction section,
/// with low-confidence split out from hard failure because the two need
/// different copy on the HUD: one has an answer we don't trust, the other has
/// no answer at all.
public enum FlowState: Sendable, Equatable {
    case ready
    case analyzing(Stage)
    case result(Prediction)
    case lowConfidence(Prediction)
    case failed(PredictionError)

    /// Sub-steps of Analyzing. Shown on the HUD so a slow trial reads as
    /// "still working, here's on what" rather than a stalled spinner — the
    /// difference between capture latency and a dead endpoint is visible to
    /// the wearer without looking at the phone.
    public enum Stage: String, Sendable, Equatable {
        case capturingFrame
        case capturingAudio
        case uploading

        public var hudDetail: String {
            switch self {
            case .capturingFrame: "Capturing…"
            case .capturingAudio: "Listening…"
            case .uploading: "Analyzing…"
            }
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .result, .lowConfidence, .failed: true
        case .ready, .analyzing: false
        }
    }
}

/// One row of the eight-trial test log required by Task 5.
public struct TrialRecord: Sendable, Equatable {
    public let index: Int
    public let groundTruth: Activity?
    public let outcome: Outcome
    public let device: String
    public let usedAudio: Bool
    /// End-to-end seconds from the analyze intent to the terminal frame.
    public let totalSeconds: Double

    public enum Outcome: Sendable, Equatable {
        case predicted(Prediction)
        case lowConfidence(Prediction)
        case failed(PredictionError)
    }

    public init(
        index: Int,
        groundTruth: Activity?,
        outcome: Outcome,
        device: String,
        usedAudio: Bool,
        totalSeconds: Double
    ) {
        self.index = index
        self.groundTruth = groundTruth
        self.outcome = outcome
        self.device = device
        self.usedAudio = usedAudio
        self.totalSeconds = totalSeconds
    }

    /// `true` only for a confident prediction that matched the labelled truth.
    /// A low-confidence hit counts as a miss for accuracy but is reported
    /// separately, since correctly *declining* to answer is the behaviour the
    /// fallback requirement is asking for.
    public var isCorrect: Bool {
        guard let groundTruth, case .predicted(let prediction) = outcome else { return false }
        return prediction.activity == groundTruth
    }
}
