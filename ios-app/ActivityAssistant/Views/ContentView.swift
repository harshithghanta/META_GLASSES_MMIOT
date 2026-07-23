import SwiftUI
import ActivityAssistantCore

/// The paired-phone UI.
///
/// The glasses are the product; this screen exists to make the demo legible.
/// It shows a faithful 600 × 600 stand-in for the HUD, the frame that produced
/// the current prediction, and a running log — the three things a viewer of
/// the demo video cannot otherwise see.
struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    statusBanner
                    HUDPreview(mirror: model.mirror)
                    controls
                    if Configuration.useMockDevice { fixturePicker }
                    trialSummary
                    logView
                }
                .padding()
            }
            .navigationTitle("Activity Assistant")
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusBanner: some View {
        switch model.status {
        case .starting, .connecting:
            Label("Connecting to glasses…", systemImage: "hourglass")
                .frame(maxWidth: .infinity, alignment: .leading)

        case .needsRegistration:
            VStack(alignment: .leading, spacing: 8) {
                Label("Not registered", systemImage: "exclamationmark.triangle")
                Text("Approve this app in the Meta AI app before it can use the camera.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Register") { model.beginRegistration() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .ready(let description, let hasGlassesDisplay):
            VStack(alignment: .leading, spacing: 4) {
                Label(description, systemImage: "eyeglasses")
                if !hasGlassesDisplay {
                    // Never let a demo run believe the HUD is live when it is
                    // the phone doing the rendering.
                    Text("No glasses display — the preview below is the only HUD.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Text("Audio: \(model.mirror.audioSource.label)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .failed(let message):
            Label(message, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        Button(action: model.tapAnalyze) {
            Label(analyzeTitle, systemImage: "camera.viewfinder")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isBusy)
    }

    private var analyzeTitle: String {
        model.flowState.isTerminal ? "Try Again" : "Analyze"
    }

    private var isBusy: Bool {
        if case .analyzing = model.flowState { return true }
        return false
    }

    /// Only present under the Mock Device Kit: swaps which fixture the
    /// simulated camera serves, so one session covers all four activities.
    private var fixturePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mock fixture").font(.headline)
            HStack {
                ForEach(Activity.allCases, id: \.self) { activity in
                    Button(activity.displayName) { model.useMockFixture(for: activity) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Trials

    @ViewBuilder
    private var trialSummary: some View {
        if !model.trials.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Trials (\(model.trials.count))").font(.headline)
                ForEach(model.trials, id: \.index) { trial in
                    HStack {
                        Text("#\(trial.index)").monospacedDigit().foregroundStyle(.secondary)
                        Text(outcomeText(trial))
                        Spacer()
                        Text(String(format: "%.1fs", trial.totalSeconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func outcomeText(_ trial: TrialRecord) -> String {
        switch trial.outcome {
        case .predicted(let prediction):
            "\(prediction.activity.displayName) \(Int(prediction.confidence * 100))%"
            + (trial.groundTruth.map { trial.isCorrect ? " ✓" : " ✗ (was \($0.displayName))" } ?? "")
        case .lowConfidence(let prediction):
            "declined — best guess \(prediction.activity.displayName) \(Int(prediction.confidence * 100))%"
        case .failed(let error):
            error.glassesMessage
        }
    }

    // MARK: - Log

    @ViewBuilder
    private var logView: some View {
        if !model.log.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Log").font(.headline)
                ForEach(model.log.reversed()) { entry in
                    Text(entry.message)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A 600 × 600 stand-in for the Ray-Ban Display panel.
///
/// Styled the way the real waveguide behaves: the panel is **additive**, so
/// black is fully transparent and only bright pixels are visible. Rendering
/// the mirror on black with high-contrast text is what makes the preview an
/// honest preview rather than a prettier parallel design.
struct HUDPreview: View {
    let mirror: HUDMirror

    var body: some View {
        ZStack {
            if let jpeg = mirror.previewJPEG, let image = UIImage(data: jpeg) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.35)      // stand-in for looking through the lens
            }
            Color.black.opacity(mirror.previewJPEG == nil ? 1 : 0.4)

            if let frame = mirror.frame {
                VStack(spacing: 12) {
                    Text(frame.headline)
                        .font(.system(size: 34, weight: .semibold))
                        .multilineTextAlignment(.center)

                    if let detail = frame.detail {
                        Text(detail)
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                    }

                    ForEach(frame.actions) { action in
                        Text(action.title)
                            .font(.system(size: 20, weight: .medium))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .overlay(Capsule().stroke(.white.opacity(0.8), lineWidth: 1.5))
                    }
                }
                .foregroundStyle(tint(for: frame.tone))
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)      // the panel is square: 600 × 600
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15), lineWidth: 1)
        )
    }

    private func tint(for tone: DisplayFrame.Tone) -> Color {
        switch tone {
        case .neutral, .working: .white
        case .success: Color(red: 0.55, green: 1.0, blue: 0.7)
        case .caution: Color(red: 1.0, green: 0.85, blue: 0.45)
        case .failure: Color(red: 1.0, green: 0.6, blue: 0.55)
        }
    }
}
