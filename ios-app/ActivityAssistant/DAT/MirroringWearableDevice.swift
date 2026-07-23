import Foundation
import Observation
import ActivityAssistantCore

/// Wraps any `WearableDevice` and additionally publishes every frame to the
/// phone, so the screen shows exactly what the HUD shows.
///
/// It earns its place twice:
///
///   * **On hardware** — the demo video needs to show the interaction, and you
///     cannot point a camera through a waveguide. The mirror is what gets
///     screen-recorded.
///   * **On the Mock Device Kit** — which has no display emulation at all, so
///     the mirror is the *only* rendering of the HUD that exists.
///
/// It is a decorator rather than a branch inside `DATWearableDevice` so that
/// neither path has an untested special case: the engine, the frames and the
/// copy are identical, and only the destination differs.
final class MirroringWearableDevice: WearableDevice {

    private let wrapped: any WearableDevice
    private let mirror: HUDMirror

    init(wrapping wrapped: any WearableDevice, mirror: HUDMirror) {
        self.wrapped = wrapped
        self.mirror = mirror
    }

    var isConnected: Bool {
        get async { await wrapped.isConnected }
    }

    var deviceDescription: String {
        get async { await wrapped.deviceDescription }
    }

    func captureFrame() async throws -> CapturedFrame {
        let frame = try await wrapped.captureFrame()
        await mirror.setPreview(jpeg: frame.jpegData)
        return frame
    }

    func captureAudio(seconds: Double) async -> CapturedAudio? {
        let audio = await wrapped.captureAudio(seconds: seconds)
        await mirror.setAudioSource(audio)
        return audio
    }

    func present(_ frame: DisplayFrame) async {
        await mirror.setFrame(frame)
        await wrapped.present(frame)
    }

    func intents() -> AsyncStream<DisplayFrame.Intent> {
        wrapped.intents()
    }

    func speak(_ text: String) async {
        await mirror.setSpoken(text)
        await wrapped.speak(text)
    }
}

/// Observable state backing the phone-side HUD preview.
@MainActor
@Observable
final class HUDMirror {

    /// The frame currently on the glasses.
    private(set) var frame: DisplayFrame?
    /// The last captured JPEG, shown behind the HUD so the demo video makes it
    /// obvious which frame produced which prediction.
    private(set) var previewJPEG: Data?
    /// Where the audio actually came from, if anywhere. Worth surfacing: a
    /// silent fall back to the phone mic in a pocket would otherwise be
    /// invisible and would quietly change what the model hears.
    private(set) var audioSource: AudioSource = .none
    private(set) var lastSpoken: String?

    @ObservationIgnored private var previewClearTask: Task<Void, Never>?

    enum AudioSource: Equatable {
        case none
        case glassesHFP(seconds: Double)
        case phoneMicrophone(seconds: Double)

        var label: String {
            switch self {
            case .none: "vision only"
            case .glassesHFP(let seconds): String(format: "glasses mic · %.1fs", seconds)
            case .phoneMicrophone(let seconds): String(format: "PHONE mic · %.1fs", seconds)
            }
        }
    }

    func setFrame(_ frame: DisplayFrame) {
        self.frame = frame
    }

    func setPreview(jpeg: Data) {
        previewJPEG = jpeg
    }

    func setAudioSource(_ audio: CapturedAudio?) {
        guard let audio else {
            audioSource = .none
            return
        }
        audioSource = audio.usedPhoneMicrophone
            ? .phoneMicrophone(seconds: audio.durationSeconds)
            : .glassesHFP(seconds: audio.durationSeconds)
    }

    func setSpoken(_ text: String) {
        lastSpoken = text
    }

    /// Drops the captured frame once the wearer has seen the result.
    ///
    /// The README promises the frame lives only as long as one request needs
    /// it. Holding it in the mirror indefinitely quietly broke that: after an
    /// eight-trial demo the app was still carrying a photograph of the last
    /// participant, for a preview nobody was looking at any more.
    ///
    /// The delay is what makes it useful rather than pedantic — the preview
    /// has to outlive the result frame long enough for the wearer, and the
    /// demo video, to see which image produced which prediction.
    func clearPreviewAfterResult(after seconds: Double = 8) {
        previewClearTask?.cancel()
        previewClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.previewJPEG = nil
        }
    }

    /// Drops it immediately, for teardown.
    func clearPreviewNow() {
        previewClearTask?.cancel()
        previewClearTask = nil
        previewJPEG = nil
    }
}
