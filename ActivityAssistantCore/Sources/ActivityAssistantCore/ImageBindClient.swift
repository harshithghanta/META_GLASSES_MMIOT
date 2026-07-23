import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to the Assignment 2 ImageBind service. No model runs on the phone or
/// the glasses — this is the only place inference happens.
public protocol ImageBindClient: Sendable {
    func predict(frame: CapturedFrame, audio: CapturedAudio?) async throws -> Prediction
}

/// Where the Assignment 2 service lives and how patient we are with it.
public struct ServiceConfiguration: Sendable {
    public let endpoint: URL
    /// Optional bearer token. Kept out of source — see `Secrets.example.xcconfig`.
    public let authToken: String?
    /// Wall-clock budget for one prediction. 12 s is generous for a warm Colab
    /// GPU and still short enough that the wearer isn't left staring at a
    /// spinner; a cold Colab usually exceeds it, which is exactly the
    /// endpoint-failure trial we're required to demonstrate.
    public let timeout: Double
    /// Below this, the flow shows the low-confidence fallback instead of
    /// asserting an answer. See `docs/REPORT.md` for how 0.45 was chosen.
    public let confidenceFloor: Double
    /// Length of the optional audio window.
    public let audioWindowSeconds: Double
    /// Whether to attempt audio capture at all.
    public let audioEnabled: Bool

    public init(
        endpoint: URL,
        authToken: String? = nil,
        timeout: Double = 12,
        confidenceFloor: Double = 0.45,
        audioWindowSeconds: Double = 2.0,
        audioEnabled: Bool = true
    ) {
        self.endpoint = endpoint
        self.authToken = authToken
        self.timeout = timeout
        self.confidenceFloor = confidenceFloor
        self.audioWindowSeconds = audioWindowSeconds
        self.audioEnabled = audioEnabled
    }
}

/// `multipart/form-data` client against `POST {endpoint}/predict`.
public struct HTTPImageBindClient: ImageBindClient {
    private let configuration: ServiceConfiguration
    private let session: URLSession

    public init(configuration: ServiceConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func predict(frame: CapturedFrame, audio: CapturedAudio?) async throws -> Prediction {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: configuration.endpoint.appendingPathComponent("predict"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        if let token = configuration.authToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            frame: frame,
            audio: audio
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw PredictionError.timedOut(seconds: configuration.timeout)
        } catch let error as URLError {
            // Everything else at this layer is "the request never landed":
            // no Wi-Fi, DNS failure, the Colab tunnel closed between trials.
            throw PredictionError.unreachable(error.localizedDescription)
        } catch {
            throw PredictionError.unreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PredictionError.malformedResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PredictionError.httpStatus(
                code: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "<binary>"
            )
        }

        do {
            return try PredictionResponse.decode(from: data).validated()
        } catch let error as PredictionError {
            throw error
        } catch {
            throw PredictionError.malformedResponse(error.localizedDescription)
        }
    }

    /// Builds the multipart body. `image` is always present; `audio` is
    /// included only when a clip was captured, which is how the service knows
    /// whether to run the audio encoder.
    public static func multipartBody(
        boundary: String,
        frame: CapturedFrame,
        audio: CapturedAudio?
    ) -> Data {
        var body = Data()

        func appendPart(name: String, filename: String, mimeType: String, payload: Data) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            body.append("Content-Type: \(mimeType)\r\n\r\n")
            body.append(payload)
            body.append("\r\n")
        }

        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append(value)
            body.append("\r\n")
        }

        appendPart(
            name: "image",
            filename: "frame.jpg",
            mimeType: "image/jpeg",
            payload: frame.jpegData
        )
        if let audio {
            appendPart(
                name: "audio",
                filename: "clip.wav",
                mimeType: "audio/wav",
                payload: audio.wavData
            )
        }
        // Lets the service log which device produced a frame without the app
        // having to send anything identifying about the wearer.
        appendField(name: "source", value: "raybandisplay-dat-ios")

        body.append("--\(boundary)--\r\n")
        return body
    }
}

private extension Data {
    mutating func append(_ string: String) {
        // UTF-8 encoding of an ASCII multipart header cannot fail.
        if let data = string.data(using: .utf8) { append(data) }
    }
}
