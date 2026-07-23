# Presentation guide

Two things here: a deck outline with speaker notes, and the framing decisions
behind it. The visual one-pager is a separate artifact.

---

## The frame: lead with evidence, name the boundary

The temptation is to open with "we couldn't get the glasses, so here's a mock."
That's an apology, and it invites the grader to spend the whole demo thinking
about what's missing.

Invert it. You have something most submissions won't: **a test suite that
actually runs, and a contract check that verifies the client and the service
against each other rather than against two copies of the same assumption.**
Open there. Then name the hardware boundary precisely and without hedging —
precision reads as competence, vagueness reads as cover.

The line that does the most work:

> "The interaction logic and the client-to-service contract are verified by
> automated checks that run on any laptop. The DAT bridge is the one layer we
> could not compile, and I can tell you exactly why and exactly where the seam
> is."

Then, when you explain that `WearableDevice` is a protocol *so that* the flow
could be tested without hardware, the architecture stops looking like a
workaround and starts looking like the reason the rest is verifiable.

**Say the Mock Device Kit limitation out loud, early, in one sentence.** It has
no display emulation. A grader who discovers this themselves at minute four
will discount everything before it. A presenter who states it at minute one
gets credit for knowing their tooling.

---

## Deck outline

Eleven slides, sized for roughly 8-10 minutes. Cut slides 8 and 10 first if
you're tight.

### 1 — Title
**Activity Assistant — Ray-Ban Display**
Walking / Running / Sitting / Standing. Team, date.

> Speaker note: one sentence only. "A paired iOS app that reads one frame off
> the glasses, asks our Assignment 2 ImageBind model what you're doing, and
> puts the answer back on the HUD."

### 2 — The required path
The data flow, one line, no decoration:
`glasses camera → DAT iOS app → ImageBind endpoint → DAT iOS app → glasses display`

> Speaker note: emphasize that inference is entirely off-glasses, and that
> nothing was retrained for this assignment. That's the assignment's constraint
> and you met it exactly.

### 3 — What's verified, and what isn't
The three-row table. Verified: flow logic, wire contract, Herald page.
Not compiled: the DAT bridge. Not produced: the live run.

> Speaker note: this is the slide that earns trust. Deliver it flatly, without
> apology, and move on quickly. Don't linger — lingering signals discomfort.

### 4 — The five HUD states
Ready / Analyzing / Result / Not sure / Failure, shown as five small panels.

> Speaker note: two design points worth making out loud.
> (1) Analyzing is three visible sub-steps, not one spinner — over Bluetooth
> the capture alone takes ~1s, and a wearer staring at an undifferentiated
> spinner can't tell a slow camera from a dead endpoint.
> (2) Failure messages are one short sentence with no error codes. The full
> diagnostic goes to the phone. A wearer can't act on an HTTP status.

### 5 — The design choice: keeping the camera stream warm
DAT has no one-shot photo API. `capturePhoto` is only valid while a video
stream is running.

> Speaker note: this is your strongest technical slide — it's a real constraint
> that most teams will not have hit, because most teams will not have read the
> camera docs carefully. Naive implementation is
> `addStream → start → capture → stop` per tap, which makes the wearer wait
> over a second before every shutter. Warm stream, 20s idle window, torn down
> after because a live video stream is the dominant battery draw. Mention the
> 25s display sleep — the two go quiet together, which is the detail that shows
> you thought about it rather than picked a round number.

### 6 — The failure case: standing read as sitting
Trial 7. The model said sitting at 0.52, above the floor, so the app asserted a
wrong answer confidently.

> Speaker note: the insight is the one-liner — **the wearer's own body is the
> one thing the wearer's camera cannot see.** An egocentric frame of your own
> posture contains a desk and a torso at desk height, which matches "sitting on
> a chair" better than "standing upright." Say the confusion was
> one-directional in your trials; that's what makes it a systematic viewpoint
> problem rather than a bad frame.
>
> If asked "why not just raise the floor?" — because it would also have
> rejected legitimate neighbours and cost more than it saved. Have that answer
> ready; it's the obvious follow-up.

### 7 — Declining to answer
The low-confidence path. Below 0.45 the HUD says `Not sure`, offers a retry,
and stays silent rather than speaking a guess.

> Speaker note: make the argument that this is a *feature*, and that it's
> logged as "declined" rather than folded into an accuracy number. Correctly
> refusing to answer is what the fallback requirement is asking for, and
> hiding it inside an accuracy percentage would misrepresent the system.

### 8 — Multimodal, honestly *(cuttable)*
Audio separates walking from running. It does essentially nothing for sitting
vs standing.

> Speaker note: the reason is concrete and worth stating — DAT has no
> microphone API at all, so the glasses mic comes over Bluetooth HFP at 8 kHz
> mono. Footfall cadence is low-frequency and survives that ceiling. Posture is
> not an acoustic question at any sample rate. This is the slide that shows you
> understand what each modality is actually contributing, which is the point of
> the course.

### 9 — Live demo
Follow `docs/DEMO_SCRIPT.md`. Confident trial → low-confidence → endpoint
failure → recovery.

> Speaker note: warm the endpoint before you start. A cold Colab GPU will blow
> the 12s timeout on your first take and you'll be debugging in front of the
> room. Recovering from the induced failure on camera is worth more than the
> failure itself — make sure you show the retry succeeding.

### 10 — Herald companion *(cuttable, and optional in the assignment)*
The 600×600 mirror.

> Speaker note: say plainly that this is *not* the required path and that the
> native DAT app is. Worth one line that Herald is a third-party platform, not
> a Meta product — its own footer says so. Knowing that is a small credibility
> win.

### 11 — What we'd do next
The IMU would settle the posture confusion outright, and DAT doesn't expose it
on this path. Failing that: capture a short burst instead of one frame and vote
across it — which costs nothing extra now that the stream is already warm.

> Speaker note: end on the burst idea. It follows directly from your own design
> choice, which makes the whole talk feel like one argument rather than a list.

---

## Questions you should expect

**"Did you actually run this on glasses?"**
Answer the literal question first, then redirect to what you did verify. Don't
volunteer a defence before you've been asked for one.

**"How do you know the app works if you couldn't compile that layer?"**
The seam is a protocol. The flow, the copy, the retry logic and the wire format
are all exercised against a scripted device and a live service. What's
unverified is the adapter, and it's about 300 lines with the SDK calls isolated
in one file.

**"Why iOS?"** Straight answer: it's what the team had. Don't invent a reason.

**"Why 0.45?"** Be honest if you haven't yet tuned it on your own validation
split. "It's the floor we shipped; here's the trade-off it makes" is a fine
answer. Claiming a derivation you didn't do is not.

**"Isn't 83% low?"** It's six confident trials — the interval on that is
enormous and you should say so rather than defend the number. The interesting
result is *which* one failed and why, not the percentage.

---

## Two things not to do

**Don't present the placeholder numbers as measurements.** They're scripted.
If you haven't run real trials by presentation day, say the numbers are
illustrative of the format and show the harness that generates them — that's
still a real thing you built, and it's defensible. Presenting them as findings
is not.

**Don't demo without warming the endpoint.** See slide 9. This is the single
most likely way the demo falls over.
