import SwiftUI
import Observation
import ActivityAssistantCore
import MWDATCore

@main
struct ActivityAssistantApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.start() }
                .onOpenURL { url in
                    // The Meta AI app returns here after registration. Without
                    // handing the URL back to the SDK, registration never
                    // completes and every permission request fails.
                    Task { await model.handle(url: url) }
                }
        }
    }
}

/// Owns the object graph and exposes it to SwiftUI.
///
/// Everything interesting lives in `ActivityAssistantEngine`; this type only
/// wires the pieces together and translates engine state into something the
/// phone UI can observe.
@MainActor
@Observable
final class AppModel {

    private(set) var status: Status = .starting
    private(set) var log: [LogEntry] = []
    let mirror = HUDMirror()

    /// Mirrored out of the engine rather than read through it.
    ///
    /// `ActivityAssistantEngine` is not `@Observable`, so SwiftUI cannot track
    /// reads that go through it — a computed `var state { engine?.state }`
    /// looks right and never triggers a redraw. Previously that meant a
    /// finished trial only appeared once the *next* one started, and the last
    /// trial of a run was never visible at all.
    private(set) var flowState: FlowState = .ready
    private(set) var trials: [TrialRecord] = []

    private var engine: ActivityAssistantEngine?
    private var device: DATWearableDevice?
    private var intentLoop: Task<Void, Never>?

    enum Status: Equatable {
        case starting
        case needsRegistration
        case connecting
        case ready(deviceDescription: String, hasGlassesDisplay: Bool)
        case failed(String)
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
    }

    // MARK: - Startup

    func start() async {
        guard case .starting = status else { return }
        status = .connecting

        do {
            let configuration = try Configuration.service()

            if Configuration.useMockDevice {
                try MockDeviceKitHarness.start(with: .walking)
                note("Mock Device Kit enabled — HUD renders on the phone mirror.")
            }

            let recorder = HFPAudioRecorder(isEnabled: configuration.audioEnabled)
            let speaker = GlassesSpeaker(isEnabled: Configuration.speechEnabled)
            let device = try DATWearableDevice(audioRecorder: recorder, speaker: speaker)
            self.device = device

            try await device.connect()

            // Acquire HFP once, before any capture. Doing it per-trial would
            // add ~2 s to every prediction; doing it after the camera stream
            // starts makes the audio route fail silently.
            if configuration.audioEnabled {
                let gotRoute = await recorder.acquireRoute()
                note(gotRoute
                     ? "Glasses microphone route acquired (HFP, 8 kHz)."
                     : "No HFP route — predictions will be vision-only.")
            }

            let mirroring = MirroringWearableDevice(wrapping: device, mirror: mirror)
            let client = HTTPImageBindClient(configuration: configuration)
            let engine = ActivityAssistantEngine(
                device: mirroring,
                client: client,
                configuration: configuration
            )
            engine.onStateChange = { [weak self] state in
                guard let self else { return }
                // Copy into observed storage on every transition. This is the
                // only place SwiftUI learns that anything happened.
                self.flowState = state
                self.trials = engine.trials
                self.note(Self.describe(state))
                if state.isTerminal {
                    // The captured frame has served its purpose. Holding it
                    // would contradict the privacy line in the README, and on a
                    // long demo the mirror would otherwise retain every frame
                    // of the session.
                    self.mirror.clearPreviewAfterResult()
                }
            }
            self.engine = engine

            let description = await device.deviceDescription
            let displayReason = await device.displayUnavailableReason
            status = .ready(deviceDescription: description, hasGlassesDisplay: displayReason == nil)
            if let displayReason {
                note("No glasses display: \(displayReason)")
            }

            intentLoop = Task { await engine.run() }
        } catch let error as PredictionError {
            // A permission failure almost always means the app was never
            // approved in the Meta AI app. That is recoverable and has a
            // button, so it gets its own status — previously every startup
            // failure collapsed into `.failed` and `.needsRegistration` was
            // unreachable, leaving the Register button as dead code and the
            // wearer with an error they had no way to act on.
            if case .captureFailed(let detail) = error, detail.contains("permission") {
                status = .needsRegistration
                note("Camera permission not granted: \(detail)")
            } else {
                status = .failed(error.diagnosticDescription)
                note("Startup failed: \(error.diagnosticDescription)")
            }
        } catch {
            status = .failed(String(describing: error))
            note("Startup failed: \(error)")
        }
    }

    func handle(url: URL) async {
        _ = try? await Wearables.shared.handleUrl(url)
        note("Handled registration callback.")
        // Registration just completed, so the connect that failed for want of
        // it can now succeed. Without this retry the wearer would approve the
        // app and then be left staring at the same Register button.
        if case .needsRegistration = status {
            status = .starting
            await start()
        }
    }

    func beginRegistration() {
        do {
            try Wearables.shared.startRegistration()
        } catch {
            note("Registration could not start: \(error)")
        }
    }

    // MARK: - Driving the flow from the phone

    /// Mirrors the on-glasses Analyze / Try Again button. Useful when the
    /// wearer's hands are busy and for driving the Mock Device Kit, where
    /// there is no HUD to tap.
    func tapAnalyze() {
        guard let engine else {
            // Previously a silent no-op, which on the connect-failed path meant
            // an enabled button that did nothing and gave no reason why.
            note("Not connected yet — tap unavailable until the glasses session starts.")
            return
        }
        engine.handle(engine.state.isTerminal ? .tryAgain : .analyze)
    }

    /// Swaps the Mock Device Kit fixture so one session can cover all four
    /// activities.
    func useMockFixture(for activity: Activity) {
        guard Configuration.useMockDevice else { return }
        do {
            switch activity {
            case .walking: try MockDeviceKitHarness.use(.walking)
            case .running: try MockDeviceKitHarness.use(.running)
            case .sitting: try MockDeviceKitHarness.use(.sitting)
            case .standing: try MockDeviceKitHarness.use(.standing)
            }
            note("Mock fixture → \(activity.displayName)")
        } catch {
            note("Fixture swap failed: \(error)")
        }
    }

    // MARK: - Logging

    private func note(_ message: String) {
        log.append(LogEntry(timestamp: Date(), message: message))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    /// Full detail goes to the phone log; the HUD only ever gets the short
    /// form from `PredictionError.glassesMessage`.
    private static func describe(_ state: FlowState) -> String {
        switch state {
        case .ready:
            "Ready"
        case .analyzing(let stage):
            "Analyzing — \(stage.rawValue)"
        case .result(let prediction):
            "Result: \(prediction.activity.displayName) "
            + "@ \(String(format: "%.2f", prediction.confidence)) "
            + "(margin \(String(format: "%.2f", prediction.margin)))"
        case .lowConfidence(let prediction):
            "Low confidence: best guess \(prediction.activity.displayName) "
            + "@ \(String(format: "%.2f", prediction.confidence))"
        case .failed(let error):
            "Failed — \(error.diagnosticDescription)"
        }
    }
}
