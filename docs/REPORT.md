# Activity Assistant — one-page report

**Assignment 3, Multimodal Machine Learning** · Team *(fill in)* · *(date)*

> Numbers below reference [`TEST_RESULTS.md`](TEST_RESULTS.md), which is
> currently a **scripted placeholder**. Re-run the trials on device and update
> both files before submitting.

## App flow

The wearer taps **Analyze** on the Ray-Ban Display. The paired iPhone captures
one frame from the glasses camera through the Device Access Toolkit, optionally
records a two-second clip from the glasses microphone, and posts both to the
Assignment 2 ImageBind service. The returned label and confidence are rendered
back on the HUD with a **Try Again** button. No model runs on the phone or the
glasses.

```
Ray-Ban Display camera → DAT iOS app → ImageBind endpoint → DAT iOS app → glasses display
```

Five states, each one screen on the HUD:

| State | HUD |
|---|---|
| Ready | `Activity Assistant` / *Tap Analyze to start* |
| Analyzing | `Capturing…` → `Listening…` → `Analyzing…` |
| Result | `🏃 Running` / *87% confident* / **Try Again** |
| Low confidence | `Not sure` / *Maybe Sitting · retry* / **Try Again** |
| Failure | `Server took too long` / *Tap to retry* / **Try Again** |

Analyzing is split into three visible sub-steps rather than one spinner. Over
Bluetooth the capture alone can take a second, and a wearer staring at an
undifferentiated spinner cannot tell a slow camera from a dead endpoint.

Two decisions about what *not* to show. Failure messages on the HUD are one
short sentence with no error codes — the full diagnostic goes to the phone log
instead, because the panel is glanceable and a wearer cannot act on an HTTP
status. And a low-confidence guess is never spoken aloud: announcing an answer
we are about to caveat is worse than staying quiet.

## Test results

> *Scripted replay, not measured. Every figure in this section and the next is
> a placeholder — see [`TEST_RESULTS.md`](TEST_RESULTS.md).*

Eight trials, two per activity. **5 of 6** confident predictions were correct
(83%); one trial fell below the confidence floor and was declined, and one hit
an endpoint failure. Median end-to-end latency was **1.9 s**.

Audio was attached on every trial. It separates walking from running clearly —
footfall cadence is low-frequency and survives the 8 kHz HFP ceiling — and does
essentially nothing for sitting versus standing, which is a posture question
that a microphone cannot answer.

## Failure case: standing read as sitting (trial 7)

> *Illustrative. The analysis below is the one this failure mode calls for, but
> the trial it is written against is scripted, not observed.*

The subject was standing while leaning on a desk. The model returned **sitting
at 0.52**, above the 0.45 floor, so the app asserted a wrong answer confidently
rather than declining.

The cause is the camera position. The glasses camera is at eye level and points
outward, so a first-person frame of your own posture contains almost no
evidence of it — what ImageBind actually sees is a desk, a chair back and a
torso at desk height, which is a much better match for the "sitting on a chair"
prompt than for "standing upright". This is a systematic weakness of the
egocentric viewpoint, not a bad frame: **the wearer's own body is the one thing
the wearer's camera cannot see.** The confusion is one-directional in our
trials, standing → sitting, which fits that explanation.

Two things follow. First, the margin is the honest signal here, not the
confidence: 0.52 with the runner-up at 0.29 is a much weaker claim than 0.52
against a flat tail, which is why the trial log records margin separately.
Second, the realistic fix is not a better prompt but a different modality —
IMU-based posture would settle it immediately, and the toolkit does not expose
the IMU on this path. Raising the floor to catch this trial would also have
rejected trial 7's legitimate neighbours and cost more than it saved.

## Design choice: keeping the camera stream warm

**DAT has no one-shot photo API.** `capturePhoto` is only valid while a video
stream is already running, so the obvious implementation is
`addStream → start → capturePhoto → stop` on every tap. Over Bluetooth Classic
that startup dominates: the wearer waits well over a second before the shutter,
on every single retry.

`DATWearableDevice` instead keeps the stream **warm**. It starts on the first
capture and stays up for 20 seconds afterwards, so the common Result → Try
Again → Result loop pays the startup cost once instead of three times. Twenty
seconds was chosen to cover the gap between a result appearing and the wearer
tapping retry (assumed ~3 s; measure this on device) with wide margin, while
still being well short of a demo-length idle.

The trade-off is real and is the reason for the timeout rather than holding the
stream open forever: a live video stream is the dominant battery draw on the
glasses, and the panel itself sleeps after 25 seconds of inactivity. Holding a
stream through an idle demo would drain the device to buy latency nobody is
waiting on. The 20-second window sits just inside that sleep boundary, so the
stream and the display go quiet at roughly the same time.

## What we would do next

Add the IMU if a later toolkit version exposes it on the DAT path — it is the
single change that would fix the posture confusion. Failing that, capture a
short burst rather than one frame and vote across it, which costs nothing extra
now that the stream is already running.
