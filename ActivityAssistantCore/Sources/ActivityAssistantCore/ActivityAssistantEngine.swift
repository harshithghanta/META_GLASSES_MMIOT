import Foundation

/// Drives the Ready → Analyzing → Result / Retry loop.
///
/// The engine owns no UI and no transport: it takes a `WearableDevice` and an
/// `ImageBindClient` and turns wearer intents into `DisplayFrame`s. That makes
/// the required demo flow and the eight-trial laptop run the same code path.
@MainActor
public final class ActivityAssistantEngine {
    public private(set) var state: FlowState = .ready {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// Latest frame handed to the device. Kept so the phone-side mirror and
    /// the tests can assert on exactly what the wearer saw.
    public private(set) var currentFrame: DisplayFrame

    /// Trial log for Task 5, in order.
    public private(set) var trials: [TrialRecord] = []

    /// Set by the iOS view model to refresh SwiftUI, and by tests to record
    /// the full state sequence.
    public var onStateChange: (@MainActor (FlowState) -> Void)?

    /// Ground truth for the trial currently being run. The harness sets this
    /// before each labelled trial; it is `nil` during a live demo.
    public var pendingGroundTruth: Activity?

    private let device: any WearableDevice
    private let client: any ImageBindClient
    private let configuration: ServiceConfiguration
    private let appName: String
    private let clock: @Sendable () -> Double

    /// In-flight analysis, so a second tap can't start a parallel run.
    private var activeRun: Task<Void, Never>?

    /// Monotonic id of the current run. See `startAnalysis` for why the plain
    /// `activeRun == nil` guard was not enough on its own.
    private var runGeneration = 0

    public init(
        device: any WearableDevice,
        client: any ImageBindClient,
        configuration: ServiceConfiguration,
        appName: String = "Activity Assistant",
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.device = device
        self.client = client
        self.configuration = configuration
        self.appName = appName
        self.clock = clock
        self.currentFrame = DisplayFrame(
            headline: appName,
            detail: "Tap Analyze to start",
            actions: [.init(id: .analyze, title: "Analyze")],
            tone: .neutral
        )
    }

    // MARK: - Lifecycle

    /// Renders the Ready frame and begins consuming wearer intents. Returns
    /// when the intent stream finishes (device disconnected or app torn down).
    public func run() async {
        await present(readyFrame())
        for await intent in device.intents() {
            handle(intent)
        }
    }

    /// Handles one intent. Separate from `run()` so tests can drive the flow
    /// without standing up a stream.
    public func handle(_ intent: DisplayFrame.Intent) {
        switch intent {
        case .analyze, .tryAgain:
            startAnalysis()
        case .dismiss:
            cancelActiveRun()
            state = .ready
            Task { await self.present(self.readyFrame()) }
        }
    }

    /// Runs one full capture → predict → render cycle and returns when the
    /// terminal frame is on the HUD. The harness awaits this; the UI doesn't.
    @discardableResult
    public func analyzeOnce() async -> FlowState {
        startAnalysis()
        await activeRun?.value
        return state
    }

    private func startAnalysis() {
        // Ignore taps while a run is in flight. Double-taps on the HUD are
        // common — the temple touchpad registers a light brush as a tap — and
        // firing two captures would show the wearer a result for a frame they
        // didn't pose for.
        guard activeRun == nil else { return }

        // Every run carries a generation. Without it, a run that was cancelled
        // mid-flight still reaches its own cleanup and sets `activeRun = nil` —
        // but by then a *newer* run may own that slot, so clearing it defeats
        // the double-tap guard entirely and two analyses proceed in parallel.
        // The generation lets late work recognise that it no longer owns the
        // engine and quietly stand down.
        runGeneration &+= 1
        let generation = runGeneration
        let groundTruth = pendingGroundTruth
        activeRun = Task { [weak self] in
            await self?.performAnalysis(groundTruth: groundTruth, generation: generation)
            self?.finishRun(generation: generation)
        }
    }

    /// Abandons the in-flight run and invalidates it, so nothing it does after
    /// this point touches the HUD, the trial log, or `activeRun`.
    private func cancelActiveRun() {
        activeRun?.cancel()
        activeRun = nil
        runGeneration &+= 1
    }

    /// Releases the run slot, but only if this run still owns it.
    private func finishRun(generation: Int) {
        guard generation == runGeneration else { return }
        activeRun = nil
    }

    /// True while `generation` is still the run the engine is listening to.
    /// Checked before every side effect: a stale or cancelled run must not
    /// repaint the HUD, append a trial, or speak.
    private func isCurrent(_ generation: Int) -> Bool {
        generation == runGeneration && !Task.isCancelled
    }

    // MARK: - The pipeline

    private func performAnalysis(groundTruth: Activity?, generation: Int) async {
        let startedAt = clock()
        let deviceName = await device.deviceDescription

        // 1. Frame — required.
        guard await advance(to: .analyzing(.capturingFrame), generation: generation) else { return }

        let frame: CapturedFrame
        do {
            frame = try await device.captureFrame()
        } catch let error as PredictionError {
            await finish(.failed(error), groundTruth: groundTruth, device: deviceName,
                         usedAudio: false, startedAt: startedAt, generation: generation)
            return
        } catch {
            await finish(.failed(.captureFailed(error.localizedDescription)),
                         groundTruth: groundTruth, device: deviceName,
                         usedAudio: false, startedAt: startedAt, generation: generation)
            return
        }

        // 2. Audio — optional. A device with no mic access must still produce
        // a vision-only prediction, so a nil clip is never an error.
        var audio: CapturedAudio?
        if configuration.audioEnabled {
            guard await advance(to: .analyzing(.capturingAudio), generation: generation) else { return }
            audio = await device.captureAudio(seconds: configuration.audioWindowSeconds)
        }

        // 3. Predict — off-glasses, on the Assignment 2 service.
        guard await advance(to: .analyzing(.uploading), generation: generation) else { return }

        do {
            let prediction = try await client.predict(frame: frame, audio: audio)
            let terminal: FlowState = prediction.confidence >= configuration.confidenceFloor
                ? .result(prediction)
                : .lowConfidence(prediction)
            await finish(terminal, groundTruth: groundTruth, device: deviceName,
                         usedAudio: audio != nil, startedAt: startedAt, generation: generation)
        } catch let error as PredictionError {
            await finish(.failed(error), groundTruth: groundTruth, device: deviceName,
                         usedAudio: audio != nil, startedAt: startedAt, generation: generation)
        } catch {
            await finish(.failed(.unreachable(error.localizedDescription)),
                         groundTruth: groundTruth, device: deviceName,
                         usedAudio: audio != nil, startedAt: startedAt, generation: generation)
        }
    }

    /// Moves to an intermediate state, or reports that this run has been
    /// superseded. Returning `false` is the signal to unwind without touching
    /// anything: the wearer has already cancelled, and the Ready frame they are
    /// looking at must not be overwritten by a run they abandoned.
    private func advance(to next: FlowState, generation: Int) async -> Bool {
        guard isCurrent(generation) else { return false }
        state = next
        await present(frame(for: next))
        return true
    }

    private func finish(
        _ terminal: FlowState,
        groundTruth: Activity?,
        device deviceName: String,
        usedAudio: Bool,
        startedAt: Double,
        generation: Int
    ) async {
        // The last and most important gate. Previously a run cancelled during
        // the upload still landed here on completion: it repainted the HUD with
        // a result, appended a trial the wearer never asked for, and spoke the
        // answer aloud — all after the flow had visibly returned to Ready.
        guard isCurrent(generation) else { return }

        state = terminal
        await present(frame(for: terminal))

        let outcome: TrialRecord.Outcome
        switch terminal {
        case .result(let prediction): outcome = .predicted(prediction)
        case .lowConfidence(let prediction): outcome = .lowConfidence(prediction)
        case .failed(let error): outcome = .failed(error)
        case .ready, .analyzing: return  // not a terminal state; nothing to log
        }

        trials.append(
            TrialRecord(
                index: trials.count + 1,
                groundTruth: groundTruth,
                outcome: outcome,
                device: deviceName,
                usedAudio: usedAudio,
                totalSeconds: clock() - startedAt
            )
        )

        // Speaking is opt-in and only for a result we trust — announcing a
        // guess we're about to caveat would be worse than staying quiet.
        if case .result(let prediction) = terminal {
            await device.speak("\(prediction.activity.displayName)")
        }
    }

    // MARK: - Frame construction

    private func readyFrame() -> DisplayFrame {
        DisplayFrame(
            headline: appName,
            detail: "Tap Analyze to start",
            actions: [.init(id: .analyze, title: "Analyze")],
            tone: .neutral
        )
    }

    private func analyzingFrame(_ stage: FlowState.Stage) -> DisplayFrame {
        DisplayFrame(
            headline: stage.hudDetail,
            detail: nil,
            // No Try Again mid-run: the only useful action while capturing is
            // to back out, and offering a retry here invites the double-tap
            // that `startAnalysis` already guards against.
            actions: [.init(id: .dismiss, title: "Cancel")],
            tone: .working
        )
    }

    private func frame(for state: FlowState) -> DisplayFrame {
        switch state {
        case .ready:
            readyFrame()

        case .analyzing(let stage):
            analyzingFrame(stage)

        case .result(let prediction):
            DisplayFrame(
                headline: "\(prediction.activity.glyph) \(prediction.activity.displayName)",
                detail: "\(Self.percent(prediction.confidence)) confident",
                actions: [.init(id: .tryAgain, title: "Try Again")],
                tone: .success
            )

        case .lowConfidence(let prediction):
            // Name the best guess but frame it as a guess, and lead with the
            // action. A wearer glancing at this should retry, not believe it.
            DisplayFrame(
                headline: "Not sure",
                detail: "Maybe \(prediction.activity.displayName) · retry",
                actions: [.init(id: .tryAgain, title: "Try Again")],
                tone: .caution
            )

        case .failed(let error):
            DisplayFrame(
                headline: error.glassesMessage,
                detail: "Tap to retry",
                actions: [.init(id: .tryAgain, title: "Try Again")],
                tone: .failure
            )
        }
    }

    private func present(_ frame: DisplayFrame) async {
        currentFrame = frame
        await device.present(frame)
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
