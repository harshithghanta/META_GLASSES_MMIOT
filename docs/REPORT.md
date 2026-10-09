# Activity Assistant — one-page report

**Assignment 3, Multimodal Machine Learning** · Team *(fill in)* · *(date)*

> **No on-device trials have been run yet.** Numbers below come from
> [`TEST_RESULTS.md`](TEST_RESULTS.md), which holds **simulated** output from a
> scripted harness. Run the trials on device and replace both files' numbers
> before submitting.

## App flow

The wearer taps **Analyze** on the Ray-Ban Display. The paired iPhone captures
one frame from the glasses camera through the Device Access Toolkit, optionally
records a two-second clip from the glasses microphone, and posts both to an
ImageBind service. The included service runs pretrained ImageBind zero-shot
against one text prompt per activity; nothing is fine-tuned. The returned
label and confidence are rendered
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
Bluetooth the capture alone is expected to take about a second (not yet
measured), and a wearer staring at an
undifferentiated spinner cannot tell a slow camera from a dead endpoint.

Two decisions about what *not* to show. Failure messages on the HUD are one
short sentence with no error codes — the full diagnostic goes to the phone log
instead, because the panel is glanceable and a wearer cannot act on an HTTP
status. And a low-confidence guess is never spoken aloud: announcing an answer
we are about to caveat is worse than staying quiet.

## Test results

> *Simulated, not measured. Every figure in this section and the next comes
> from a scripted harness — see [`TEST_RESULTS.md`](TEST_RESULTS.md). No
> on-device trials have been run.*

The scripted harness replays eight trials, two per activity: 5 of 6 confident
predictions "correct" (83%), one declined below the confidence floor, and one
endpoint failure. These numbers were chosen to exercise each code path. They
are not results.

Hypothesis, untested: audio should help separate walking from running, since
footfall cadence is low-frequency and should survive the 8 kHz HFP ceiling. It
should do essentially nothing for sitting versus standing, which is a posture
question a microphone cannot answer.

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
the wearer's camera cannot see.** Whether the confusion is one-directional
(standing → sitting) has to be checked on real trials.

Two things follow. First, the margin is the honest signal here, not the
confidence: 0.52 with the runner-up at 0.29 is a much weaker claim than 0.52
against a flat tail, which is why the trial log records margin separately.
Second, the realistic fix is not a better prompt but a different modality —
IMU-based posture would settle it immediately, and the toolkit does not expose
the IMU on this path. Raising the floor would catch this trial. In the scripted
table it would cost nothing, since the lowest correct confident trial is at
0.69. Whether it costs correct answers in practice depends on real trial data.
The 0.45 floor itself is a provisional default, not tuned on validation data.

## Design choice: keeping the camera stream warm

**DAT has no one-shot photo API.** `capturePhoto` is only valid while a video
stream is already running, so the obvious implementation is
`addStream → start → capturePhoto → stop` on every tap. Over Bluetooth Classic
that startup is expected to dominate (not yet measured), making the wearer wait
before the shutter on every retry.

`DATWearableDevice` instead keeps the stream **warm**. It starts on the first
capture and stays up for 20 seconds afterwards, so the common Result → Try
Again → Result loop pays the startup cost once instead of three times. Twenty
seconds is a design assumption, not a measurement, chosen to cover the gap between a result appearing and the wearer
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
