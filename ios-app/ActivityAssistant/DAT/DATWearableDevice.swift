import Foundation
import ActivityAssistantCore
import MWDATCore
import MWDATCamera
import MWDATDisplay

/// The required DAT path: Ray-Ban Display camera → this app → ImageBind → HUD.
///
/// Written against **Device Access Toolkit 0.8.0** (`meta-wearables-dat-ios`,
/// products `MWDATCore` / `MWDATCamera` / `MWDATDisplay`). It is not compiled
/// in this repository's automated checks, because building it needs Xcode, a
/// registered Meta app and the SDK's binary xcframeworks — see README
/// "What is and isn't verified". Everything above it in the stack (the flow,
/// the client, the display copy) is covered by `swift run corecheck`, which is
/// exactly why `WearableDevice` exists as a protocol.
///
/// ## The one non-obvious thing about DAT camera capture
///
/// **There is no one-shot photo API.** `capturePhoto` is only valid while a
/// video stream is already running, so a naive implementation would be:
///
///     addStream → start → capturePhoto → stop
///
/// on every tap. Over Bluetooth Classic that startup costs well over a second
/// before the shutter, which the wearer feels on every single Try Again.
///
/// So this class keeps the stream **warm**: it starts on the first capture and
/// stays up for `streamIdleTimeout` afterwards, so back-to-back retries pay
/// the cost once. The stream still tears down on idle rather than being held
/// forever, because a live video stream is the dominant battery draw on the
/// glasses. See `docs/REPORT.md` for the measurement behind the timeout.
actor DATWearableDevice: WearableDevice {

    // MARK: - Tuning

    /// How long the video stream stays up after a capture. Long enough to
    /// cover a wearer reading a result and tapping Try Again (~3 s observed),
    /// short enough not to stream video through an idle demo.
    private let streamIdleTimeout: Duration = .seconds(20)

    /// Ceiling on one `capturePhoto` round-trip before we give up and tell the
    /// wearer the camera didn't fire.
    private let captureTimeout: Duration = .seconds(6)

    /// Lowest quality on purpose. DAT applies per-frame compression over
    /// Bluetooth and automatically degrades a stream it cannot sustain; the
    /// docs are explicit that asking for less yields a *better* looking image
    /// than asking for more and being throttled. 360×640 is also far above
    /// what ImageBind's vision encoder needs after its 224×224 centre crop.
    private let streamConfiguration = StreamConfiguration(
        videoCodec: .raw,
        resolution: .low,
        frameRate: 24
    )

    // MARK: - State

    private let wearables: WearablesInterface
    private var session: DeviceSession?
    private var stream: MWDATCamera.Stream?
    private var display: Display?

    private var listenerTokens: [AnyListenerToken] = []
    private var photoContinuation: CheckedContinuation<Data, Error>?
    private var captureWatchdog: Task<Void, Never>?
    private var streamTeardownTask: Task<Void, Never>?

    /// Guards `warmStream` against a teardown that has already committed.
    /// Cancelling `streamTeardownTask` is not enough on its own: the task may
    /// have passed its `isCancelled` check and be suspended on the actor hop,
    /// in which case it will still stop the stream we are about to capture on.
    private var streamEpoch = 0

    /// Bounds display recovery. The back gesture ends the display session, and
    /// re-attaching can fail on a device that has genuinely gone away — without
    /// a bound, each failure schedules another attempt and leaks a listener.
    private var displayRecoveryAttempts = 0
    private let maxDisplayRecoveryAttempts = 3

    private let audioRecorder: any AudioWindowRecorder
    private let speaker: any ResultSpeaker
    private var connectedDeviceName = "Ray-Ban Display"

    /// Last frame we sent, so we can re-send it after the panel sleeps or the
    /// wearer's two-finger back gesture kills the display session.
    private var lastFrame: DisplayFrame?

    init(audioRecorder: any AudioWindowRecorder, speaker: any ResultSpeaker) throws {
        try Wearables.configure()
        self.wearables = Wearables.shared
        self.audioRecorder = audioRecorder
        self.speaker = speaker
    }

    // MARK: - Connection

    /// Brings up the session, the display, and the camera permission.
    /// Call once after the wearer has registered the app in the Meta AI app.
    func connect() async throws {
        let session = try wearables.createSession(
            deviceSelector: AutoDeviceSelector(wearables: wearables)
        )
        try session.start()

        // `start()` returns before the link is up; wait for the state we need.
        for await state in session.stateStream() where state == .started { break }
        self.session = session

        // Camera permission is granted in the Meta AI app, not by an iOS
        // dialog, and is app-level rather than per-session.
        var status = try await wearables.checkPermissionStatus(.camera)
        if status != .granted {
            status = try await wearables.requestPermission(.camera)
        }
        guard status == .granted else {
            throw PredictionError.captureFailed("camera permission not granted in the Meta AI app")
        }

        // Display attach is deliberately non-fatal. The Mock Device Kit
        // emulates registration, permissions, streaming and capture, but it
        // has **no display emulation** — there is no MockDisplayKit in 0.8.0.
        // On the mock path this throws, and the run continues with the phone
        // mirror standing in for the HUD (see `MirroringWearableDevice`).
        do {
            try await attachDisplay(to: session)
        } catch {
            displayUnavailableReason = String(describing: error)
        }
    }

    /// Non-nil when there is no glasses display to render on, which is the
    /// normal case under the Mock Device Kit. Surfaced in the phone UI so a
    /// demo never silently looks like the HUD is broken.
    private(set) var displayUnavailableReason: String?

    private func attachDisplay(to session: DeviceSession) async throws {
        let display = try session.addDisplay()
        display.start()
        self.display = display

        // The wearer's back gesture (two-finger tap on the temple) ends the
        // *display* session while leaving the device session alive. Without
        // this watcher the HUD would simply go dark and never come back.
        let token = display.statePublisher.listen { [weak self] state in
            guard state == .stopped else { return }
            Task { await self?.recoverDisplay() }
        }
        listenerTokens.append(token)
    }

    private func recoverDisplay() async {
        guard let session else { return }
        guard displayRecoveryAttempts < maxDisplayRecoveryAttempts else {
            displayUnavailableReason = "display session ended and could not be re-attached"
            return
        }
        displayRecoveryAttempts += 1
        display = nil
        do {
            try await attachDisplay(to: session)
            // Only a successful re-attach resets the budget. Resetting
            // unconditionally would let a display that fails immediately on
            // every attach recover forever, leaking a state listener each time.
            displayRecoveryAttempts = 0
        } catch {
            displayUnavailableReason = String(describing: error)
            return
        }
        if let lastFrame {
            await present(lastFrame)
        }
    }

    var isConnected: Bool {
        session != nil
    }

    var deviceDescription: String {
        connectedDeviceName
    }

    // MARK: - Camera

    func captureFrame() async throws -> CapturedFrame {
        let startedAt = ContinuousClock.now
        let stream = try await warmStream()

        // The capture is deliberately NOT wrapped in `withTimeout`. Two
        // separate defects lived in that shape:
        //
        //  1. `withTimeout` takes an `@escaping @Sendable` closure, which does
        //     not inherit this actor's isolation — so `self.photoContinuation =
        //     continuation` inside it was a cross-actor mutation, a hard
        //     compile error even in Swift 5 language mode.
        //  2. Even setting isolation aside, it deadlocked. When the sleep child
        //     threw, the group cancelled and then *awaited* the operation
        //     child, which was suspended on a continuation that cancellation
        //     does not resume. `captureFrame` would never return and the HUD
        //     would sit on "Analyzing…" forever — the exact failure the helper
        //     was supposed to prevent.
        //
        // Instead the deadline is an in-actor watchdog. Both it and the photo
        // callback run on this actor and both clear `photoContinuation`, so
        // exactly one of them can resume it.
        let jpeg: Data = try await withCheckedThrowingContinuation { continuation in
            self.photoContinuation = continuation
            self.captureWatchdog = Task { [captureTimeout] in
                try? await Task.sleep(for: captureTimeout)
                guard !Task.isCancelled else { return }
                // No `await`: a Task created inside an actor method inherits that
                // actor's isolation, so this already runs on the actor. That is
                // what makes the watchdog and deliverPhoto mutually exclusive.
                self.failCapture("no photo within \(captureTimeout)")
            }
            stream.capturePhoto(format: .jpeg)
        }

        scheduleStreamTeardown()

        let elapsed = ContinuousClock.now - startedAt
        return CapturedFrame(
            jpegData: jpeg,
            // `.low` is documented as 360×640 portrait.
            width: 360,
            height: 640,
            // Seconds alone would round a 180 ms capture to 0, which is the
            // only number in the trial log that separates camera latency from
            // network latency.
            captureDuration: Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
        )
    }

    /// Returns a running stream, starting one if the warm window has lapsed.
    private func warmStream() async throws -> MWDATCamera.Stream {
        streamTeardownTask?.cancel()
        streamTeardownTask = nil
        // Invalidate any teardown already past its cancellation check.
        streamEpoch &+= 1

        if let stream { return stream }
        guard let session else {
            throw PredictionError.captureFailed("no device session")
        }

        guard let stream = try? session.addStream(config: streamConfiguration) else {
            throw PredictionError.captureFailed("could not add a camera stream")
        }

        // Register the photo sink *before* starting: DAT delivers captures on
        // a publisher, not as a return value, so the listener is the only way
        // to see the result at all.
        let photoToken = stream.photoDataPublisher.listen { [weak self] photoData in
            Task { await self?.deliverPhoto(photoData.data) }
        }
        listenerTokens.append(photoToken)

        stream.start()
        // NOTE: the iOS SDK exposes observation both as `x.statePublisher.listen { }`
        // (returning a token you must retain) and as an async sequence. The
        // async spelling is what the session guide uses; if `stateStream()`
        // does not resolve against 0.8.0, switch this and the session wait
        // above to the publisher form and await a continuation instead.
        for await state in stream.stateStream() where state == .streaming { break }

        self.stream = stream
        return stream
    }

    /// Delivers a captured photo. A no-op if the watchdog already gave up, so
    /// a late frame can never resume an already-resumed continuation.
    private func deliverPhoto(_ data: Data) {
        captureWatchdog?.cancel()
        captureWatchdog = nil
        photoContinuation?.resume(returning: data)
        photoContinuation = nil
    }

    private func failCapture(_ reason: String) {
        captureWatchdog = nil
        photoContinuation?.resume(throwing: PredictionError.captureFailed(reason))
        photoContinuation = nil
        // A capture that timed out still left a stream running. Without this,
        // a failed trial kept the camera streaming until the app disconnected,
        // which on a battery-constrained device is the worst case to leak.
        scheduleStreamTeardown()
    }

    private func scheduleStreamTeardown() {
        streamTeardownTask?.cancel()
        let epoch = streamEpoch
        streamTeardownTask = Task { [streamIdleTimeout] in
            try? await Task.sleep(for: streamIdleTimeout)
            guard !Task.isCancelled else { return }
            self.tearDownStream(epoch: epoch)
        }
    }

    /// Tears the stream down only if it is still the one this teardown was
    /// scheduled for.
    ///
    /// The `isCancelled` check above happens *outside* the actor. A teardown
    /// that passed it and is suspended on the actor hop cannot be stopped by
    /// `warmStream`'s `cancel()`, so without the epoch it would stop a stream a
    /// capture had just claimed — and `capturePhoto` on a stopped stream never
    /// delivers, stalling the trial until the watchdog fires.
    private func tearDownStream(epoch: Int) {
        guard epoch == streamEpoch else { return }
        stream?.stop()
        session?.removeStream()
        stream = nil
        streamEpoch &+= 1
    }

    // MARK: - Audio

    /// Optional by design. The Device Access Toolkit exposes **no microphone
    /// API**; the glasses mic is reached over Bluetooth HFP through
    /// `AVAudioSession`. If that route isn't available we return `nil` and the
    /// engine falls back to a vision-only prediction rather than failing.
    func captureAudio(seconds: Double) async -> CapturedAudio? {
        await audioRecorder.record(seconds: seconds)
    }

    // MARK: - Display

    func present(_ frame: DisplayFrame) async {
        lastFrame = frame
        guard let display else { return }
        _ = try? await display.send(GlassesDisplayRenderer.tree(for: frame))
    }

    nonisolated func intents() -> AsyncStream<DisplayFrame.Intent> {
        IntentBus.shared.stream()
    }

    // MARK: - Speech

    /// DAT has no text-to-speech API. This routes `AVSpeechSynthesizer` to the
    /// glasses over A2DP, which is mutually exclusive with the HFP route used
    /// for capture — see `GlassesSpeaker` for how the handover is sequenced.
    func speak(_ text: String) async {
        // Check first, disturb the audio route second. The old order released
        // the HFP route on every single result and only then discovered that
        // speech was switched off — so the ~2 s re-acquisition cost that
        // `SPEECH_ENABLED = NO` is supposed to avoid was paid on every trial
        // anyway, and the next trial's audio silently fell back to the phone
        // mic while the route came back up.
        guard speaker.isEnabled else { return }

        let hadRoute = await audioRecorder.releaseRoute()
        await speaker.speak(text)

        // Hand the capture route back, so the next Analyze is not the one that
        // pays for this announcement.
        if hadRoute {
            await audioRecorder.acquireRoute()
        }
    }

    // MARK: - Teardown

    func disconnect() async {
        streamTeardownTask?.cancel()
        streamTeardownTask = nil
        captureWatchdog?.cancel()
        // Never strand a capture that is still waiting on a photo: the caller
        // is suspended on that continuation and would hang for the lifetime of
        // the process.
        failCapture("device disconnected")
        tearDownStream(epoch: streamEpoch)
        display?.stop()
        session?.removeDisplay()
        session?.stop()
        listenerTokens.removeAll()
        IntentBus.shared.finish()
        display = nil
        session = nil
    }
}

// A generic `withTimeout` helper used to live here, racing the operation
// against a sleeping task inside a throwing task group. It is deliberately
// gone rather than merely unused.
//
// It could not work for this job. When the sleep child threw, the group
// cancelled the remaining children and then *awaited* them — and the operation
// child was suspended on a `CheckedContinuation`, which cancellation does not
// resume. The group never unwound, so the timeout never surfaced and the HUD
// stayed on "Analyzing…" forever: the precise failure the helper existed to
// prevent. Leaving it in the file as a general-purpose utility would invite
// the next person to reach for it and reintroduce the hang.
//
// The deadline now lives inside the actor as `captureWatchdog`. See
// `captureFrame`.
