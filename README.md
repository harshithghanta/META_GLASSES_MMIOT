# Activity Assistant — Meta Ray-Ban Display

Assignment 3, Multimodal Machine Learning.

A paired iOS app that captures one frame from Ray-Ban Display glasses through
Meta's Device Access Toolkit, sends it (plus an optional two-second audio clip)
to the Assignment 2 ImageBind service, and renders the predicted activity back
on the glasses. The model runs off-glasses; nothing is trained here.

Activities: **walking · running · sitting · standing**

---

## Read this first: what is verified, and what is not

Being straight about this matters more than the code.

| Part | Status |
|---|---|
| Flow state machine, display copy, error handling | **Verified.** `swift run corecheck` — 30 checks, runs on any machine with the Swift toolchain. |
| Client ⇄ service wire contract | **Verified end-to-end.** `python3 scripts/smoke_test.py` — 32 checks. It starts the service, posts a real multipart body, and pipes the real response through the real Swift decoder. |
| Herald companion | **Verified in a browser** against the live service, in its live, stale, low-confidence and unreachable states. |
| `ios-app/ActivityAssistant/DAT/*` — the DAT bridge | **Compiles and type-checks**, under Swift 6 strict concurrency, against shape-only stubs of the DAT API — `cd ios-app/DATBridgeCheck && swift build`. Signatures still need reconciling against the real SDK on first Xcode build. |
| The rest of the iOS app (SwiftUI, `AVAudioSession`) | **Not compiled.** UIKit and `AVAudioSession` are iOS-only, so these need Xcode. |
| Live demo, demo video, contribution statement | **Not produced.** These need the hardware, the team and you. See [`docs/DEMO_SCRIPT.md`](docs/DEMO_SCRIPT.md) and [`docs/CONTRIBUTIONS.md`](docs/CONTRIBUTIONS.md), which are prepared for you to fill in. |

The whole architecture follows from that split. `WearableDevice` is a protocol
precisely so the interesting logic could be tested without a headset, and so
the same engine drives the mock and the real glasses.

### Why the DAT bridge is compiled against stubs

An uncompiled, concurrency-heavy file is where bugs hide, and the real SDK is
locked behind a Meta developer account. So `ios-app/DATBridgeCheck` contains
hand-written stubs matching the *shape* of the documented DAT 0.8.0 API, plus
**symlinks** to the real bridge sources — one copy of the code, no drift.

It earned its keep immediately. Compiling the bridge for the first time
surfaced three defects that reading had not:

- `self.photoContinuation = continuation` inside an `@escaping @Sendable`
  closure — a cross-actor mutation, and a **hard compile error even in Swift 5
  mode**. The bridge did not build at all.
- `MWDATCamera.Stream` collides with `Foundation.Stream`; the unqualified name
  was ambiguous.
- `MockDeviceKitHarness.pairedDevice` was nonisolated global mutable state,
  which Swift 6 rejects.

**What this proves:** the bridge is internally consistent, actor isolation is
correct, and continuations are resumed exactly once.
**What it does not prove:** that the stub signatures match the real binary.
They come from Meta's published API reference. Expect to reconcile names on the
first Xcode build — but the *logic* underneath is checked.

### Two findings that will affect your demo plan

1. **The Mock Device Kit does not emulate the display.** As of DAT 0.8.0 there
   is `MockCameraKit`, `MockCaptouchKit` and `MockPermissions`, but no
   `MockDisplayKit`, and the only documented pairing model is `.rayBanMeta`,
   which has no display at all. Camera capture is fully mockable; **the HUD
   half of this assignment can only be shown on real Ray-Ban Display
   hardware.** On the mock path the app renders the HUD on the phone instead,
   and says so on screen rather than pretending.
2. **An app that links DAT cannot be submitted to the App Store.** The SDK uses
   `ExternalAccessory`. Irrelevant for grading, relevant if you were planning
   to ship it.

---

## Layout

