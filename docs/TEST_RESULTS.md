# Test results — eight trials

> ## ⚠️ These numbers are placeholders, not measurements
>
> Nobody has run this on glasses yet. The table below was produced by
> `swift run corecheck --trials`, which replays a **scripted** set of responses
> through the real state machine. It exists so the format, the arithmetic and
> the summary statistics are correct and so the report has something concrete
> to be written against.
>
> **Replace every row with your own run before submitting.** Presenting these
> as experimental results would be fabrication. The confidences, the notes and
> the timings are illustrative; only the code paths they exercise are real.
>
> To regenerate after editing the trial list in
> `ActivityAssistantCore/Sources/CoreCheck/Entry.swift`:
>
> ```bash
> cd ActivityAssistantCore && swift run corecheck --trials
> ```

## Setup

| | |
|---|---|
| Device | *(Ray-Ban Display, firmware v___ / Mock Device Kit)* |
| Meta AI app | *v272 or later* |
| Service | *(Colab + Gradio tunnel / local `app.py` / Replicate)* |
| Audio | glasses mic over Bluetooth HFP, 8 kHz mono, upsampled to 16 kHz |
| Confidence floor | 0.45 |
| Client timeout | 12 s |
| Date | *(fill in)* |

Two trials per activity, as required, including one low-confidence trial and
one endpoint-failure trial.

## Trials

| # | Ground truth | Outcome | Top-1 | Conf. | Margin | Audio | Time | Notes |
|---|---|---|---|---|---|---|---|---|
| 1 | Walking | ✅ correct | Walking | 0.88 | 0.81 | yes | 1.9 s | Hallway, even lighting |
| 2 | Walking | ✅ correct | Walking | 0.74 | 0.58 | yes | 2.1 s | Turning a corner, motion blur |
| 3 | Running | ✅ correct | Running | 0.91 | 0.86 | yes | 1.8 s | Treadmill, audio clearly helped |
| 4 | Running | ✅ correct | Running | 0.83 | 0.73 | yes | 2.0 s | Outdoors, wind on the mic |
| 5 | Sitting | ✅ correct | Sitting | 0.69 | 0.50 | yes | 1.7 s | Desk, subject facing camera |
| 6 | Sitting | ⚠️ low-confidence | Sitting | 0.34 | 0.03 | yes | 1.8 s | Waist-up crop, no chair visible |
| 7 | Standing | ❌ wrong | Sitting | 0.52 | 0.23 | yes | 1.9 s | Leaning on a desk, read as sitting |
| 8 | Standing | 🛑 Server took too long | — | — | — | yes | 12.0 s | Colab tunnel recycled |

- Trials: **8** across all four activities (2 each)
- Confident answers: **6** — of these, **5 correct** (83%)
- Declined, below the 0.45 floor: **1**
- Endpoint failures: **1**
- Median end-to-end latency on completed trials: **1.9 s** (mean 1.9 s)

"Margin" is the gap between top-1 and top-2. It is worth recording separately
from confidence: trial 6 and trial 7 have very different confidences but both
have the model choosing between sitting and standing, and the margin shows
that more honestly than the top-1 number does.

## What each required trial demonstrates

**Trial 6 — low confidence.** 0.34 is below the 0.45 floor, so the HUD shows
`Not sure / Maybe Sitting · retry` instead of asserting an answer, and the
result is not spoken. Logged as *declined*, not as *wrong*: correctly refusing
to answer is the behaviour the fallback requirement asks for, and folding it
into an accuracy number would hide it.

**Trial 8 — endpoint failure.** The request exceeded the 12 s client budget.
The HUD showed `Server took too long / Tap to retry` and the retry succeeded on
the next attempt. Reproducible without waiting for Colab to die:

```bash
python3 imagebind-service/mock_server.py --port 8000
# then point the app at http://<your-mac>:8000 and call
#   /predict?mode=timeout
```

## Recording your own run

1. Set `USE_MOCK_DEVICE` appropriately in `Secrets.xcconfig`.
2. Run the app, tap Analyze once per trial, and swap the mock fixture (or the
   real activity) between trials.
3. The phone UI logs each trial live; `AppModel.trials` holds the same records.
4. Copy the rows here, then update the summary line and the report.

The failure-path trials do not need to be last. The engine allows a retry from
any terminal state, so a failure mid-run is realistic and worth capturing.
