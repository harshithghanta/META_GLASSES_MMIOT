# Scripted harness results (simulated, not device trials)

> ## ⚠️ No on-device trials have been run yet
>
> Nothing in this file is a measurement. The table below is the output of
> `swift run corecheck --trials`. That command replays eight **scripted**
> responses through the real state machine, with a scripted device, a
> scripted service and a scripted clock. The labels, confidences, margins,
> timings and notes were all chosen by hand to exercise each code path: a
> confident hit, a low-confidence decline, a confident miss and an endpoint
> failure. Only the code paths are real.
>
> **Replace this table with a real run before submitting.** Presenting these
> rows as experimental results would be fabrication.
>
> To regenerate after editing the trial list in
> `ActivityAssistantCore/Sources/CoreCheck/Entry.swift`:
>
> ```bash
> cd ActivityAssistantCore && swift run corecheck --trials
> ```

## Setup (fill in for the real run)

| | |
|---|---|
| Device | *(Ray-Ban Display, firmware v___ / Mock Device Kit)* |
| Meta AI app | *v272 or later* |
| Service | *(local `app.py` / Colab tunnel running `app.py` / other)* |
| Audio | glasses mic over Bluetooth HFP, 8 kHz mono, upsampled to 16 kHz |
| Confidence floor | 0.45 (provisional default, not tuned) |
| Client timeout | 12 s |
| Date | *(fill in)* |

The assignment asks for two trials per activity, including one low-confidence
trial and one endpoint-failure trial.

## Simulated table (harness output)

| # | Ground truth | Outcome | Top-1 | Conf. | Margin | Audio | Time | Notes |
|---|---|---|---|---|---|---|---|---|
| 1 | Walking | ✅ correct | Walking | 0.88 | 0.81 | yes | 1.9 s | Hallway, even lighting |
| 2 | Walking | ✅ correct | Walking | 0.74 | 0.58 | yes | 2.1 s | Turning a corner, motion blur |
| 3 | Running | ✅ correct | Running | 0.91 | 0.86 | yes | 1.8 s | Treadmill, audio clearly helped |
| 4 | Running | ✅ correct | Running | 0.83 | 0.73 | yes | 2.0 s | Outdoors, wind on the mic |
| 5 | Sitting | ✅ correct | Sitting | 0.69 | 0.50 | yes | 1.7 s | Desk, subject facing camera |
| 6 | Sitting | ⚠️ low-confidence | Sitting | 0.34 | 0.03 | yes | 1.8 s | LOW CONFIDENCE — waist-up crop, no chair visible |
| 7 | Standing | ❌ wrong | Sitting | 0.52 | 0.23 | yes | 1.9 s | MISS — leaning on a desk, read as sitting |
| 8 | Standing | 🛑 Server took too long | — | — | — | yes | 12.0 s | ENDPOINT FAILURE — Colab tunnel recycled |

- Trials: **8** across all four activities (2 each)
- Confident answers: **6** — of these, **5 correct** (83%)
- Declined (below the 0.45 floor): **1**
- Endpoint failures: **1**
- Median end-to-end latency on completed trials: **1.9 s** (mean 1.9 s)

The "Notes" column is scripted text, not observations. "Margin" is the gap
between top-1 and top-2. Record it in the real run, because a low margin
shows when the model is choosing between two classes (e.g. sitting vs
standing) more honestly than the top-1 confidence does.

This table was transcribed from the harness code, and every number was
re-derived by hand from `Prediction.sample`. The harness was not re-run while
writing this file. Run the command above to confirm it matches exactly.

## What the required trial types should demonstrate

**Low confidence.** Below the 0.45 floor, the HUD shows
`Not sure / Maybe <Activity> · retry` instead of asserting an answer, and the
result is not spoken. Log it as *declined*, not *wrong*.

**Endpoint failure.** The request exceeds the 12 s client budget and the HUD
shows `Server took too long / Tap to retry`. To reproduce it without waiting
for a real outage:

```bash
python3 imagebind-service/mock_server.py --host 0.0.0.0 --port 8000
# set IMAGEBIND_SCHEME = http and IMAGEBIND_ENDPOINT = <your-mac-LAN-IP>:8000,
# then trigger /predict?mode=timeout (or call /predict with no query until the
# six-step cycle reaches its timeout step)
```

Record whether the retry after the failure succeeded. That is something to
observe on device, not assume.

## Recording your own run

1. Set `USE_MOCK_DEVICE` appropriately in `Secrets.xcconfig`.
2. Run the app, tap Analyze once per trial, and swap the mock fixture (or the
   real activity) between trials.
3. The phone UI logs each trial live; `AppModel.trials` holds the same records.
4. Replace the table and summary above, retitle this file, and update the
   report.

The failure-path trials do not need to be last. The engine allows a retry from
any terminal state, so a failure mid-run is realistic and worth capturing.
