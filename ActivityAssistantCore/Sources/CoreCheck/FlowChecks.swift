import Foundation
import ActivityAssistantCore

/// Covers the Required Interaction states: Ready, Analyzing, Result, the
/// low-confidence fallback, and the endpoint / capture failure paths.
@MainActor
enum FlowChecks {

    static func makeEngine(
        responses: [ScriptedImageBindClient.Response],
        frames: [ScriptedWearableDevice.FrameScript] = [.success(.sample())],
        audio: CapturedAudio? = .sample(),
        confidenceFloor: Double = 0.45,
        audioEnabled: Bool = true
    ) -> (ActivityAssistantEngine, ScriptedWearableDevice, ScriptedImageBindClient) {
        let device = ScriptedWearableDevice(frames: frames, audio: audio)
        let client = ScriptedImageBindClient(responses: responses)
        let configuration = ServiceConfiguration(
            endpoint: URL(string: "https://example.invalid")!,
            confidenceFloor: confidenceFloor,
            audioEnabled: audioEnabled
        )
        let engine = ActivityAssistantEngine(
            device: device,
            client: client,
            configuration: configuration
        )
        return (engine, device, client)
    }

    static func run() async {
        Check.suite("Ready state")

        await Check.test("shows the app name and an Analyze action") {
            let (engine, _, _) = makeEngine(responses: [])
            Check.equal(engine.state, .ready)
            Check.equal(engine.currentFrame.headline, "Activity Assistant")
            Check.equal(engine.currentFrame.actions.map(\.id), [.analyze])
            Check.equal(engine.currentFrame.tone, .neutral)
        }

        Check.suite("Result state")

        await Check.test("confident prediction shows the activity and confidence") {
            let prediction = Prediction.sample(.running, confidence: 0.87)
            let (engine, _, _) = makeEngine(responses: [.prediction(prediction)])

            let terminal = await engine.analyzeOnce()

            Check.equal(terminal, .result(prediction))
            Check.equal(engine.currentFrame.headline, "🏃 Running")
            Check.equal(engine.currentFrame.detail, "87% confident")
            Check.equal(engine.currentFrame.actions.map(\.id), [.tryAgain])
            Check.equal(engine.currentFrame.tone, .success)
        }

        await Check.test("wearer sees every Analyzing sub-step, never a frozen HUD") {
            let (engine, device, _) = makeEngine(
                responses: [.prediction(.sample(.running, confidence: 0.87))]
            )
            await engine.analyzeOnce()
            let headlines = await device.presentedFrames.map(\.headline)
            Check.equal(headlines, ["Capturing…", "Listening…", "Analyzing…", "🏃 Running"])
        }

        await Check.test("a trusted result is spoken aloud") {
            let (engine, device, _) = makeEngine(
                responses: [.prediction(.sample(.walking, confidence: 0.91))]
            )
            await engine.analyzeOnce()
            let spoken = await device.spokenLines
            Check.equal(spoken, ["Walking"])
        }

        Check.suite("Low-confidence fallback")

        await Check.test("declines to assert an answer and offers a retry") {
            let prediction = Prediction.sample(.sitting, confidence: 0.31, runnerUp: .standing)
            let (engine, _, _) = makeEngine(responses: [.prediction(prediction)])

            let terminal = await engine.analyzeOnce()

            Check.equal(terminal, .lowConfidence(prediction))
            Check.equal(engine.currentFrame.headline, "Not sure")
            Check.equal(engine.currentFrame.detail, "Maybe Sitting · retry")
            Check.equal(engine.currentFrame.tone, .caution)
            Check.equal(engine.currentFrame.actions.map(\.id), [.tryAgain])
        }

        await Check.test("a guess we are about to caveat is not announced") {
            let (engine, device, _) = makeEngine(
                responses: [.prediction(.sample(.sitting, confidence: 0.31))]
            )
            await engine.analyzeOnce()
            let spoken = await device.spokenLines
            Check.expect(spoken.isEmpty, "low-confidence guess should stay silent, spoke \(spoken)")
        }

        await Check.test("confidence exactly at the floor counts as a result") {
            let (engine, _, _) = makeEngine(
                responses: [.prediction(.sample(.standing, confidence: 0.45))],
                confidenceFloor: 0.45
            )
            let terminal = await engine.analyzeOnce()
            guard case .result = terminal else {
                return Check.fail("0.45 with a floor of 0.45 should be a result, got \(terminal)")
            }
        }

        Check.suite("Failure paths")

        await Check.test("endpoint timeout shows a short retry message") {
            let (engine, _, _) = makeEngine(responses: [.failure(.timedOut(seconds: 12))])

            let terminal = await engine.analyzeOnce()

            Check.equal(terminal, .failed(.timedOut(seconds: 12)))
            Check.equal(engine.currentFrame.headline, "Server took too long")
            Check.equal(engine.currentFrame.detail, "Tap to retry")
            Check.equal(engine.currentFrame.tone, .failure)
            Check.equal(engine.currentFrame.actions.map(\.id), [.tryAgain])
        }

        await Check.test("camera failure is reported without uploading anything") {
            let (engine, _, client) = makeEngine(
                responses: [.prediction(.sample(.walking, confidence: 0.9))],
                frames: [.failure(.captureFailed("no frame from device"))]
            )

            let terminal = await engine.analyzeOnce()

            Check.equal(terminal, .failed(.captureFailed("no frame from device")))
            Check.equal(engine.currentFrame.headline, "Camera didn't capture")
            let requests = await client.requestCount
            Check.equal(requests, 0, "must not upload when there is no frame")
        }

        await Check.test("every failure message fits the HUD headline budget") {
            let errors: [PredictionError] = [
                .unreachable("Could not connect to the server."),
                .timedOut(seconds: 12),
                .httpStatus(code: 503, body: "upstream unavailable"),
                .malformedResponse("not json"),
                .unknownLabel("cycling"),
                .captureFailed("device busy"),
            ]
            for error in errors {
                Check.expect(
                    error.glassesMessage.count <= DisplayFrame.Budget.headline,
                    "\"\(error.glassesMessage)\" overflows the \(DisplayFrame.Budget.headline)-char headline"
                )
            }
        }

        Check.suite("Retry")

        await Check.test("Try Again after a failure runs a second prediction") {
            let (engine, _, client) = makeEngine(
                responses: [
                    .failure(.unreachable("offline")),
                    .prediction(.sample(.walking, confidence: 0.78)),
                ]
            )

            let first = await engine.analyzeOnce()
            guard case .failed = first else { return Check.fail("expected a failure first") }

            let second = await engine.analyzeOnce()
            guard case .result(let prediction) = second else {
                return Check.fail("retry should succeed, got \(second)")
            }
            Check.equal(prediction.activity, .walking)
            let requests = await client.requestCount
            Check.equal(requests, 2)
        }

        await Check.test("a double tap does not start two captures") {
            let device = ScriptedWearableDevice()
            let client = ScriptedImageBindClient(
                responses: [.prediction(.sample(.running, confidence: 0.8))],
                latency: 0.15
            )
            let engine = ActivityAssistantEngine(
                device: device,
                client: client,
                configuration: ServiceConfiguration(endpoint: URL(string: "https://example.invalid")!)
            )

            // Two taps in quick succession, as the temple touchpad produces.
            engine.handle(.analyze)
            engine.handle(.analyze)
            await engine.analyzeOnce()

            let requests = await client.requestCount
            Check.equal(requests, 1, "the second tap must be swallowed while a run is in flight")
        }

        Check.suite("Cancellation")

        await Check.test("cancelling mid-run does not repaint the HUD with a late result") {
            let device = ScriptedWearableDevice()
            let client = ScriptedImageBindClient(
                responses: [.prediction(.sample(.running, confidence: 0.9))],
                latency: 0.3
            )
            let engine = ActivityAssistantEngine(
                device: device,
                client: client,
                configuration: ServiceConfiguration(endpoint: URL(string: "https://example.invalid")!)
            )

            engine.handle(.analyze)
            try? await Task.sleep(for: .milliseconds(60))
            engine.handle(.dismiss)              // wearer backs out mid-upload
            try? await Task.sleep(for: .milliseconds(500))

            Check.equal(engine.state, .ready, "state should stay Ready after dismiss")
            Check.equal(engine.currentFrame.headline, "Activity Assistant",
                        "the abandoned run must not overwrite the Ready frame")
            Check.equal(engine.trials.count, 0, "an abandoned run must not log a trial")
            let spoken = await device.spokenLines
            Check.expect(spoken.isEmpty, "an abandoned run must not speak, spoke \(spoken)")
        }

        await Check.test("a cancelled run does not free the slot for a newer run") {
            // Regression: the old cleanup ran `activeRun = nil` unconditionally,
            // so a cancelled run released a slot a *newer* run already owned —
            // and the next tap started a second analysis in parallel.
            let device = ScriptedWearableDevice()
            let client = ScriptedImageBindClient(
                responses: [.prediction(.sample(.walking, confidence: 0.9))],
                latency: 0.4
            )
            let engine = ActivityAssistantEngine(
                device: device,
                client: client,
                configuration: ServiceConfiguration(endpoint: URL(string: "https://example.invalid")!)
            )

            engine.handle(.analyze)              // run A
            try? await Task.sleep(for: .milliseconds(50))
            engine.handle(.dismiss)              // cancel A
            engine.handle(.analyze)              // run B takes the slot
            try? await Task.sleep(for: .milliseconds(120))
            engine.handle(.analyze)              // must be swallowed: B is live
            try? await Task.sleep(for: .milliseconds(700))

            let requests = await client.requestCount
            Check.expect(requests <= 2,
                         "at most one predict per accepted run; got \(requests)")
            Check.equal(engine.trials.count, 1, "exactly one run should have committed")
        }

        Check.suite("Audio is optional")

        await Check.test("audio disabled skips Listening and still predicts") {
            let (engine, device, client) = makeEngine(
                responses: [.prediction(.sample(.standing, confidence: 0.7, modalities: [.vision]))],
                audioEnabled: false
            )

            let terminal = await engine.analyzeOnce()
            guard case .result = terminal else { return Check.fail("expected a result") }

            let headlines = await device.presentedFrames.map(\.headline)
            Check.expect(!headlines.contains("Listening…"), "should not show the audio step")
            let sentAudio = await client.lastRequestIncludedAudio
            Check.expect(!sentAudio, "should not attach an audio part")
        }

        await Check.test("a device with no microphone degrades to vision-only") {
            let (engine, _, client) = makeEngine(
                responses: [.prediction(.sample(.walking, confidence: 0.66, modalities: [.vision]))],
                audio: nil
            )

            let terminal = await engine.analyzeOnce()
            guard case .result = terminal else {
                return Check.fail("no mic must not fail the trial, got \(terminal)")
            }
            let sentAudio = await client.lastRequestIncludedAudio
            Check.expect(!sentAudio, "should not attach an audio part")
        }

        Check.suite("Trial log")

        await Check.test("records correctness and separates low-confidence from wrong") {
            let (engine, _, _) = makeEngine(
                responses: [
                    .prediction(.sample(.walking, confidence: 0.88)),
                    .prediction(.sample(.running, confidence: 0.80)),
                    .prediction(.sample(.sitting, confidence: 0.30)),
                    .failure(.unreachable("tunnel closed")),
                ]
            )

            engine.pendingGroundTruth = .walking
            await engine.analyzeOnce()
            engine.pendingGroundTruth = .walking    // model says running — a miss
            await engine.analyzeOnce()
            engine.pendingGroundTruth = .sitting    // right label, too little confidence
            await engine.analyzeOnce()
            engine.pendingGroundTruth = .standing
            await engine.analyzeOnce()

            Check.equal(engine.trials.count, 4)
            Check.equal(engine.trials.map(\.index), [1, 2, 3, 4])
            Check.equal(engine.trials.map(\.isCorrect), [true, false, false, false])

            guard case .lowConfidence = engine.trials[2].outcome else {
                return Check.fail("trial 3 should log as low-confidence, not a wrong answer")
            }
            guard case .failed = engine.trials[3].outcome else {
                return Check.fail("trial 4 should log as an endpoint failure")
            }
        }
    }
}
