# Activity Assistant — Meta Ray-Ban Display

Assignment 3, Multimodal Machine Learning.

A paired iOS app that captures one frame from Ray-Ban Display glasses through
Meta's Device Access Toolkit, sends it (plus an optional two-second audio clip)
to an ImageBind service, and renders the predicted activity back on the
glasses. The model runs off-glasses. The included service (`app.py`) uses
pretrained ImageBind zero-shot with one text prompt per class; nothing is
trained or fine-tuned here.

Activities: **walking · running · sitting · standing**

---

## Verification status — read this first

Nothing in this repo has run on glasses, and the iOS app has never been
compiled. What has and has not been checked:

**Run (passing):**

- `python3 scripts/smoke_test.py`: the Python half of its checks (service
  contract, failure modes, `/latest`) against `mock_server.py`. Its other
  checks pipe responses through the Swift decoder (`swift run corecheck
  --decode`) and need a Swift toolchain.
- `app.py`'s FastAPI layer (multipart parsing, response shape, auth,
  vision-only fallback, `/latest`), with ImageBind and torch replaced by small
  fakes. The real model's loading and its confidence calibration have **not**
  been run.
- Herald companion: checked by hand in a browser against the mock service.

**Written but not re-run after the latest changes:** `swift run corecheck` (31
checks of the flow state machine, display copy and wire decoding). It needs
only the Swift toolchain. It has not been run in CI. Run it yourself before
trusting it.

**Type-checked only, against stubs:** `ios-app/ActivityAssistant/DAT/*`, via
`cd ios-app/DATBridgeCheck && swift build` (macOS). The stubs are transcribed
from the real DAT 0.8.0 `.swiftinterface` files, and every SDK call site was
checked by hand against those files. The real binary SDK has never been linked.

**Untested:**

- Building the app in Xcode.
- Anything on real Ray-Ban Display glasses or the Mock Device Kit.
- The HFP microphone path and spoken results.
- The real ImageBind model.
- The 0.45 confidence floor. It is a provisional default, not a tuned value.
- The live demo, demo video and contribution statement. These need the
  hardware and the team. See [`docs/DEMO_SCRIPT.md`](docs/DEMO_SCRIPT.md) and
  [`docs/CONTRIBUTIONS.md`](docs/CONTRIBUTIONS.md).

`WearableDevice` is a protocol so the flow logic can be exercised without a
headset, and so the same engine drives the mock and the real glasses.

### Why the DAT bridge is type-checked against stubs

The DAT SDK ships as binary xcframeworks. Their public `.swiftinterface` files
are readable in the public `facebook/meta-wearables-dat-ios` repo at tag
`0.8.0`. `ios-app/DATBridgeCheck` contains stubs that mirror those signatures
for every symbol the app uses, plus **symlinks** to the real bridge sources, so
the bridge can be type-checked on a Mac without Xcode or the iOS SDK.

An earlier version of these stubs was written from documentation and hid
several real mismatches. For example, `Stream` has no `stateStream()`,
`DeviceSession` has no `removeStream()`/`removeDisplay()`, the icon names
were wrong, `services` lives on `MockGlasses`, and `startRegistration()` is
`async`. Those were fixed by diffing against the real interface.

**What this shows:** the bridge type-checks against the real API *as
transcribed*.
**What it does not show:** runtime behaviour. That includes actor reentrancy,
whether continuations resume exactly once in practice, and how the device
actually behaves. Only a real build on a device can show that.

### Two findings that will affect your demo plan

1. **The Mock Device Kit does not emulate the display.** In DAT 0.8.0 there is
   `MockCameraKit`, `MockCaptouchKit` and `MockPermissions`, but no
   `MockDisplayKit`. None of the mock glasses models (`.rayBanMeta`,
   `.oakleyMetaHSTN`, `.oakleyMetaVanguard`, `.rayBanMetaOptics`,
   `.metaGlasses`) is the Ray-Ban Display. Camera capture is mockable; **the HUD
   half of this assignment can only be shown on real Ray-Ban Display
   hardware.** On the mock path the app renders the HUD on the phone instead,
   and says so on screen rather than pretending.