```
ActivityAssistantCore/     Platform-free logic. Builds and self-checks anywhere.
  Sources/ActivityAssistantCore/
    ActivityAssistantEngine.swift   Ready → Analyzing → Result / Retry
    FlowState.swift                 The five states, plus the trial log
    DisplayFrame.swift              What the wearer sees, device-independent
    WearableDevice.swift            The seam: real glasses, mock, or scripted
    ImageBindClient.swift           Multipart client for the A2 service
    Prediction.swift                Wire format, both response shapes
  Sources/CoreCheck/                The check suite and the trial replay

ios-app/ActivityAssistant/
  DAT/DATWearableDevice.swift       Session, warm stream, capture, display
  DAT/GlassesDisplayRenderer.swift  DisplayFrame → DAT view tree
  DAT/HFPAudioRecorder.swift        Glasses mic over Bluetooth HFP
  DAT/GlassesSpeaker.swift          Spoken result over A2DP
  DAT/MockDeviceKitHarness.swift    Official Mock Device Kit setup
  DAT/MirroringWearableDevice.swift Mirrors the HUD onto the phone
  DAT/AudioPorts.swift              Seams that keep the bridge compilable
  Views/ContentView.swift           Phone UI and 600 × 600 HUD preview
ios-app/DATBridgeCheck/             Stub SDK; type-checks the bridge on a laptop

imagebind-service/
  app.py                            FastAPI wrapper around the A2 model
  mock_server.py                    Stdlib-only mock, with failure injection

herald-companion/index.html         Optional 600 × 600 display-only mirror
scripts/smoke_test.py               Client ⇄ service contract check
docs/                               Report, test results, demo script
```

---

## Quick start, no hardware and no Xcode

Everything in this section runs on a plain Mac with the Swift toolchain.

```bash
# 1. The flow, the display copy, the error handling
cd ActivityAssistantCore && swift run corecheck

# 2. The eight-trial table in docs/TEST_RESULTS.md
swift run corecheck --trials

# 3. The client ⇄ service contract, end to end
cd .. && python3 scripts/smoke_test.py

# 4. The DAT bridge type-checks under Swift 6 strict concurrency
cd ios-app/DATBridgeCheck && swift build
```

To see the Herald companion against a live service:

```bash
python3 imagebind-service/mock_server.py --port 8000 &
cd herald-companion && python3 -m http.server 8080 &
# seed a prediction, then open:
#   http://127.0.0.1:8080/index.html?api=http://127.0.0.1:8000
```

---

## Building the iOS app

### 1. Prerequisites

- **Xcode 16+.** `project.yml` sets `SWIFT_VERSION = 6.0`, which earlier Xcode
  releases cannot build. (The DAT SDK itself only requires 14+, but this app
  does not.) Only Command Line Tools are needed for the checks above.
- **iPhone on iOS 15.2+.** This app targets iOS 17 because it uses
  `Observation` and `AsyncStream.makeStream`.
- **Meta AI app v272+**, glasses firmware **v127+**.
- A **Managed Meta Account**, or Developer Mode (below), which is far quicker.

### 2. Register the app

The fast path for a class project is **Developer Mode**: in the Meta AI app,
Settings → App Info → tap the version five times → Enable Developer Mode. In
Developer Mode registration is always allowed, attestation is skipped, and
`MetaAppID` / `ClientToken` may stay `0`. No allowlist application is needed.

One catch: in Developer Mode only **one** third-party app can be registered at
a time. Registering another silently unregisters this one.

