# Demo script — one to two minutes

The video has to show four things: **capture, prediction, display, retry.**
That is the whole grading criterion; everything else is optional.

## Before you record

- [ ] `Secrets.xcconfig` points at a service that is awake. Warm it with one
      request first — a cold Colab GPU will blow the 12 s timeout on take one.
- [ ] `SPEECH_ENABLED = YES` only if you are demonstrating the voice feature.
      It costs ~2 s on the following trial because A2DP and HFP cannot both be
      active, so leave it off for the timed portion.
- [ ] Glasses charged above 20%, worn, and unfolded. The camera will not stream
      otherwise.
- [ ] Screen-record the phone. You cannot film through a waveguide, so the
      phone mirror is what makes the HUD legible on video.
- [ ] Everyone on camera has consented. No bystanders, no private spaces.

## Beats

**0:00 – 0:10 — Setup.** One sentence: paired iOS app, Ray-Ban Display, four
activities, ImageBind running off-glasses. Show the Ready frame.

**0:10 – 0:35 — A confident trial.** Tap Analyze. Let the three Analyzing
sub-steps land on camera — they are the evidence that capture and inference are
separate steps. Show the result with its confidence, then tap Try Again and get
a second correct result. This one beat covers capture, prediction, display and
retry.

**0:35 – 0:55 — The low-confidence fallback.** Frame a genuinely ambiguous
shot, or point at a fixture you know scores below 0.45. Show the HUD declining
to answer rather than guessing. Say out loud that the floor is 0.45 and that
the app stays silent here on purpose.

**0:55 – 1:20 — The endpoint failure.** Kill the tunnel, or use
`mock_server.py` with `?mode=timeout`. Show the retry message, then bring the
service back and show Try Again succeeding. Recovering on camera is worth more
than the failure itself.

**1:20 – 1:40 — Optional.** The Herald companion mirroring the last prediction,
or a spoken result. Say explicitly that Herald is not the required path.

**1:40 – 2:00 — Close.** One line on the failure case from the report, and one
line on what you would do next.

## If you only have the Mock Device Kit

Say so on camera, in one sentence, early. The mock kit has no display
emulation, so the phone mirror is the only HUD that exists on that path, and
the app says so on screen. Claiming otherwise is the kind of thing a grader
notices. Everything else — registration, permissions, streaming, capture,
the full state machine — is genuinely exercised.
