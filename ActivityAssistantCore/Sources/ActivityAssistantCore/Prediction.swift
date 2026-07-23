import Foundation

/// One prediction returned by the Assignment 2 ImageBind service.
public struct Prediction: Sendable, Equatable {
    public let activity: Activity
    /// Softmax probability of `activity`, in 0...1.
    public let confidence: Double
    /// Full distribution over the four activities, highest first.
    public let scores: [(activity: Activity, score: Double)]
    /// Which modalities the service actually used. Vision is always present;
    /// audio only when the app sent a clip and the service consumed it.
    public let modalities: Set<Modality>
    /// Server-side inference time, when the service reports it.
    public let latencyMilliseconds: Int?

    public enum Modality: String, Sendable, Codable {
        case vision
        case audio
    }

    public init(
        activity: Activity,
        confidence: Double,
        scores: [(activity: Activity, score: Double)],
        modalities: Set<Modality>,
        latencyMilliseconds: Int?
    ) {
        self.activity = activity
        self.confidence = confidence
        self.scores = scores
        self.modalities = modalities
        self.latencyMilliseconds = latencyMilliseconds
    }

    /// The runner-up, used by the report to show how separated the top-2 were.
    public var runnerUp: (activity: Activity, score: Double)? {
        scores.first { $0.activity != activity }
    }

    /// Gap between top-1 and top-2. A small margin with a high top-1 score is
    /// the signature of the confusion case documented in the report
    /// (standing vs. sitting from a chest-height camera).
    public var margin: Double {
        guard let runnerUp else { return confidence }
        return confidence - runnerUp.score
    }

    public static func == (lhs: Prediction, rhs: Prediction) -> Bool {
        lhs.activity == rhs.activity
            && lhs.confidence == rhs.confidence
            && lhs.modalities == rhs.modalities
            && lhs.latencyMilliseconds == rhs.latencyMilliseconds
            && lhs.scores.count == rhs.scores.count
            && zip(lhs.scores, rhs.scores).allSatisfy {
                $0.activity == $1.activity && $0.score == $1.score
            }
    }
}

public extension Prediction {
    /// Parse a `/predict` response body. Accepts both the native and the
    /// Gradio-wrapped shapes; throws `PredictionError` on anything else.
    static func decode(from data: Data) throws -> Prediction {
        try PredictionResponse.decode(from: data).validated()
    }
}

// MARK: - Wire format

/// Raw JSON body of a successful `/predict` response.
///
/// Two shapes are accepted because Assignment 2 could be served either way:
///
///   * **Native** — what `imagebind-service/app.py` returns:
///     `{"label": "walking", "confidence": 0.87, "scores": {...}, ...}`
///   * **Gradio** — what a bare Colab + Gradio `/run/predict` returns, which
///     wraps the same object in a one-element `data` array:
///     `{"data": [{"label": "walking", ...}]}`
///
/// Decoding tries native first and falls back to unwrapping `data`.
struct PredictionResponse: Decodable {
    let label: String
    let confidence: Double
    let scores: [String: Double]
    let modalities: [String]?
    let latencyMs: Int?

    private enum CodingKeys: String, CodingKey {
        case label, confidence, scores, modalities
        case latencyMs = "latency_ms"
    }

    private struct GradioEnvelope: Decodable {
        let data: [PredictionResponse]
    }

    static func decode(from data: Data) throws -> PredictionResponse {
        let decoder = JSONDecoder()
        if let native = try? decoder.decode(PredictionResponse.self, from: data) {
            return native
        }

        let envelope: GradioEnvelope
        do {
            envelope = try decoder.decode(GradioEnvelope.self, from: data)
        } catch {
            // Every failure leaves as a `PredictionError`, never as a raw
            // `DecodingError`. This is not tidiness: an expired Colab tunnel
            // serves an HTML error page with a 200 status, which is the single
            // most common bad response in practice, and the flow needs it to
            // land on the retry frame rather than escaping as an opaque type.
            throw PredictionError.malformedResponse(summarize(data))
        }

        guard let first = envelope.data.first else {
            throw PredictionError.malformedResponse("Gradio `data` array was empty")
        }
        return first
    }

    /// A short, loggable description of a body we could not parse.
    private static func summarize(_ data: Data) -> String {
        guard let text = String(data: data.prefix(160), encoding: .utf8) else {
            return "not JSON (\(data.count) bytes of binary)"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "empty response body" }
        return "not JSON: \(trimmed.prefix(80))"
    }

    /// Validate and lift the wire object into a domain `Prediction`.
    func validated() throws -> Prediction {
        guard let activity = Activity(serviceLabel: label) else {
            throw PredictionError.unknownLabel(label)
        }
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw PredictionError.malformedResponse(
                "confidence \(confidence) outside 0...1"
            )
        }

        // Drop score keys we do not recognise rather than failing: a service
        // that adds a fifth diagnostic key should not break the display flow.
        let parsed = scores.compactMap { key, value -> (Activity, Double)? in
            guard let activity = Activity(serviceLabel: key), value.isFinite else {
                return nil
            }
            return (activity, value)
        }
        guard !parsed.isEmpty else {
            throw PredictionError.malformedResponse("no recognisable keys in `scores`")
        }

        let sorted = parsed
            .sorted { ($0.1, $0.0.rawValue) > ($1.1, $1.0.rawValue) }
            .map { (activity: $0.0, score: $0.1) }

        let usedModalities = Set(
            (modalities ?? ["vision"]).compactMap(Prediction.Modality.init(rawValue:))
        )

        return Prediction(
            activity: activity,
            confidence: confidence,
            scores: sorted,
            modalities: usedModalities.isEmpty ? [.vision] : usedModalities,
            latencyMilliseconds: latencyMs
        )
    }
}

// MARK: - Errors

/// Every way the prediction round-trip can fail, in the granularity the
/// display flow needs. Each case maps to exactly one on-glasses message.
public enum PredictionError: Error, Equatable, Sendable {
    /// No route to the service — phone off Wi-Fi, Colab tunnel closed.
    case unreachable(String)
    /// Service answered but took longer than the configured budget.
    case timedOut(seconds: Double)
    /// Non-2xx status.
    case httpStatus(code: Int, body: String)
    /// 2xx but the body was not a shape we understand.
    case malformedResponse(String)
    /// A label outside the four-class set.
    case unknownLabel(String)
    /// The glasses camera returned no frame.
    case captureFailed(String)

    /// Short line for the HUD. The Ray-Ban Display is glanceable, not a
    /// console: every message here is one short sentence with no error codes.
    public var glassesMessage: String {
        switch self {
        case .unreachable:
            "Can't reach the server"
        case .timedOut:
            "Server took too long"
        case .httpStatus:
            "Server error"
        case .malformedResponse, .unknownLabel:
            "Unexpected reply"
        case .captureFailed:
            "Camera didn't capture"
        }
    }

    /// Full detail for the phone-side log and the README's troubleshooting
    /// table. Never shown on the glasses.
    public var diagnosticDescription: String {
        switch self {
        case .unreachable(let detail):
            "Unreachable: \(detail)"
        case .timedOut(let seconds):
            "Timed out after \(seconds)s"
        case .httpStatus(let code, let body):
            "HTTP \(code): \(body.prefix(200))"
        case .malformedResponse(let detail):
            "Malformed response: \(detail)"
        case .unknownLabel(let label):
            "Unknown label from service: \"\(label)\""
        case .captureFailed(let detail):
            "Capture failed: \(detail)"
        }
    }
}