For a release-channel build instead, create a project at
[wearables.developer.meta.com](https://wearables.developer.meta.com), add your
app under Configuration, and copy the Application ID and Client Token into
`Secrets.xcconfig`.

### 3. Configure

```bash
cp ios-app/Secrets.example.xcconfig ios-app/Secrets.xcconfig
# then edit it — IMAGEBIND_ENDPOINT is the only required value
```

`Secrets.xcconfig` is git-ignored. **Do not commit your endpoint or token**;
the assignment rules are explicit about this.

Note the endpoint is written *without* `https://`. xcconfig treats `//` as a
comment anywhere on a line and would silently eat it, so the scheme is a
separate key that `Configuration.swift` rejoins.

### 4. Generate the project and run

```bash
brew install xcodegen
cd ios-app && xcodegen generate && open ActivityAssistant.xcodeproj
```

The `.xcodeproj` is deliberately not committed: a generated project keeps
diffs readable and avoids the `pbxproj` merge conflicts a four-person team
otherwise hits. If you would rather not use XcodeGen, `project.yml` is short
enough to read as a spec for a manual target: an iOS app target over
`ActivityAssistant/`, `Secrets.xcconfig` as the config file for both
configurations, a local package dependency on `../ActivityAssistantCore`, and
SwiftPM package `https://github.com/facebook/meta-wearables-dat-ios` at exactly
`0.8.0` with products `MWDATCore`, `MWDATCamera`, `MWDATDisplay`,
`MWDATMockDevice`.

### 5. Mock Device Kit

Set `USE_MOCK_DEVICE = YES` in `Secrets.xcconfig`, then put eight fixture files
in `ios-app/Fixtures/`:

```
walking_feed.mp4   walking_still.jpg
running_feed.mp4   running_still.jpg
sitting_feed.mp4   sitting_still.jpg
standing_feed.mp4  standing_still.jpg
```

The videos **must be H.265**. The iOS sample transcodes automatically but the
kit itself will show a black feed for H.264:

```bash
ffmpeg -i input.mp4 -c:v hevc_videotoolbox -tag:v hvc1 -an walking_feed.mp4
```

Record only consenting participants, and keep the fixtures out of the repo
(`.gitignore` already excludes `ios-app/Fixtures/`).

---

## The ImageBind service

The app posts to `POST {IMAGEBIND_ENDPOINT}/predict` as `multipart/form-data`:

| Part | Required | Content |
|---|---|---|
| `image` | yes | one JPEG frame from the glasses |
| `audio` | no | mono 16 kHz WAV, ~2 s |
| `source` | no | a string identifying the app |

A successful response:

```json
{
  "label": "walking",
  "confidence": 0.87,
  "scores": {"walking": 0.87, "standing": 0.07, "running": 0.04, "sitting": 0.02},
  "modalities": ["vision", "audio"],
  "latency_ms": 412
}
```

The client also accepts a bare Gradio `/run/predict` response, which wraps the
same object in a one-element `data` array — so **an existing Assignment 2
Gradio deployment works unchanged**. Point `IMAGEBIND_ENDPOINT` at it and skip
`app.py` entirely.

`app.py` exists so the pipeline is reproducible from a clean checkout. It also
serves `GET /latest` for the Herald companion, which returns the most recent
prediction and never the frame or the audio.

### Failure injection

`mock_server.py` can misbehave on demand, which is how the required
endpoint-failure trial is produced without waiting for Colab to actually die:

```
/predict?mode=low        below the confidence floor
/predict?mode=timeout    hangs past the client's 12 s budget
/predict?mode=error      HTTP 503
/predict?mode=garbage    200 with an HTML body (an expired tunnel)
/predict?label=running   force a specific activity
```

---

## Herald companion (optional)

`herald-companion/index.html` is a single self-contained page that polls
`/latest` and mirrors the result. It is **display only**, and it is **not the
required implementation** — the graded path is the native DAT app. Do not
upload the Xcode project to Herald.

Worth knowing: **Herald is a third-party platform**
([herald.ascents.gg](https://herald.ascents.gg)), not a Meta product. Its
footer says so explicitly. Publishing goes through `/studio`, either by linking
a public Git repo or uploading a folder, then submitting to the Hub for review.

The page is built for the real constraints of the panel: a fixed 600 × 600
viewport with no scrolling, an additive waveguide where pure black is fully
transparent, and keyboard-only input (arrow keys move focus, Enter activates,
Escape goes back). There is no cursor and no touch.

Configure it once with `?api=https://your-service`, which it stores in
`localStorage`. Nothing personal goes in the URL, and the page carries no
analytics or trackers.

---

## Privacy

- The frame and the audio clip live only for the duration of one request. The
  service holds the latest *prediction* for the Herald mirror; it never stores
  or serves the raw media.
- `/latest` exposes labels and scores only.
- Record only consenting participants, and avoid bystanders and private
  spaces. The glasses' capture LED must remain visible.
- No tokens, endpoints or GitHub credentials are committed; everything
  sensitive lives in `Secrets.xcconfig`, which is git-ignored.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Every permission request fails | The app is not registered. Open the Meta AI app and approve it, or check Developer Mode is on. |
| Registered, but it stopped working after you built another DAT app | Developer Mode allows only one registered third-party app at a time. |
| `capturePhoto` returns nothing | There is no running stream. Capture is only valid while streaming; `DATWearableDevice` handles this, but a manual call will not. |
| HUD goes dark and never returns | The wearer's two-finger temple tap ends the display session. `DATWearableDevice` watches for this and re-attaches. |
| Audio always falls back to the phone mic | The HFP route was not acquired, or the camera stream started before it settled. Acquire the route first. |
| Spoken results kill audio capture | A2DP and HFP are mutually exclusive. This is why `SPEECH_ENABLED` defaults to `NO`. |
| Mock camera feed is black | The fixture video is H.264. Transcode to H.265. |
| `IMAGEBIND_ENDPOINT is not set` | `Secrets.xcconfig` is missing, or the URL still has `//` in it. |
