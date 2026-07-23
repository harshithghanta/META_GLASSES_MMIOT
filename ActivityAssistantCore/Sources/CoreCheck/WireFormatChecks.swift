import Foundation
import ActivityAssistantCore

/// Covers the contract with the Assignment 2 service: both response shapes it
/// can be served in, the tolerant label parse, and the multipart request body.
@MainActor
enum WireFormatChecks {

    static func run() async {
        Check.suite("Response decoding")

        await Check.test("decodes the native service response") {
            let json = Data("""
            {
              "label": "walking",
              "confidence": 0.87,
              "scores": {"walking": 0.87, "standing": 0.07, "running": 0.04, "sitting": 0.02},
              "modalities": ["vision", "audio"],
              "latency_ms": 412
            }
            """.utf8)

            let prediction = try Prediction.decode(from: json)

            Check.equal(prediction.activity, .walking)
            Check.close(prediction.confidence, 0.87)
            Check.equal(prediction.modalities, [.vision, .audio])
            Check.equal(prediction.latencyMilliseconds, 412)
            Check.equal(prediction.scores.map(\.activity), [.walking, .standing, .running, .sitting])
            Check.equal(prediction.runnerUp?.activity, .standing)
            Check.close(prediction.margin, 0.80)
        }

        await Check.test("decodes the Gradio `data` envelope from a bare Colab deploy") {
            let json = Data("""
            {"data": [{"label": "Sitting", "confidence": 0.62,
                       "scores": {"sitting": 0.62, "standing": 0.30, "walking": 0.05, "running": 0.03}}]}
            """.utf8)

            let prediction = try Prediction.decode(from: json)

            Check.equal(prediction.activity, .sitting)
            // No `modalities` key means the service only reported vision.
            Check.equal(prediction.modalities, [.vision])
            Check.equal(prediction.latencyMilliseconds, nil)
        }

        await Check.test("parses prompt-templated labels from zero-shot output") {
            Check.equal(Activity(serviceLabel: "a photo of a person running"), .running)
            Check.equal(Activity(serviceLabel: "  STANDING "), .standing)
            Check.equal(Activity(serviceLabel: "cycling"), nil)
        }

        await Check.test("an out-of-vocabulary label is an error, not a silent default") {
            let json = Data(#"{"label": "cycling", "confidence": 0.9, "scores": {"cycling": 0.9}}"#.utf8)
            Check.throwsError({ _ = try Prediction.decode(from: json) }) { error in
                Check.equal(error as? PredictionError, .unknownLabel("cycling"))
            }
        }

        await Check.test("confidence outside 0...1 is rejected") {
            let json = Data(#"{"label": "walking", "confidence": 1.4, "scores": {"walking": 1.4}}"#.utf8)
            Check.throwsError({ _ = try Prediction.decode(from: json) })
        }

        await Check.test("an unrecognised score key does not break the flow") {
            let json = Data("""
            {"label": "running", "confidence": 0.71,
             "scores": {"running": 0.71, "walking": 0.29, "_entropy": 0.44}}
            """.utf8)

            let prediction = try Prediction.decode(from: json)
            Check.equal(prediction.scores.count, 2)
            Check.equal(prediction.scores.map(\.activity), [.running, .walking])
        }

        await Check.test("an empty Gradio `data` array is rejected") {
            let json = Data(#"{"data": []}"#.utf8)
            Check.throwsError({ _ = try Prediction.decode(from: json) })
        }

        await Check.test("a fixture's stated label is always its argmax") {
            // Regression: the low-confidence fixture used to hand the named
            // runner-up more mass than the top-1, yielding a negative margin.
            // 0.26 sits just above the 1/4 floor, where clamping only the
            // named runner-up used to let the tail overtake the stated label.
            for confidence in [0.26, 0.28, 0.30, 0.34, 0.52, 0.88] {
                let prediction = Prediction.sample(.sitting, confidence: confidence, runnerUp: .standing)
                Check.equal(prediction.scores.first?.activity, prediction.activity,
                            "top score should be the stated label at conf \(confidence)")
                Check.expect(prediction.margin > 0,
                             "margin was \(prediction.margin) at conf \(confidence)")
                let total = prediction.scores.reduce(0) { $0 + $1.score }
                Check.close(total, 1.0, accuracy: 1e-9)
            }
        }

        Check.suite("Request encoding")

        await Check.test("multipart body carries the image and the audio clip") {
            let body = HTTPImageBindClient.multipartBody(
                boundary: "TESTBOUNDARY",
                frame: .sample(),
                audio: .sample()
            )
            let text = String(decoding: body, as: UTF8.self)

            Check.expect(text.contains(#"name="image"; filename="frame.jpg""#), "missing image part")
            Check.expect(text.contains("Content-Type: image/jpeg"), "missing image content type")
            Check.expect(text.contains(#"name="audio"; filename="clip.wav""#), "missing audio part")
            Check.expect(text.contains("Content-Type: audio/wav"), "missing audio content type")
            Check.expect(text.contains(#"name="source""#), "missing source field")
            Check.expect(text.hasSuffix("--TESTBOUNDARY--\r\n"), "missing closing boundary")
        }

        await Check.test("multipart body omits the audio part when there is no clip") {
            let body = HTTPImageBindClient.multipartBody(
                boundary: "TESTBOUNDARY",
                frame: .sample(),
                audio: nil
            )
            let text = String(decoding: body, as: UTF8.self)
            Check.expect(text.contains(#"name="image""#), "missing image part")
            Check.expect(!text.contains(#"name="audio""#), "audio part should be absent")
        }

        Check.suite("HUD text budget")

        await Check.test("a long headline truncates on a word boundary") {
            let frame = DisplayFrame(headline: "Could not reach the prediction server")
            Check.expect(
                frame.headline.count <= DisplayFrame.Budget.headline,
                "headline \"\(frame.headline)\" is \(frame.headline.count) chars"
            )
            Check.expect(frame.headline.hasSuffix("…"), "should be elided")
            Check.expect(!frame.headline.contains(" …"), "should not leave a dangling space")
        }

        await Check.test("a frame never offers more actions than the HUD fits") {
            let frame = DisplayFrame(
                headline: "Result",
                actions: [
                    .init(id: .tryAgain, title: "Try Again"),
                    .init(id: .dismiss, title: "Dismiss"),
                    .init(id: .analyze, title: "Analyze"),
                ]
            )
            Check.equal(frame.actions.count, DisplayFrame.Budget.maxActions)
        }

        await Check.test("every activity label fits alongside its glyph") {
            for activity in Activity.allCases {
                let headline = "\(activity.glyph) \(activity.displayName)"
                Check.equal(
                    DisplayFrame(headline: headline).headline,
                    headline,
                    "\(activity) headline should not need truncation"
                )
            }
        }
    }
}
