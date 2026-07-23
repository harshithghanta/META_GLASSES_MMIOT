import Foundation

/// A deterministic stand-in for the glasses.
///
/// Used by the unit tests and by `scripts/run_trials.swift`, which produces
/// the eight-trial table in `docs/TEST_RESULTS.md` without hardware. The real
/// `DATWearableDevice` and `MockDeviceKitWearable` live in the iOS app target
/// because they import the Device Access Toolkit; this one is pure Foundation
/// so it builds and runs anywhere.
public actor ScriptedWearableDevice: WearableDevice {
    /// What the next `captureFrame()` should do.
    public enum FrameScript: Sendable {
        case success(CapturedFrame)
        case failure(PredictionError)
    }

    private var frameScripts: [FrameScript]
    private var audioScript: CapturedAudio?
    private let name: String
    private let connected: Bool

    /// Every frame the engine asked us to show, in order — the assertion
    /// surface for "what did the wearer actually see".
    public private(set) var presentedFrames: [DisplayFrame] = []
    public private(set) var spokenLines: [String] = []

    private nonisolated let intentStream: AsyncStream<DisplayFrame.Intent>
    private nonisolated let intentContinuation: AsyncStream<DisplayFrame.Intent>.Continuation

    public init(
        frames: [FrameScript] = [.success(.sample())],
        audio: CapturedAudio? = .sample(),
        name: String = "Scripted device",
        connected: Bool = true
    ) {
        self.frameScripts = frames
        self.audioScript = audio
        self.name = name
        self.connected = connected
        (intentStream, intentContinuation) = AsyncStream.makeStream()
    }

    public var isConnected: Bool { connected }
    public var deviceDescription: String { name }

    public func captureFrame() async throws -> CapturedFrame {
        // Reuse the last script once exhausted so a harness can run more
        // trials than it scripted without falling off the end.
        let script = frameScripts.count > 1 ? frameScripts.removeFirst() : (frameScripts.first ?? .success(.sample()))
        switch script {
        case .success(let frame): return frame
        case .failure(let error): throw error
        }
    }

    public func captureAudio(seconds: Double) async -> CapturedAudio? {
        audioScript
    }

    public func present(_ frame: DisplayFrame) async {
        presentedFrames.append(frame)
    }

    public nonisolated func intents() -> AsyncStream<DisplayFrame.Intent> {
        intentStream
    }

    public func speak(_ text: String) async {
        spokenLines.append(text)
    }

    // MARK: - Driving the fake from a test

    public nonisolated func send(_ intent: DisplayFrame.Intent) {
        intentContinuation.yield(intent)
    }

    public nonisolated func endIntents() {
        intentContinuation.finish()
    }

    public func setFrameScripts(_ scripts: [FrameScript]) {
        frameScripts = scripts
    }

    public func setAudio(_ audio: CapturedAudio?) {
        audioScript = audio
    }
}

// MARK: - Fixtures

public extension CapturedFrame {
    /// A tiny but structurally valid JPEG (SOI + APP0 + EOI). Enough for the
    /// multipart body to be well-formed; the scripted client never decodes it.
    static func sample(captureDuration: Double = 0.18) -> CapturedFrame {
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]
        bytes += Array("JFIF".utf8) + [0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]
        bytes += [0xFF, 0xD9]
        return CapturedFrame(
            jpegData: Data(bytes),
            width: 1280,
            height: 960,
            captureDuration: captureDuration
        )
    }
}

public extension CapturedAudio {
    /// A 16 kHz mono WAV header with no PCM payload — valid enough to post.
    static func sample(seconds: Double = 2.0, fromPhone: Bool = false) -> CapturedAudio {
        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(contentsOf: [0x24, 0x00, 0x00, 0x00])
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        header.append(contentsOf: [0x10, 0x00, 0x00, 0x00])   // subchunk size 16
        header.append(contentsOf: [0x01, 0x00, 0x01, 0x00])   // PCM, mono
        header.append(contentsOf: [0x80, 0x3E, 0x00, 0x00])   // 16000 Hz
        header.append(contentsOf: [0x00, 0x7D, 0x00, 0x00])   // byte rate
        header.append(contentsOf: [0x02, 0x00, 0x10, 0x00])   // align, 16-bit
        header.append(contentsOf: Array("data".utf8))
        header.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        return CapturedAudio(
            wavData: header,
            durationSeconds: seconds,
            usedPhoneMicrophone: fromPhone
        )
    }
}

