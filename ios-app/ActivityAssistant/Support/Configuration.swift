import Foundation
import ActivityAssistantCore

/// Reads the Assignment 2 endpoint out of the build configuration.
///
/// The assignment's rules forbid committing tokens or private endpoint URLs,
/// so nothing here has a hard-coded default that points anywhere real. Values
/// come from `Secrets.xcconfig`, which is git-ignored; `Secrets.example.xcconfig`
/// is the committed template.
enum Configuration {

    /// `IMAGEBIND_ENDPOINT` — e.g. your Colab/Gradio tunnel or Replicate proxy.
    static var endpoint: URL {
        get throws {
            guard let raw = infoValue("IMAGEBIND_ENDPOINT"), !raw.isEmpty else {
                throw ConfigurationError.missing("IMAGEBIND_ENDPOINT")
            }
            // xcconfig strips `//`, so the scheme is stored separately and
            // rejoined here — a well-known xcconfig gotcha that otherwise
            // produces a silently malformed URL.
            let scheme = infoValue("IMAGEBIND_SCHEME") ?? "https"
            let joined = raw.contains("://") ? raw : "\(scheme)://\(raw)"
            guard let url = URL(string: joined) else {
                throw ConfigurationError.malformed("IMAGEBIND_ENDPOINT", joined)
            }
            return url
        }
    }

    /// `IMAGEBIND_TOKEN` — optional bearer token.
    static var authToken: String? {
        infoValue("IMAGEBIND_TOKEN").flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Assembled service configuration.
    ///
    /// The two numbers worth explaining:
    ///
    /// * **`confidenceFloor: 0.45`** — a provisional default. It has NOT been
    ///   tuned on validation data, and the service's confidence calibration
    ///   is itself unverified. See `docs/REPORT.md`.
    /// * **`timeout: 12`** — a warm Colab GPU answers in well under 2 s. Twelve
    ///   seconds is long enough that a slow-but-alive service still succeeds,
    ///   and short enough that a dead tunnel surfaces as a retry prompt while
    ///   the wearer is still looking at the HUD.
    static func service() throws -> ServiceConfiguration {
        ServiceConfiguration(
            endpoint: try endpoint,
            authToken: authToken,
            timeout: 12,
            confidenceFloor: 0.45,
            audioWindowSeconds: 2.0,
            audioEnabled: audioEnabled
        )
    }

    /// Audio is on by default — it is what separates walking from running.
    static var audioEnabled: Bool {
        infoValue("AUDIO_ENABLED").map { $0 != "NO" } ?? true
    }

    /// Spoken results are **off** by default. Speaking needs A2DP, capture
    /// needs HFP, and the two are mutually exclusive — so every announcement
    /// costs roughly 2 s of route re-acquisition on the *next* trial. Turn it
    /// on for the voice-feature part of the demo, not for timed runs.
    static var speechEnabled: Bool {
        infoValue("SPEECH_ENABLED").map { $0 == "YES" } ?? false
    }

    /// Set `USE_MOCK_DEVICE = YES` to run against the Mock Device Kit.
    static var useMockDevice: Bool {
        infoValue("USE_MOCK_DEVICE").map { $0 == "YES" } ?? false
    }

    /// Reads an Info.plist value, treating "absent" and "present but useless"
    /// as the same thing.
    ///
    /// Two ways a key can be useless. An xcconfig variable that is never
    /// defined leaves the literal `$(IMAGEBIND_SCHEME)` in the built plist,
    /// and one defined as empty leaves `""`. Returning either verbatim made
    /// every `?? "https"` fallback in this file dead code: `endpoint` would
    /// build a scheme-less URL, the request would fail, and the wearer would
    /// see "Can't reach the server" for what is actually a missing setting.
    private static func infoValue(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("$(") && trimmed.hasSuffix(")") { return nil }
        return trimmed
    }

    enum ConfigurationError: Error, CustomStringConvertible {
        case missing(String)
        case malformed(String, String)

        var description: String {
            switch self {
            case .missing(let key):
                "\(key) is not set. Copy Secrets.example.xcconfig to Secrets.xcconfig and fill it in."
            case .malformed(let key, let value):
                "\(key) is not a valid URL: \(value)"
            }
        }
    }
}
