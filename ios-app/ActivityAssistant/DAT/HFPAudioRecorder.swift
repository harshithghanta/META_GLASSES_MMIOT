import AVFoundation
import Foundation
import ActivityAssistantCore

/// Captures the optional audio window from the glasses microphone.
///
/// ## Why this is not a DAT call
///
/// The Device Access Toolkit has **no microphone API**. Meta's own docs are
/// explicit: *"Microphone access uses the Hands-Free Profile (HFP), so you
/// request those permissions through iOS or Android platform dialogs."* So the
/// glasses mic is reached entirely through `AVAudioSession` — DAT is not
/// involved in this file at all.
///
/// Three consequences that shape the code below:
///
///  1. **HFP is 8 kHz mono.** ImageBind's audio encoder wants 16 kHz, so we
///     resample on the way out. That adds no information — there is nothing
///     above 4 kHz in an HFP signal — it only matches the tensor shape.
///  2. **HFP and A2DP are mutually exclusive.** Holding the record route means
///     we cannot play speech through the glasses, which is why `releaseRoute()`
///     exists and why `GlassesSpeaker` is a separate object.
///  3. **The route takes ~2 s to settle**, and starting the DAT camera stream
///     before it settles makes the audio route fail silently. We acquire the
///     route once and hold it, rather than paying that cost on every trial.
actor HFPAudioRecorder: AudioWindowRecorder {

    /// Set `false` to run the demo vision-only. The engine treats a `nil` clip
    /// as "no audio available" and predicts from the frame alone.
    private let isEnabled: Bool

    /// ImageBind's expected input rate. HFP delivers 8 kHz; we upsample.
    private let targetSampleRate: Double = 16_000

    private var engine: AVAudioEngine?
    private var holdsRoute = false

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    // MARK: - Route management

    /// Acquires the HFP input route. Idempotent, and safe to call before the
    /// DAT camera stream starts — which is the required order.
    @discardableResult
    func acquireRoute() async -> Bool {
        guard isEnabled, !holdsRoute else { return holdsRoute }
        guard await requestPermission() else { return false }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
            try session.setActive(true)

            // Prefer the glasses. If they aren't offering an HFP input we fall
            // back to the built-in mic rather than failing — a pocket mic is
            // worse than a head-mounted one, but it is still a second modality
            // and the trial log records which one was used.
            if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                try session.setPreferredInput(glasses)
            }

            // The route change is asynchronous; polling beats a blind sleep.
            for _ in 0..<20 {
                if session.currentRoute.inputs.contains(where: { $0.portType == .bluetoothHFP }) {
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            holdsRoute = true
            return true
        } catch {
            return false
        }
    }

    /// Drops the record route so A2DP playback can take over. Called before
    /// speaking a result, since the two profiles cannot be active at once.
    /// Returns whether a route was actually held, so the caller knows whether
    /// to hand it back afterwards.
    @discardableResult
    func releaseRoute() -> Bool {
        guard holdsRoute else { return false }
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        holdsRoute = false
        return true
    }

    private var isUsingGlassesMicrophone: Bool {
        AVAudioSession.sharedInstance().currentRoute.inputs
            .contains { $0.portType == .bluetoothHFP }
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Recording

    /// Records `seconds` of mono audio and returns it as a 16 kHz WAV.
    /// Returns `nil` on any failure — audio is optional, so a broken mic must
    /// degrade the prediction to vision-only, never fail the trial.
    func record(seconds: Double) async -> CapturedAudio? {
        guard isEnabled, await acquireRoute() else { return nil }

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else { return nil }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }

        let collector = SampleCollector()
        let targetSamples = Int(targetSampleRate * seconds)

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            guard let converted = Self.convert(buffer, using: converter, to: outputFormat) else {
                return
            }
            collector.append(converted)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.engine = nil
            return nil
        }

        // Poll rather than sleeping the full window, so a mic that stops
        // producing buffers ends the trial instead of hanging it.
        let deadline = ContinuousClock.now + .seconds(seconds + 1)
        while collector.count < targetSamples, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        input.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil

        let samples = collector.take(targetSamples)
        guard !samples.isEmpty else { return nil }

        return CapturedAudio(
            wavData: Self.wav(samples: samples, sampleRate: Int(targetSampleRate)),
            durationSeconds: Double(samples.count) / targetSampleRate,
            usedPhoneMicrophone: !isUsingGlassesMicrophone
        )
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    /// Minimal 44-byte canonical WAV header plus little-endian PCM16 samples.
    static func wav(samples: [Int16], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataBytes = samples.count * bytesPerSample
        var data = Data(capacity: 44 + dataBytes)

        func appendASCII(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func appendUInt32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendUInt16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + dataBytes))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)                                    // PCM subchunk size
        appendUInt16(1)                                     // format: PCM
        appendUInt16(1)                                     // channels: mono
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * bytesPerSample))   // byte rate
        appendUInt16(UInt16(bytesPerSample))                // block align
        appendUInt16(16)                                    // bits per sample
        appendASCII("data")
        appendUInt32(UInt32(dataBytes))

        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

/// Accumulates converted samples from the audio tap, which fires on a
/// real-time thread and therefore cannot touch actor state directly.
private final class SampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int16] = []

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.int16ChannelData?[0] else { return }
        let incoming = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        lock.lock()
        samples.append(contentsOf: incoming)
        lock.unlock()
    }

    func take(_ limit: Int) -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        return Array(samples.prefix(limit))
    }
}