/// An `ImageBindClient` that replays a fixed script instead of hitting the
/// network — the other half of a hardware-free trial run.
public actor ScriptedImageBindClient: ImageBindClient {
    public enum Response: Sendable {
        case prediction(Prediction)
        case failure(PredictionError)
    }

    private var responses: [Response]
    /// Simulated round-trip, so trial timings in the log look like real ones.
    private let latency: Double

    public private(set) var requestCount = 0
    public private(set) var lastRequestIncludedAudio = false

    public init(responses: [Response], latency: Double = 0) {
        self.responses = responses
        self.latency = latency
    }

    public func predict(frame: CapturedFrame, audio: CapturedAudio?) async throws -> Prediction {
        requestCount += 1
        lastRequestIncludedAudio = audio != nil
        if latency > 0 {
            try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
        }
        let response = responses.count > 1 ? responses.removeFirst() : (responses.first ?? .failure(.unreachable("no script")))
        switch response {
        case .prediction(let prediction): return prediction
        case .failure(let error): throw error
        }
    }
}

public extension Prediction {
    /// Builds a well-formed prediction from a top-1 label and confidence,
    /// spreading the remainder over the other three classes so `scores` always
    /// sums to 1 — the shape the real service returns.
    static func sample(
        _ activity: Activity,
        confidence: Double,
        runnerUp: Activity? = nil,
        modalities: Set<Modality> = [.vision, .audio],
        latencyMilliseconds: Int? = 410
    ) -> Prediction {
        let others = Activity.allCases.filter { $0 != activity }
        let remainder = max(0, 1 - confidence)

        // Below 1/n the request is arithmetically impossible, not merely
        // awkward: the other n-1 classes must absorb 1-c, so at least one of
        // them necessarily outscores the "top" label and the fixture would
        // describe a prediction whose stated label is not its own argmax.
        // Fail loudly rather than emit nonsense a check might then encode.
        precondition(
            confidence > 1.0 / Double(Activity.allCases.count),
            "Prediction.sample needs confidence > \(1.0 / Double(Activity.allCases.count)) "
            + "to keep \(activity.rawValue) the argmax over \(Activity.allCases.count) classes; got \(confidence)"
        )

        var scores: [(activity: Activity, score: Double)] = [(activity, confidence)]

        if let runnerUp, runnerUp != activity {
            // Give the named runner-up 60% of the leftover mass so the margin
            // is a realistic top-2 gap rather than a flat tail — but never
            // more than the top-1 itself. Without that clamp, a low-confidence
            // fixture (0.34 top-1, 0.66 spare) hands the runner-up 0.40 and
            // produces a prediction whose stated label is not the argmax.
            var runnerUpScore = min(remainder * 0.6, confidence * 0.9)
            var rest = max(0, remainder - runnerUpScore) / Double(others.count - 1)

            // Clamping only the runner-up is not enough. Near the 1/n floor the
            // leftover mass is large enough that the *tail* overtakes it — at
            // c = 0.26 the runner-up is capped to 0.234 while each tail class
            // gets 0.253. When that happens the runner-up distinction is
            // meaningless anyway, so spread the remainder evenly.
            if rest > runnerUpScore {
                runnerUpScore = remainder / Double(others.count)
                rest = runnerUpScore
            }

            scores.append((runnerUp, runnerUpScore))
            scores += others.filter { $0 != runnerUp }.map { ($0, rest) }
        } else {
            let each = remainder / Double(others.count)
            scores += others.map { ($0, each) }
        }

        return Prediction(
            activity: activity,
            confidence: confidence,
            scores: scores.sorted { $0.score > $1.score },
            modalities: modalities,
            latencyMilliseconds: latencyMilliseconds
        )
    }
}
