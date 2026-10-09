import Foundation

/// Everything the flow needs from a pair of glasses.
///
/// Conformers:
///
///   * `DATWearableDevice` (iOS app) — the real Device Access Toolkit session.
///     With `USE_MOCK_DEVICE = YES`, `MockDeviceKitHarness` enables the DAT
///     Mock Device Kit underneath it, serving frames from bundled fixtures.
///   * `MirroringWearableDevice` (iOS app) — a decorator that also mirrors
///     the HUD onto the phone.
///   * `ScriptedWearableDevice` (this package) — a deterministic fake used by
///     the unit tests and the trial harness.
///
/// The engine only ever talks to this protocol, so the required DAT demo and
/// the laptop test run exercise exactly the same state machine.
public protocol WearableDevice: Sendable {
    /// Whether a device (real or mock) is currently connected and permitted.
    var isConnected: Bool { get async }

    /// Human-readable source, surfaced in the phone-side log and the report's
    /// test table so a trial row records which device produced it.
    var deviceDescription: String { get async }

    /// Capture exactly one still frame from the glasses camera.
    /// Throws `PredictionError.captureFailed` if no frame is available.
    func captureFrame() async throws -> CapturedFrame

    /// Capture a short audio window. Returns `nil` when audio is unavailable —
    /// audio is optional in the assignment, so a device without mic access
    /// must degrade to vision-only rather than failing the trial.
    func captureAudio(seconds: Double) async -> CapturedAudio?

    /// Render a frame on the HUD.
    func present(_ frame: DisplayFrame) async

    /// Stream of wearer intents (taps on the HUD actions).
    func intents() -> AsyncStream<DisplayFrame.Intent>

    /// Speak a line through the glasses speakers. Optional feature; a no-op
    /// implementation is valid.
    func speak(_ text: String) async
}

/// A single JPEG frame from the glasses camera.
public struct CapturedFrame: Sendable, Equatable {
    public let jpegData: Data
    public let width: Int
    public let height: Int
    /// Seconds since the analyze intent — reported in the trial log so we can
    /// separate capture latency from network latency.
    public let captureDuration: Double

    public init(jpegData: Data, width: Int, height: Int, captureDuration: Double) {
        self.jpegData = jpegData
        self.width = width
        self.height = height
        self.captureDuration = captureDuration
    }
}

/// A short mono 16 kHz WAV clip — the sample rate the Assignment 2 ImageBind
/// audio encoder expects.
///
/// Note what this actually contains on device. The Device Access Toolkit has
/// no microphone API at all; the glasses mic is reached through Bluetooth
/// Hands-Free Profile, which is **8 kHz mono**. `HFPAudioRecorder` upsamples
/// to 16 kHz so the tensor shape matches what the encoder was trained on, but
/// there is no information above 4 kHz in the signal. That ceiling is the
/// reason audio separates walking from running (footfall cadence is low
/// frequency) far better than it separates sitting from standing.
public struct CapturedAudio: Sendable, Equatable {
    public let wavData: Data
    public let durationSeconds: Double
    /// `true` when the clip came from the phone mic because HFP was
    /// unavailable. Recorded in the trial log, since it changes what the audio
    /// modality is actually hearing — the phone mic is in a pocket.
    public let usedPhoneMicrophone: Bool

    public init(wavData: Data, durationSeconds: Double, usedPhoneMicrophone: Bool) {
        self.wavData = wavData
        self.durationSeconds = durationSeconds
        self.usedPhoneMicrophone = usedPhoneMicrophone
    }
}