2. **An app that links DAT may not be submittable to the App Store.** The app
   declares `ExternalAccessory` usage. This has not been confirmed with Meta or
   Apple. Irrelevant for grading, relevant if you were planning to ship it.

---

## Layout

```
ActivityAssistantCore/     Platform-free logic. Builds and self-checks anywhere.
  Sources/ActivityAssistantCore/
    ActivityAssistantEngine.swift   Ready → Analyzing → Result / Retry
    FlowState.swift                 The five states, plus the trial log
    DisplayFrame.swift              What the wearer sees, device-independent
    WearableDevice.swift            The seam: real glasses, mock, or scripted
    ImageBindClient.swift           Multipart client for the ImageBind service
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
  app.py                            FastAPI service: zero-shot ImageBind + prompts
  mock_server.py                    Stdlib-only mock, with failure injection

herald-companion/index.html         Optional 600 × 600 display-only mirror
scripts/smoke_test.py               Client ⇄ service contract check
docs/                               Report, test results, demo script
```

---

## Quick start, no hardware and no Xcode

Everything in this section runs on a plain Mac with the Swift toolchain.
Step 4 needs macOS. Steps 1 to 3 should also work on Linux, but that has not
been tried.

```bash
# 1. The flow, the display copy, the error handling
cd ActivityAssistantCore && swift run corecheck

# 2. The simulated eight-trial table in docs/TEST_RESULTS.md (scripted, not measured)
swift run corecheck --trials

# 3. The client ⇄ mock-service contract (Swift decoder + Python service)
cd .. && python3 scripts/smoke_test.py

# 4. The DAT bridge type-checks against stubs of the real 0.8.0 API
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

- **Xcode 26 (iOS 26 SDK).** `HFPAudioRecorder` uses
  `AVAudioSession.CategoryOptions.allowBluetoothHFP`, which first appears in
  the iOS 26 SDK. The DAT 0.8.0 binaries were also built with Swift 6.3. With
  an older Xcode, expect compile errors. (For Xcode 16 you could switch that
  option back to `.allowBluetooth`, but that is untested.) Only Command Line
  Tools are needed for the checks above.
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

The decoder will also unwrap that same object from a one-element `data` array.
That does **not** make a stock Gradio deployment compatible. The client always
POSTs multipart/form-data to `{endpoint}/predict`, which Gradio's API does not
accept, and Gradio's `Label` output has a different shape. To use an existing
Assignment 2 model, serve it behind `app.py`'s contract.

`app.py` runs pretrained `imagebind_huge` zero-shot against four text prompts.
Nothing is fine-tuned, and no Assignment 2 checkpoint is loaded. It loads the
model at startup (`PRELOAD_MODEL=0` to defer), so the first request doesn't
time out on a ~4.5 GB download. An audio clip that can't be decoded falls
back to a vision-only prediction. It also serves `GET /latest` for the Herald
companion: the most recent prediction, never the frame or the audio. When
`IMAGEBIND_TOKEN` is set, `/latest` requires the token too, unless
`LATEST_PUBLIC=1`. The Herald page cannot send a token.

The softmax temperature (`SOFTMAX_TEMPERATURE`, default 0.05) is hand-picked,
and confidence calibration has not been validated. Treat the app's 0.45
confidence floor as provisional until it is tuned on real data.

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

The mock binds `127.0.0.1` by default. To reach it from an iPhone on the same
Wi-Fi, run it with `--host 0.0.0.0` and set the endpoint to
`http://<your-mac-LAN-IP>:8000` (`IMAGEBIND_SCHEME = http`). Info.plist allows
plain HTTP to local-network hosts (`NSAllowsLocalNetworking`). This path has
not been tried on a device.

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
