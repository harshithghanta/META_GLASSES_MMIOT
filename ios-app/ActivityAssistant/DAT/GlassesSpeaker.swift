import AVFoundation
import Foundation

/// Speaks a result through the glasses speakers — the assignment's optional
/// voice feature.
///
/// Like the microphone, this is **not** a DAT capability: the toolkit has no
/// text-to-speech API. Audio played through a normal `AVAudioSession` routes
/// to the glasses over A2DP because they are the connected Bluetooth output.
///
/// The handover matters. A2DP (playback, 44.1 kHz stereo) and HFP (capture,
/// 8 kHz mono) cannot be active at the same time, so `DATWearableDevice.speak`
/// releases the recorder's route before calling this. The cost of that is
/// paid on the *next* trial, which re-acquires HFP — about 2 s. That is the
/// whole reason spoken results are off by default in `Configuration`.
actor GlassesSpeaker: ResultSpeaker {

    nonisolated let isEnabled: Bool
    private let synthesizer = AVSpeechSynthesizer()
    /// Strongly held: `AVSpeechSynthesizer.delegate` is weak.
    private let completion = UtteranceCompletion()

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    func speak(_ text: String) async {
        guard isEnabled else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return   // Optional feature: never fail a trial over speech.
        }

        // Wait for the route to actually switch before deciding where audio is
        // going. HFP was released moments ago and A2DP does not appear in
        // `currentRoute` instantly — checking immediately, as this used to,
        // found no A2DP output and returned early every single time, so the
        // optional voice feature never once spoke.
        let routedToGlasses = await waitForA2DPRoute(session: session)

        // If the glasses still aren't the output, stay silent rather than
        // announcing the wearer's activity out of the phone speaker in public.
        guard routedToGlasses else { return }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        // `speak` returns immediately. Wait for the utterance to finish (or
        // a safety timeout) before returning: the caller re-acquires the HFP
        // capture route as soon as we return, which would cut speech off.
        synthesizer.delegate = completion
        await withCheckedContinuation { continuation in
            completion.arm(continuation, timeout: .seconds(10))
            synthesizer.speak(utterance)
        }
    }

    /// Polls for the playback route for up to a second.
    private func waitForA2DPRoute(session: AVAudioSession) async -> Bool {
        for _ in 0..<10 {
            if session.currentRoute.outputs.contains(where: { $0.portType == .bluetoothA2DP }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

/// Resumes a waiting `speak` when the utterance finishes or is cancelled, or
/// after a timeout so a missed delegate callback can never hang a trial.
/// Resumes at most once.
private final class UtteranceCompletion: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var generation = 0

    func arm(_ continuation: CheckedContinuation<Void, Never>, timeout: Duration) {
        lock.lock()
        let previous = self.continuation
        self.continuation = continuation
        generation &+= 1
        let armed = generation
        lock.unlock()
        previous?.resume()
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resume(ifGeneration: armed)
        }
    }

    /// Timeout path: only fires for the utterance it was armed for.
    private func resume(ifGeneration armed: Int) {
        lock.lock()
        guard armed == generation else { lock.unlock(); return }
        lock.unlock()
        resume()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resume()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resume()
    }

    private func resume() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
