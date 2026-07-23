import Foundation
import ActivityAssistantCore

/// The two things `DATWearableDevice` needs from the audio stack.
///
/// They are protocols rather than concrete types for the same reason
/// `WearableDevice` is: `HFPAudioRecorder` and `GlassesSpeaker` are built on
/// `AVAudioSession`, which exists only on iOS, and depending on them directly
/// would make the DAT bridge impossible to compile anywhere but a device.
/// Behind these two seams the bridge type-checks on a laptop — see
/// `ios-app/DATBridgeCheck`.
protocol AudioWindowRecorder: Sendable {
    /// Records a short clip, or returns `nil` when no microphone route is
    /// available. Audio is optional, so `nil` is never an error.
    func record(seconds: Double) async -> CapturedAudio?

    /// Releases the capture (HFP) route so playback (A2DP) can take over.
    /// Returns `true` if a route was actually held and has now been dropped.
    @discardableResult
    func releaseRoute() async -> Bool

    /// Re-acquires the capture route. Returns `false` when unavailable.
    @discardableResult
    func acquireRoute() async -> Bool
}

protocol ResultSpeaker: Sendable {
    /// Whether speaking is switched on at all. Checked *before* the audio route
    /// is disturbed — see `DATWearableDevice.speak`.
    var isEnabled: Bool { get }

    func speak(_ text: String) async
}
