# Sfera — improvements to spatial rendering, mixing and the room

A review of the current engine (`Sources/SferaCore`) with measured evidence, published
references, and a prioritised implementation plan.

**Scope.** Binaural rendering, the stereo upmix, the virtual room, loudness/bass
management, and the small number of app/platform changes that materially affect sound.
Not a UI redesign, and not a redesign of the parts that already work well.

**Method.** Three inputs:

1. Read the engine and app sources end to end.
2. Measured the *actual* engine: rendered impulses through the public `Spatializer` API
   at 48 kHz with the default tuning, for every room mode and for representative bed
   speakers, then computed ITD, ILD, interaural coherence, RT60, band decay and
   low-frequency share. A throwaway harness outside the repo; method in
   [Appendix A](#appendix-a--how-the-measurements-were-made).
3. Read current research and listener reports (references at the end).

**Confidence labels** used below: `[measured]` = measured from this repo; `[code]` =
derived directly from the source; `[published]` = from the cited literature/report.

**Short version.** The engine is in good shape architecturally — one chain, one room,
allocation-free, well validated — but its binaural cue model is effectively
two-dimensional, and the room has no low-frequency content and no source dependence.
Those two facts cap how convincing "spatial" and "Far" can get. Fixing the cue geometry
is a few days and removes the largest measurable localisation errors in every format; a
low-frequency room path and source-dependent early reflections are the largest remaining
quality gains. Measured HRTFs and head tracking are the next tier. Everything here still
needs a listening test before it is called an improvement — the numbers say what is
wrong, not what listeners will prefer.

> **Constraint from the brief:** the current **Far** is considered good and must not be
> silently replaced. Every room proposal below keeps Far's measured behaviour as a
> preset/anchor, and the plan includes a regression gate on its impulse response. See
> [§7.3](#73-do-not-regress-far--the-acceptance-gate).

---

## 0. What is already strong (protect it)

- One head renderer, one room, one limiter for both the upmix and the bed; the switch
  crossfades feeds, not outputs. `[code]`
- Exact transparency at centre/surround/height \(= 0\) (−139 dB) and the deliberate
  handling of the 0.9 float artefacts. `[code, docs/VALIDATION.md]`
- Allocation-free, lock-`try`-only audio thread; sleeping speaker groups, room and
  whole chain; vectorised covariance/eigen pass. `[code]`
- Latency is one STFT frame plus the limiter and the routing is simple (no ring buffer,
  no AVAudioEngine). `[code]`
- The BlackHole/aggregate route is a pragmatic way to get a real 9.1.6 bed on macOS,
  and the fallback ordering (loopback → tap → never silence) is right. `[code]`
- The equivalence + CPU bench already exists, which makes everything below measurable.

Nothing in this document argues for a rewrite. The structural decisions are sound; the
model inside them needs more dimensions.

---

## 1. Measured baseline

Default tuning (`centre 0.75, width 0.3, surround 0.75, height 0.6`), 48 kHz, 512-frame
blocks, impulse through the stereo path (`L` only) unless stated.

### 1.1 Latency `[measured]`

| | samples | ms @48k |
|---|---|---|
| Upmix STFT | 2048 | 42.7 |
| Limiter look-ahead | 96 | 2.0 |
| **Input → output** | **2144** | **44.7** |

At 96 kHz the same code is 22 ms; at 192 kHz, 11 ms. The README's "about 43 ms" is the
48 kHz figure.

### 1.2 Room modes only change level `[measured]`

| Mode | direct | send | peak (same impulse) | room tail @100 ms* | RT60 (250 ms+) | tail <150 Hz |
|---|---|---|---|---|---|---|
| Dry | 0 dB (pan only) | — | −2.2 dBFS | silent | — | — |
| Near | −1.5 dB | −17 dB | −3.6 dBFS | −42 dB | 0.39 s | 1.5 % |
| Mid | −3 dB | −11 dB | −3.7 dBFS | −36 dB | 0.39 s | 1.5 % |
| Far | −6 dB | −6 dB | −4.1 dBFS | −31 dB | 0.39 s | 1.5 % |

\* energy of a 50 ms window vs the 4 ms direct window, so per-sample it is ~11 dB lower.

**This is the central room finding:** Near/Mid/Far differ only by the direct/send
balance (11 dB of send from Near to Far). The room itself — reflection pattern, tail
density, decay time, bandwidth — is byte-for-byte the same object in all three modes.
There is currently no notion of room *size* or *decay*.

### 1.3 Speaker cues `[measured]` vs geometry `[code]`

Engine ITD is measured from the rendered impulse (cross-correlation of the first 4 ms)
and matches the formula. "Correct" is the published Woodworth model evaluated at the
true interaural lateral angle \(\theta = \arcsin(\sin az \cdot \cos el)\).

| Speaker | az/el | engine ITD | correct ITD | engine shadow fc | correct fc |
|---|---|---|---|---|---|
| L | −30/0 | 0.26 ms | 0.26 ms | 4772 Hz | 4772 Hz |
| Lss | −90/0 | 0.66 ms | 0.66 ms | 1265 Hz | 1265 Hz |
| Lrs | −135/0 | **0.78 ms** | **0.38 ms** | 2753 Hz | 2753 Hz |
| Ltf | −30/45 | **0.26 ms** | **0.18 ms** | **4772 Hz** | **7040 Hz** |
| Cts | 0/60 | 0 | 0 | 18000 Hz | 18000 Hz |
| Ltr | −135/45 | **0.78 ms** | **0.26 ms** | **2753 Hz** | **4772 Hz** |

Measured values confirm the model: L 0.27 ms, Lss 0.67 ms, Lrs 0.79 ms, Ltf 0.27 ms,
Cts 0. So a rear speaker and a side speaker are 0.12 ms apart in ITD (should be
0.28 ms the other way), and a front-height speaker is indistinguishable from the front
speaker by ITD.

### 1.4 Room tail shape `[measured]`, Mid

| time after onset | 50 ms | 100 ms | 200 ms | 400 ms |
|---|---|---|---|---|
| tail energy vs 4 ms direct | −26 dB | −36 dB | −52 dB | −83 dB |

Late RT60 0.39 s, essentially flat across 63 Hz–12 kHz, and ~1.5 % of the tail's energy
is below 150 Hz. The late tail is well decorrelated (IACC ≈ 0.0); the early room is the
part that is thin.

---

## 2. Spatial rendering (the binaural model)

### 2.1 The cue geometry is wrong off the horizontal plane — P0 `[code, measured]`

`Binaural.swift:24-35` computes:

```swift
let lateral = sin(azimuth)                                   // used for shadow + pan
let itdSeconds = maxITD * (abs(azimuth) + sin(abs(azimuth))) / (π + 1)
```

Two independent problems:

1. **ITD uses the raw azimuth, not the interaural lateral angle.** Woodworth's
   \(\tau = \frac{a}{c}(\theta + \sin\theta)\) is a function of the angle from the
   median plane. For \(|az| > 90°\) the lateral angle folds back
   (\(\theta = 180° - |az|\)), but the code keeps growing the delay. Consequences:
   - Lrs/Rrs (135°) get **2× the correct ITD**;
   - the formula's maximum is at **180°**, not 90°, so the back-wall reflection in the
     room is lateralised;
   - side and rear become nearly the same direction.
2. **Elevation is ignored for ITD and shadow.** Height speakers are grouped by azimuth
   (`Binaural.swift:158-172`) and inherit the ground speaker's ITD/shadow. Ltf gets the
   same 0.26 ms and 4.7 kHz shadow as L, although its lateral angle is 20.7°, not 30°.
   Ltr at 135°/45° gets 0.78 ms/2.75 kHz instead of 0.26 ms/4.77 kHz.

**Fix** (small, local, testable):

```swift
let az = azimuth * .pi / 180, el = elevation * .pi / 180
let sinLat = sin(az) * cos(el)                 // signed projection on the interaural axis
let lateral = asin(sinLat)                     // ∈ [−π/2, π/2], folds rear correctly
let itd = Cue.maxITD * (abs(lateral) + abs(sinLat)) / (.pi + 1)
let shadowLeft  = clamp(max(sinLat, 0) * 0.95 + rear * 0.35, 0, 1)
let shadowRight = clamp(max(-sinLat, 0) * 0.95 + rear * 0.35, 0, 1)
// pan from the same projection, so height sends narrow slightly too
let panAngle = (sinLat + 1) * .pi / 4
```

Keep the `rear` term. The only behavioural change is for rear and height directions:
every horizontal front/side speaker keeps exactly today's values, so A/B against the
current build stays meaningful. (Mono compatibility is unaffected: the pan is still
constant power and the two sides sum to 1 in energy.)
The same fold belongs in `Room.swift:61-63`:

```swift
let theta = abs(r.azimuth) * .pi / 180
let lateral = asin(sin(theta) * cos(elevation))   // reflections need an elevation too
let itd = headDelay * (abs(lateral) + abs(sin(lateral))) * sampleRate
```

and the 180° back-wall reflection must get **zero** ITD (today it gets 0.4 ms to one
ear, which turns the back wall into a lateral reflection).

**Acceptance:** renders the table in §1.3 to within 10 %; ITD is monotonic from 0° to
90° and falls to ~0 at 180°; Lrs and Lss differ by ≥ 0.2 ms; Ltf differs from L.

**Why this matters:** this is the cheapest change in the document and it fixes the
clearest localisation defect: rear channels are pushed to the sides (their ITD is 2× too
large and does not fall off behind the listener), and the four height channels are
distinguishable mainly by a gentle 8.2 kHz dip. These are exactly the cues that matter
for the content the app advertises (Atmos and 7.1 beds), and no other part of the engine
can compensate for them.

---

### 2.2 Head shadow and ILD are too gentle — P1 `[code, measured]`

Per ear, the shadow is a single one-pole low-pass whose corner falls to 1.1 kHz at full
shadow, plus a flat level trim of at most \(1-0.28\) (−2.9 dB). Real head shadow is
frequency-dependent: roughly 0–3 dB below 500 Hz, 3–10 dB around 2–4 kHz, and
10–20 dB above 6 kHz for a fully lateral source. The measured broadband ILD for Lss is
13 dB (dominated by the low-pass), but there is no high-frequency ILD shelf, so lateral
images are carried almost entirely by a dull contralateral channel rather than by the
combination of level and spectrum that listeners actually use.

**Fix:** replace the one-pole with a two-band model per ear:

- a low shelf (−0…2 dB) below 500 Hz,
- a peaking/shelf cut centred 2.5–4 kHz (−0…6 dB),
- the existing low-pass above ~4 kHz (corner 6–10 kHz, not 1.1 kHz),
- an additional contralateral broadband trim that grows with \(\sin\theta\) up to
  ~−8 dB, on top of the LP.

All are biquads; the group structure (one chain per azimuth) does not change, so cost is
a few multiplies per sample per group. Add a `shadow` unit test that prints the
contralateral response at 0.5/2/6 kHz for 30°, 60°, 90°.

Also: `ildL/ildR` are applied **after** the LP but the LP already changes the level.
Measured Ltf ILD (6.6 dB) is lower than L (9.0 dB) even though both share the same
shadow coefficients, which shows how entangled these knobs are. Build the model from a
target contralateral response, not from two independent trims.

---

### 2.3 A single 8.2 kHz notch is not an elevation cue — P1 `[code]`

`Binaural.swift:170-172` gives each height bus one peaking EQ at 8.2 kHz, Q 1.3, −3.75 dB
at 45° and −5 dB at 60°. Measured on an impulse, Cts and C differ mainly by the distance
gain; the notch is too shallow and too narrow to be a robust elevation cue. Published
HRTF work puts the dominant elevation information in a set of 1–3 spectral notches
between roughly 6 and 16 kHz whose centre frequencies *move with elevation*, with depths
of 10–20 dB, plus a high-frequency gain change. A fixed, 5 dB, one-octave-wide dip is
close to inaudible under music.

**Fix, in increasing cost:**

1. **Parametric pinna model.** 2–3 notches + 1 high shelf per elevation bus, with
   centre frequencies and depths interpolated from elevation (e.g. notch 1
   7.0 → 10.5 kHz, depth −6 → −16 dB; notch 2 10 → 14 kHz; shelf +2 dB at 12 kHz for
   overhead). Still zero new state per speaker, just three biquads per elevation bus.
2. **Small measured set.** A 12 azimuth × 3 elevation × 2 ear HRIR grid, crossfaded by
   direction, replacing the parametric ear chain for the direct path. This is the same
   machinery needed for §2.5.
3. **Full measured HRIR** (§2.5).

Whichever is chosen, the *rear* should also get a spectral signature distinct from the
front (see §2.4), because the current rear term only dulls both ears.

**Acceptance:** a listening test that asks "above / in front / behind" for the four
height speakers and C; and an objective check that the Cts vs C transfer function
differs by ≥ 6 dB somewhere in 6–16 kHz.

---

### 2.4 Front/back confusion has no real cue — P1 `[code]`

`rear = clamp((|az|/180 − 0.5)·2)` raises both ears' shadow by up to 0.35. That dulls a
rear source symmetrically — a valid but weak rear cue — and it is combined with the
(wrong) maximum ITD from §2.1. There is no rear-specific spectral shape (real rear
HRTFs differ from front ones in the 1–4 kHz region and in the high-frequency detail), and
the room's back-wall reflection has no cue at all.

**Fix:** derive the rear cue from the same parametric model as elevation: a broad
1.5–3 kHz notch/shelf and a gentle HF roll-off on *both* ears, scaled by how far behind
the median plane the source is. With head tracking (§2.6), small head movements resolve
most front/back confusion anyway, so this is more important for wired-headphone users.

---

### 2.5 `distanceGain` has an undocumented 1.5× elevation fudge — P0/P1 `[code]`

`Binaural.swift:44-52` multiplies elevation by `90/60` before taking `cos(el)`. That
makes Cts (60°) have a horizontal radius of 0 (gain 1.00) instead of 0.5 (gain 0.74),
i.e. +2.6 dB relative to the geometric model; Ltf gets 0.79 instead of 0.67 (+1.4 dB).
The comment says elevated speakers "sit closer to the head axis", which is true, but the
correct factor is `cos(elevation)`, not `cos(1.5·elevation)`.

**Fix:** use `cos(el)` and document the model. Better: replace the ad-hoc formula with an
explicit virtual-speaker radius per format (all bed speakers at 1.0 m; optional near-field
for heights) and make it a named constant so it can be tuned and regression-tested.
This is a small level/timbre change, but it currently biases every height channel bright
and loud relative to the bed, which interacts with the notch in §2.3.

---

### 2.6 Measured HRTFs are now practical, and the licences are workable — P2 `[published]`

The current model is a published *cue synthesis*, not a measured HRTF, and the README
says so. The step up is a compact measured set:

| Dataset | Content | Licence | Fit |
|---|---|---|---|
| **SADIE II** (Univ. of York) | 20 subjects + 2 dummy heads, HRIR + BRIR, SOFA, 44.1/48/96 kHz | listed as **Apache-2.0** in the SONICOM ecosystem; verify the download's licence file | best default: dummy heads for a "generic" profile, plus 2–3 humans |
| **SONICOM** (Imperial/QMUL) | 300 measured + 200 synthetic subjects, 3D scans, SOFA, MIT per the dataset paper | verify before commercial shipping (the dataset page also says "research purposes") | best for a future personalisation/selection feature |
| **CIPIC** (UC Davis) | 45 subjects, 1250 directions, anthropometry | use permitted incl. commercial, with acknowledgement | good research cross-check |

Sizes are small: 122 directions × 2 ears × 256 taps × 4 B ≈ 250 KB per subject at 48 kHz.
Ship 3–4 profiles, interpolate bilinearly in direction, and add a 3-way "which of these
sounds most in front of you?" calibration (the classic non-individual HRTF selection
task). Expose each profile as a named choice, not a hidden default.

**Rendering cost.** 16 speakers × 2 ears × 256 taps = 8192 MAC/sample ≈ 393 MMAC/s
≈ 1–3 % of one M4 core with straightforward `vDSP_conv`, less with a 2-partition FFT
(both worth benching before committing). Because speakers sharing an azimuth can still
share one HRIR (today's group trick), the practical count is ~10 groups, not 16.

**Research caveat, important for sequencing.** A 2023 externalisation study found that
with synthetic-IIR HRTFs, adding an FDN room raised perceived externalisation *above*
measured BRIRs, and that reverberation mattered more than early reflections. In other
words: **measured HRTFs are not the biggest lever for externalisation; the room is.**
Do §3 before §2.6 if the goal is "sound outside my head".

---

### 2.7 Head tracking is available on macOS and is the biggest dynamic cue — P2 `[published]`

`CMHeadphoneMotionManager` has been available on **macOS 14+** and streams AirPods
attitude at roughly 25 Hz. A 2024 study comparing static and dynamic binaural rendering
found in-head ratings of **17.1 % static vs 5.7 % dynamic** — roughly 3× fewer
"inside the head" responses with head tracking. This is the single largest
externalisation improvement available on this platform, and it fits Sfera's existing
architecture.

Implementation notes specific to this codebase:

- `FractionalDelay` (`Binaural.swift:56-113`) precomputes read taps for a *fixed* delay.
  Head tracking needs a slowly varying delay. Replace it with a read offset + linear
  interpolation (`readPos = write − delay[i]`, frictionally smoothed), or double-buffer
  two precomputed tables and crossfade. The current design cannot change ITD smoothly.
- Recompute each group's cue when yaw changes by > 0.5°, not per sample. Group membership
  is preserved under a pure yaw rotation, so no reallocation is needed; the notch
  coefficients for the elevation buses are unchanged by yaw (elevation is).
- Rotate the **room** too. The reflections and the room's L/R taps are part of the scene;
  leaving the room fixed while the direct sound rotates breaks the illusion. Re-render
  the 8 reflection cues on the same yaw update.
- Recentre on demand and on reconnect; smooth with a one-pole (~100 ms) and ignore
  micro-motion below a deadzone to avoid shimmer.
- Gate on `isDeviceMotionAvailable` *and* the delegate's connect callback, not on model
  names; add `NSMotionUsageDescription`.
- Offer **head-tracked** vs **fixed** (scene anchored to the screen) — Apple exposes the
  same distinction, and "fixed to the display" is the natural default for films on a Mac.
- For non-AirPods users, an optional very slow ±2–3° orbit can break front/back
  confusion, but should be off by default; motion that is not correlated with the
  listener's own head movement can be worse than none.

---

### 2.8 Headphone/HRTF colouration and device profiles — P2

The binaural chain adds its own timbre: measured on an impulse, the direct path is
already tilted (the perceived effect is "less treble / flatter / muddier", the most
common listener complaint about Atmos on headphones — see §5.4). Two cheap mitigations:

- **Diffuse-field equalisation** of the HRTF set (standard for measured HRIRs; for the
  parametric model, a fixed corrective shelf).
- **Device profiles**: a small EQ per output type (over-ear, IEM, AirPods Pro/Max, DAC),
  applied *after* the binaural render, so the same spatial scene sounds consistent.
  AirPods in particular have their own tuning; Sfera currently hands them a signal with
  no compensation.

Do not make this a full parametric EQ (that is a different product); three or four
presets plus a "neutral" default is enough.

---

## 3. The room

### 3.1 There is no low-frequency room — P1 `[measured, code]`

`Room.swift:53-55` high-passes the send at **160 Hz** and low-passes at 7 kHz, and the
LFE bypasses the room entirely (`Spatializer.swift:318-331`). Measured: **1.4–1.5 %** of
the tail's energy is below 150 Hz, identically in Near, Mid and Far.

Two perceptual consequences:

1. **No low-frequency envelopment.** The sense of being *in* a space depends
   substantially on decorrelated low-frequency lateral energy; headphones reproduce none
   of it here, so bass stays in the head while the mids move out.
2. **The room disappears on bass-heavy material.** A track whose energy is mostly below
   150 Hz gets almost no room at all — the "Far" setting can sound like "Mid" on the
   bottom two octaves.

**Fix — a separate low-frequency room path:**

- Feed it from (a) the bass-managed content and (b) the LFE channel, below a
  120–160 Hz crossover (4th-order Linkwitz–Riley, not the current one-pole).
- Decorrelate with 2–3 all-passes and a short delay (8–20 ms), not with the STFT phase
  randomiser.
- Give it a **longer RT** than the mid/high tail (real rooms: LF RT is typically
  20–40 % longer). Measured baseline: 0.39 s; try 0.55–0.7 s below 120 Hz.
- Keep it out of the early-reflection bus (or give it one or two dedicated low
  reflections) so it does not smear transient bass.
- Make its level a control ("Bass in room" / "Low end"), because too much is worse than
  none.

**Acceptance:** tail energy below 150 Hz rises from 1.5 % to 15–35 %; the tail IACC below
150 Hz is ≤ 0.4; A/B on a bass-heavy track shows no boom or one-note resonance.

---

### 3.2 Early reflections are 2D, fixed, and not source-dependent — P1 `[code]`

`Room.swift:12-21` defines eight reflections at fixed azimuths (including 0° "ceiling"
and 180° "back wall") with fixed delays and gains, and each is rendered with a simplified
lateral shadow. Three gaps:

1. **No elevation cue.** The "ceiling" reflection has azimuth 0 and no elevation at all,
   so it is a frontal reflection. The back wall is a lateral one (§2.1). The early room
   is therefore a ring of sources in the ear plane, not a 3D room.
2. **The pattern is identical for every source.** All speaker feeds are panned into one
   stereo send, so a centre voice, a hard-left guitar and a rear effect all excite the
   same eight reflection directions. Real rooms produce a *source-position-dependent*
   reflection pattern; this is a large part of why the room feels painted on rather than
   around the source.
3. **Eight reflections in 8.7–29.8 ms is sparse.** Real small rooms have dozens of
   audible reflections in the first 30 ms; sparse early reflections produce the
   "flutter/comb" character and weak diffuseness.

**Fix, in two tiers:**

- **Tier A (days).** Give each reflection an elevation, feed it through the same `Cue`
  model as the speakers (§2.1), and render it with the elevation notch. Make the ceiling
  reflection actually overhead (45–60°) and the back wall symmetric. Also add a
  per-source-group delay/gain offset derived from the group's direction and a simple
  shoebox (the wall distance differs for a left vs right source).
- **Tier B (1–2 weeks).** Image-source early reflections for a shoebox around the
  listener's head: 1st + 2nd order for the six walls, precomputed per speaker group,
  with air absorption and wall absorption. Group by arrival direction so the number of
  binaural filters stays bounded. This gives a genuinely source-dependent early room at
  modest cost.
- **Tier C (architecture, §3.5).** Render the room in the spherical-harmonic domain.

**Acceptance:** the Cts and Lrs impulse responses show early reflections with the right
elevation cue; a moving source changes the early reflection pattern; echo density
(measured as the fraction of nonzero samples in the first 50 ms) increases.

---

### 3.3 The late tail is short, coloured and single-decay — P1/P2 `[code, published]`

Today: 8-line Hadamard FDN, 21–60 ms lines at 48 kHz, RT60 0.42 s, one damping
coefficient (5.2 kHz) inside the feedback, output gain `0.32 × 0.35`.

What the literature says:

- 8 lines is at the low end; with a scalar feedback matrix the echo density grows
  slowly and the early tail is sparse. **Velvet-noise / filtered feedback matrices
  (FFDN)** reach the same echo and modal density as a conventional FDN with roughly
  2× the lines at ~40 % less compute, and are specifically designed to avoid metallic
  colouration. Schlecht & Habets (IEEE TASLP 2020) and a 2025 optimisation paper both
  describe practical designs.
- Spectral flatness matters more than raw line count; tiny FDNs (4–8 lines) can be
  optimised to be much less coloured.
- Real rooms have **frequency-dependent decay**: LF longer, HF shorter. The current
  design has one RT60 and one 5.2 kHz damping coefficient, so there is no deliberate
  LF/HF ratio at all; the measured broadband RT is 0.39 s and the per-band decay needs
  to be measured from the late tail (250 ms+) before tuning, not from the early field.

**Fix (incremental, no architecture change):**

- Add 2–3 frequency bands with their own RT60 and damping (e.g. LF 0.6 s, mid 0.42 s,
  HF 0.28 s), implemented as a one-pole/two-band attenuation filter per line.
- Either double the lines (16) or add a sparse velvet scattering filter to the 8-line
  matrix; both raise echo density without much CPU.
- Measure the tail's spectral flatness and add a **diffuse-field EQ** (a gentle static
  correction) so the tail is not coloured; this is standard practice and cheap.
- Make the early/late balance explicit rather than a single `lateGain` constant.

**Acceptance:** echo density at 20/50 ms up; RT60 per band follows the intended curve
within ±10 %; the tail's 1/3-octave spectrum is within ±3 dB of flat after EQ.

---

### 3.4 Modes should become a continuous room, with Far as a preset — P1 `[measured]`

Because Near/Mid/Far only move the send level, the app has no way to express "bigger",
"longer", "closer", "more diffuse". The natural control set:

| Control | What it changes | Current |
|---|---|---|
| **Amount / distance** | direct gain + send level (one dimension) | the 4 presets |
| **Size** | reflection delays, FDN line lengths, predelay | fixed |
| **Decay** | RT60 (and per-band RT) | fixed 0.42 s |
| **Diffusion** | early/late balance, scattering | fixed |
| **Bass in room** | LF room send (§3.1) | none |
| **Front bias** | weight of front vs rear reflections; protects the front image | none |

Implementation: keep `RoomMode` as JSON-compatible presets, add a `RoomSettings` struct
(amount, size, decay, diffusion, bass, frontBias), and make each preset a point in that
space. **Far maps to today's exact values** (direct −6 dB, send −6 dB, RT 0.42 s,
reflection table unchanged), so existing users hear no change.

Presets worth shipping: `Dry`, `Near`, `Mid`, `Far`, plus **Studio**, **Living room**,
**Hall** (size/decay beyond Far) and **Film** (front-biased, dialogue-protecting).

Why this is a real improvement, not just UI: the measured Far is a 0.39 s room. That is
a small, dry room. "Far" currently means "more room send", not "farther away". A
size/decay axis can take the same externalisation and make it a hall, or keep it close
and dry — which is what most listeners actually want to tune.

---

### 3.5 Room architectures, ranked by effort and payoff

| Option | What it buys | Cost | Risk |
|---|---|---|---|
| **A. Parametric upgrade** (§3.1–3.4) | LF envelopment, elevation, source dependence, size/decay | 1–3 weeks | low; incremental, testable |
| **B. SH/ambisonic room** | encode the 16 speaker feeds to 3rd-order ambisonics, convolve with an SH→binaural BRIR set; smooth diffuse field, coherent LF, **head rotation is an SH rotation** (cheap) | 3–5 weeks | medium: SH encoder/decoder + BRIR loader (SOFA) |
| **C. Measured BRIR per direction** | most realistic room | 4–8 weeks | high CPU and memory; fixed room; the DAGA result suggests parametric FDN can externalise *better* than short measured BRIRs |
| **D. Object renderer (IAMF/Eclipsa)** | real objects for local files | research | licensing/content availability; Apple Music still delivers a bed |

**Recommendation:** A now, B when head tracking lands (they compose naturally: the room
is a field to rotate), and treat C/D as experiments. Do not build C first: it is the
most expensive path and the published evidence does not say it is the best-sounding one.

---

## 4. The upmix and the mix

### 4.1 Default `width = 0.3` moves hard-panned content to ±48° — P1 `[code]`

`Upmixer.swift:153` sets `maxAzimuth = 30·(1 + 2·width)`, and the pan chain is
`Lss(−90) · L(−30) · C · R(30) · Rss(90)`. With the default width 0.3, a hard-left
signal (`p = −1`) lands at **−48°**, split in constant-power proportion between L (−30°)
and Lss (−90°) — roughly 80/20 in energy. So:

- the default upmix is not angle-preserving for panned content;
- the front stage is wider than the ±30° the app describes;
- A/B against Original compares a widened image to the original, which biases the
  comparison.

**Fix:** default `width` to 0 (front stage at ±30°), or redefine width as *ambience
width only* and keep direct panning angle-preserving. If the current default is
deliberate (it may be part of "the sound" users like), keep it but document it and add a
"reference stereo" measurement to the bench so future changes are visible.

---

### 4.2 Centre extraction is broadband — P1 `[code]`

`focus` steers the coherent principal component to C at all frequencies. That means
kick/bass and cymbals that happen to be centre-panned are pulled into the centre channel
with the vocal. The usual symptom is a "boxy" centre and a thinner, wider low end; the
usual fix is a **frequency-dependent** centre emphasis, e.g. a smooth bell over roughly
200 Hz–4 kHz, with the low end kept on L/R (and bass-managed), and the top kept partly
wide.

Add a second, opt-in stage: **"Keep vocals front"**, using a band-limited (250 Hz–4 kHz)
centre extraction with a higher priority than the broadband one. This directly addresses
the most common listener complaint about upmixed/Atmos music ("the vocal is behind me /
too much reverb on the voice").

---

### 4.3 Correlated reverb is classified as direct — P1 `[code, published]`

The PCA model treats \(\lambda_2\) (the small eigenvalue) as the only ambience. A
mono-ish or highly correlated reverb tail has \(\lambda_2 \approx 0\), so it is steered to
the front/centre and the upmix produces no surround for it. This is a known limitation of
covariance-only PAE; the literature's fixes are (a) an explicit side-signal ambience
component, (b) a coherence measure with a frequency-dependent diffuse-field prior, and
(c) temporal decay/tail detection.

**Practical fix:** add a side-signal ambience path:

```
side = 0.5·(L − R)                  // already decorrelated from the mid by construction
ambience = β(f)·side + (1−β(f))·PCA_ambience
```

with `β` rising where the PCA ambience is unstable (low coherence, high frequency) and a
transient gate. This also gives a more stable, less "phasey" ambience than eight
independent random-phase copies of the same two channels.

---

### 4.4 Decorrelation is static random phase + fixed delays — P1/P2 `[code]`

`Upmixer.swift:106-115` gives every ambience slot a fixed random-phase walk per bin,
plus a fixed 5–16 ms delay. Consequences:

- the eight ambience channels are decorrelated from each other, but each is a *static*
  all-pass of the same source, so tonal material can acquire a fixed "phasiness" and
  comb colouration;
- the eight delays are short and fixed, so the ambience's temporal texture is
  repetitive;
- the decorrelation is broadband, including below 150 Hz, where phase manipulation
  produces audible warble and hurts mono compatibility.

**Fix:** use time-varying all-pass/velvet-noise decorrelators (a few sparse taps per
channel, updated slowly or with a fixed velvet sequence), limit decorrelation below
~150 Hz (keep bass coherent, then widen with the dedicated bass path §3.1), and consider
different decorrelator lengths per speaker group so the ambience is not a single
repeated texture.

---

### 4.5 No transient handling — P1 `[code]`

The covariance is smoothed over 40 ms and applied once per 10.7 ms hop. A transient
therefore (a) contributes to the covariance long after it happened, so ambience gain
"hangs" on a hit, and (b) is spread by the 2048-sample Hann frame into a decorrelated
burst around the attack. For percussive material this reads as a puff/smear around
transients and a slightly soft attack.

**Fix:** a lightweight transient detector (spectral flux or a fast/slow envelope ratio)
that

- reduces the ambience send for the first 20–50 ms after an attack (or resets the
  covariance faster on attack),
- shortens the direct/ambience gain attack and lengthens the release,
- optionally switches the ambience decorrelator to a shorter window on transients.

This is the single biggest "hi-fi" improvement available in the upmix, and it is cheap.

---

### 4.6 Use the wide speakers and a smooth 5-point pan chain — P2 `[code]`

The upmix emits 12 slots and leaves `Lw/Rw`, `Cts`, `Cfh` unused, even though the
renderer and the 16-channel layout support them. The pan chain jumps ±30° → ±90°, so
intermediate pans are split between speakers 60° apart, which can sound hollow. Adding
`Lw/Rw` at ±60° (and using `Cts/Cfh` for the height sends) gives:

- a smooth 30°-spaced front stage,
- a true 9.1.6 upmix target (the layout already exists),
- better use of the height channels for front-vs-rear ambience.

This is mostly a `Slot`/gain-table change plus a new steering segment; the renderer
already handles the positions.

---

### 4.7 Ambience makeup is static and settings-dependent — P1 `[code, measured]`

`RoomMode.makeupDB` (Off +0.4, Near +0.9, Mid +2.3, Far +4.9 dB) was measured for pink
noise with the default upmix. Moving the `surround`/`height`/`focus` sliders changes the
energy split between correlated direct and decorrelated ambience, so the perceptual
loudness of the Spatial path changes while the makeup does not. The measured impulse
peaks across modes span only ~1.9 dB, so the current values are reasonable for the
default, but they are not robust to tuning.

**Fix, two levels:**

- **Analytic:** compute the expected energy of each output slot from the current gains
  (`front/side/rear/top` are already energy-normalised) and derive the makeup from the
  current settings instead of a fixed table.
- **Runtime (better):** a slow (400 ms) K-weighted energy comparison between the Spatial
  and Original paths, clamped to ±6 dB, applied to the crossfade. This also fixes
  content-dependent loudness differences and is exactly what makes A/B honest.

---

### 4.8 Content detection: absolute threshold, 3 s hold — P1 `[code]`

`Spatializer.swift:32, 196` marks a channel active when its block peak exceeds
**−80 dBFS** and holds it for 3 s. Risks:

- A quiet film passage with surrounds at −85 dB (absolutely quiet but perceptually
  present relative to a −55 dB front) drops the bed to stereo after 3 s, and the surround
  content fades out.
- A player's dithered silence at −90 dB with a DC offset can keep channels "active"
  forever, preventing sleep.
- A loud front channel and a quiet rear channel are compared on an absolute scale.

**Fix:** use a relative threshold (e.g. active if `peak > max(−80 dBFS, loudestChannel − 60 dB)`
with a longer hold for low-level channels), integrate energy rather than single-block
peak, and clear the mask on a real digital-silence run. This is a small change with a
large reliability payoff for films.

---

### 4.9 A fixed 2048 FFT is sample-rate dependent — P2 `[code]`

At 88.2/96 kHz the analysis window is 21 ms (fine), but at 192 kHz it is 10.7 ms and the
93.75 Hz bin spacing makes the 180 Hz height roll-off and the 80–160 Hz LFE taper span
only 1–2 bins. The delay also shrinks to 11 ms at 192 kHz, which is good for video, but
the bass steering becomes coarse.

**Fix:** choose the FFT size from the sample rate to keep a 20–45 ms window (e.g.
1024 at 96 kHz+, 2048 at 44.1/48), or use a sample-rate-scaled bin map for the height/LFE
curves. Add a bench case at 96 kHz — the current bench is 48 kHz only.

---

### 4.10 Mono bass and the LFE path — P1 `[code]`

- The LFE is low-passed at 80 Hz with a **one-pole** (`Spatializer.swift:66, 328`). The
  *generated* LFE has already been tapered 80–160 Hz in the upmix
  (`Upmixer.swift:122`), so that path is low-passed twice with two different shapes;
  bed LFE content is filtered once.
- It is added to **both ears at the same level**, with no HRTF, no room and no
  decorrelation (`Spatializer.swift:328-331`), so all LFE energy is a mono in-head
  phantom.
- Bass-managed content is not routed at all: there is a `generateLFE` switch, but no
  proper bass management of the main channels.

**Fix:** implement real bass management (4th-order LR crossover at 80 or 120 Hz),
route the low band to a proper bass path (with the low-frequency room send from §3.1),
and apply the LFE gain once. A small amount of decorrelation/width below 120 Hz (not
above) improves envelopment without hurting localisation. Add a crossover-frequency and
LFE-trim control.

---

## 5. Loudness, dynamics and the volume path

### 5.1 True-peak limiting — P1 `[code]`

The limiter is sample-peak only: it looks at `max(|l|,|r|)` at the base rate with a 2 ms
look-ahead, a −1.5 dB threshold and a −0.3 dBFS ceiling. Inter-sample peaks can exceed
the ceiling by 1–3 dB on lossy-decoded material, and the release is a fixed 160 ms. For
a headphone output that is the last stage before a DAC, this is worth fixing:

- 4× oversampled **true-peak detector** (the gain can still be applied at the base rate;
  only the detector needs to oversample),
- a program-dependent release (fast for short overs, slow for sustained),
- keep the current `transparent` behaviour but **reset the gain state** when entering
  transparent mode (`Spatializer.swift:385`), otherwise Original starts ducked and
  recovers over 160 ms after a switch.

### 5.2 Dynamics for film — P2 (product gap)

There is no DRC, no dialogue enhancement and no night mode. A film mixed for a dubbing
stage (dialogue around −27 LUFS, effects near 0 dBFS) is uncomfortable on headphones,
and the limiter is the only protection. Add an optional, clearly labelled dynamics
section:

- **Night**: downward compression (e.g. 2:1 above −30 dBFS, 10 ms/200 ms), dialogue
  boost in 300 Hz–4 kHz, and the room send reduced on the centre channel.
- **Cinema**: light compression + true-peak limiting only.
- **Off** by default.

A dialogue-protecting room send (duck 300 Hz–4 kHz on C by 2–4 dB) is a small change
that makes Far usable for films; intelligibility is the first casualty of a loud room.

### 5.3 The volume keys drive the limiter — P1 `[code, README]`

While listening, the Mac's volume keys control **BlackHole's** volume, which is the
gain into Sfera. Sfera sets it to 0.5 at start and asks the user to use the headphones'
own volume. So the volume keys are an input-drive control: turning them up pushes the
content into the −1.5 dB limiter rather than making the headphones louder, and any
content already near 0 dBFS is limited at 0.5. The user has two volume controls with
non-obvious interaction.

**Fix (product decision, not DSP):**

- Optionally capture the system volume keys (event tap, with permission) and map them to
  Sfera's output gain, keeping BlackHole at unity.
- Or keep the current design but show an **input-drive meter** and a "limiting" indicator
  so the interaction is visible.
- Or set BlackHole to a fixed −6 dB and give Sfera a proper output volume, accepting that
  the Mac's volume keys then do nothing while Sfera runs (explain it in the panel).

At minimum, add a limiter-activity flag to the existing meter path (`outPeak` already
exists) and surface it.

### 5.4 What listeners actually complain about, mapped to fixes `[published]`

Recurring reports about spatial/Atmos on headphones in public forums and community
threads — *muddy, less treble, less bass, quieter, vocals pushed back or over-reverbed,
instruments appearing in the rear* (see the MacRumors/ASR/The Verge sources in Appendix
B). Mapping:

| Complaint | Likely cause here | Fix |
|---|---|---|
| "muddy / less treble" | HRTF colouration; over-shadowed heights; single weak elevation notch | §2.2, §2.3, §2.8 diffuse-field EQ |
| "less bass" | LF room HP, mono LFE, no bass management | §3.1, §4.10 |
| "quieter" | fixed makeup, no runtime loudness match | §4.7, §5.1 |
| "vocals behind / too wet" | broadband centre extraction, room send on C | §4.2, §5.2 dialogue duck |
| "instruments in the rear" | PCA ambience + hard width default | §4.1, §4.3, §4.5 |
| "inside my head" | static rendering, no LF room, weak elevation | §2.7, §3.1, §3.2 |

This mapping is a useful acceptance checklist: each row should improve without the
others regressing.

### 5.5 A/B should include a real bypass — P2

The Original path is a fold-down of the bed, not what the Mac would play with Sfera off
(Apple's own renderer). For stereo it is the true original; for Atmos it is not. Add a
**"Compare with system"** action that stops the session, restores the output device and
lets macOS render, then resumes. Keep the existing loudness-matched fold-down A/B as the
quick toggle, but make the difference explicit in the UI copy.

---

## 6. Latency, real-time and app/platform

### 6.1 A low-latency mode — P1/P2 `[code, measured]`

Measured latency is 44.7 ms at 48 kHz. That is at the edge of lip-sync tolerance, and
Sfera cannot delay video. Options:

- **Quality (default):** N=2048, hop 512 (today).
- **Video:** N=1024, hop 256 → ~23 ms including the limiter at 48 kHz, at the cost of frequency resolution
  (46.9 Hz bins) and slightly less precise bass steering. Make it a setting.
- **Experimental:** an asymmetric analysis window (most energy late) can reduce the
  algorithmic delay below N for the same resolution; verify with the existing
  transparency bench before shipping.

Also expose the measured latency in the UI (samples and ms at the current rate) and in
the log, so users of IINA/VLC can set a picture delay. Do not silently change latency
between modes without updating that readout.

### 6.2 The mic indicator and the BlackHole dependency — P2/P3 (product)

The loopback route makes macOS show the orange microphone indicator because BlackHole is
an input device. This is the most visible trust cost of the app. Options:

- **Ship an AudioServerPlugIn / AudioDriverKit virtual output device** (16 ch, no input
  side, no mic indicator). This removes the third-party install and the permission
  surprise. It needs real signing/notarisation and an installer — a product project, not
  a DSP one, but the highest-value platform change.
- The process-tap route avoids the mic indicator but is stereo-only, because the tap
  mixes the processes' output down (or carries a device stream whose channel count is
  whatever the player rendered into that device). A device-stream tap
  (`init(processes:andDeviceUID:withStream:)`) can carry a stream's own channels, but
  without a multichannel sink to render into, it does not unlock surround. Verify before
  relying on it.
- If shipping a driver is out of scope, make the microphone explanation unmissable in
  the first-run flow (the README is honest; the panel should be too).

### 6.3 Channel map confidence and per-app routing — P2

- The 16-channel order is assumed to be BlackHole's installed layout. Add an optional
  channel-map override (a small table in settings) for other 16-channel devices, and
  reuse `--surround-probe` to validate it.
- Add an app allowlist/denylist for the tap route (spatialise Music and IINA, leave
  system sounds and calls alone). `CATapDescription` already supports process lists; the
  routing logic is the work.
- Add a "system sounds are not spatialised" default: alerts and UI sounds are the most
  fatiguing thing to hear through a concert hall.

### 6.4 Object audio — P3 (research)

Through BlackHole, Apple Music's Atmos arrives as a 9.1.6 **bed**; object metadata never
leaves Music, so real object rendering is not possible for that source without a Dolby
decoder. Two honest paths:

- Document the limitation clearly (the README does).
- For **local files**, support an open object format: IAMF/Eclipsa is royalty-free, has
  an open reference decoder and renderer, and added object-based audio elements in
  v2.0.0 (2026). A file-based renderer would let Sfera spatialise real objects without
  Dolby, and is a differentiator nothing else on macOS offers. Treat as an experiment;
  do not promise Atmos object support.

### 6.5 Measurement and tuning UI — P2 (high leverage for a small app)

- **`--render-ir <speaker> <mode> <out.wav>`**: write the binaural impulse response of any
  speaker/mode. This turns every tuning argument into a measurement and lets users EQ
  their own headphones against the rendered HRTF.
- **`--render-noise`**: pink/white noise through the current scene for level matching and
  room tuning.
- A small **Room panel** with the continuous controls from §3.4 and a "reset to Far"
  button.
- A **"what is arriving"** diagnostic (per-channel level + detected format + D/R ratio)
  behind the existing panel; the `activeChannels` mask already exists.
- An **HRTF profile calibration** flow (§2.6): three short samples, "which is most in
  front?" — the classic selection task.

---

## 7. Verification plan

### 7.1 Add objective probes to `Scripts/check.sh`

1. **IR probe** per speaker and mode (the harness in Appendix A). Emit ITD, ILD, IACC,
   RT60 per octave, LF share, echo density, D/R ratio, latency.
2. **Cue geometry test**: assert the corrected table (ITD ±10 %, shadow fc ±10 %), and
   monotonic ITD vs azimuth.
3. **True-peak test**: a +6 dBFS inter-sample-peak signal must come out ≤ −0.3 dBTP.
4. **Transparency test**: unchanged (−139 dB at zero centre/surround/height).
5. **Activity test**: a bed whose surround channels sit 40 dB below the front must stay a
   bed for 10 s (no dropout).
6. **Sample-rate test**: 44.1/48/96 kHz, same perceived cues (ITD in ms, RT in s).
7. **CPU budget**: stereo ≤ 1.0 %, 16-ch bed ≤ 0.5 %, silent ≤ 0.1 % on the M4 bench
   (today 0.73 / 0.32 / 0.08).

### 7.2 Listening protocol

Use the externalisation/attribute vocabulary from the 2024 studies rather than a single
"better?" score: externalisation (in-head ↔ outside), distance, width, timbre
(dull/bright), front bias, envelopment, and localisation correctness for the eight
horizontal positions plus four heights. Blind, level-matched, 8–12 trials per condition.
Keep a fixed small corpus (a dry vocal, a dense rock track, a bass-heavy electronic
track, an Atmos film scene, a 5.1 action scene) so runs are comparable.

### 7.3 Do not regress Far — the acceptance gate

Freeze the current Far impulse response as the reference and assert after every room
change. One deliberate exception: the §2.1 cue-geometry correction is global and will
move the Far IR, so rebaseline the reference **once**, at the end of Sprint 1, with a
before/after A/B — then freeze it and do not let later room work drift past the
tolerances below.

| Metric | Current Far (reference) | Tolerance |
|---|---|---|
| Latency | 2144 samples @48k | exact |
| RT60 (250 ms window) | 0.39 s | ±0.03 s |
| Tail <150 Hz | 1.5 % | may rise intentionally; record the new value |
| Tail IACC | ≈ 0.0 | ≤ 0.2 |
| Tail vs direct @100 ms | −31 dB | ±1.5 dB |
| Direct peak (same impulse) | −4.1 dBFS | ±0.5 dB |

Any intentional change to Far must be a separate, A/B-able preset — not a silent
replacement.

---

## 8. Roadmap

Ordered by payoff per day, with rough effort. All estimates assume one experienced
Swift/DSP developer and include tests.

### Sprint 1 — correctness and cheap wins (2–4 days)

1. Fix ITD/shadow geometry in `Cue` and `Room` (§2.1). **Largest single localisation
   fix.**
2. Zero the back-wall reflection's ITD; give reflections an elevation.
3. Fix `distanceGain` elevation scaling (§2.5).
4. Relative activity threshold (§4.8).
5. Single LFE low-pass + gain trim (§4.10, minimal version).
6. True-peak detector (§5.1).
7. Add the IR probe and freeze the Far reference (§7).

### Sprint 2 — room v2 parametric (1–2 weeks)

8. Low-frequency room path with its own RT and decorrelation (§3.1).
9. Elevation-aware, denser early reflections (§3.2 Tier A).
10. Band-dependent late RT + diffuse-field EQ (§3.3).
11. Continuous RoomSettings with Far as a preset (§3.4).
12. Dialogue-ducking room send (§5.2) and limiter indicator (§5.3).

### Sprint 3 — HRTF quality (2–4 weeks)

13. Parametric multi-notch elevation + two-band shadow (§2.2–2.4).
14. Measured HRIR profiles + interpolation + selection UI (§2.6).
15. Diffuse-field/headphone EQ (§2.8).
16. Head tracking with variable fractional delay, room rotation, recentre (§2.7).

### Sprint 4 — upmix v2 (2–3 weeks)

17. Frequency-dependent centre extraction + "keep vocals front" (§4.2).
18. Side-signal ambience + coherence prior (§4.3).
19. Velvet/time-varying decorrelation, no LF decorrelation (§4.4).
20. Transient-aware ambience (§4.5).
21. Wides + 9.1.6 pan chain (§4.6).
22. Analytic/runtime loudness makeup (§4.7).

### Sprint 5 — product and platform (parallel, larger)

23. Low-latency/video mode + latency readout (§6.1).
24. Per-app routing, channel map, system-sounds exclusion (§6.3).
25. Own virtual driver (project-sized; removes BlackHole + mic indicator) (§6.2).
26. Dynamics/night mode (§5.2) and real-bypass A/B (§5.5).
27. IAMF/object experiment (§6.4).

### Explicitly do **not** do

- Do not replace Far's sound by default.
- Do not add room to the Original path (it is the reference).
- Do not chase "wider" with more decorrelation: past a point it becomes phasey, reduces
  punch, and hurts mono compatibility.
- Do not ship a measured-BRIR-only room before the parametric one is fixed: it is more
  work, more CPU, and the literature does not show it externalises better.
- Do not turn every preference into a slider; the room controls above are the set that
  map to perception, not to implementation details.

---

## 9. Summary: the ten changes with the best payoff

| # | Change | Why | Effort |
|---|---|---|---|
| 1 | Fold azimuth/elevation into the true lateral angle for ITD and shadow | rear and height speakers are currently mis-localised; free improvement in every format | days |
| 2 | Low-frequency room path (120–160 Hz, 0.6 s, decorrelated) | LF envelopment is missing (1.5 % of tail); bass stays in-head | days–1 wk |
| 3 | Elevation-aware, denser early reflections; give the ceiling/back wall real cues | the early room is a 2D ring; the ceiling reflection is frontal | 1 wk |
| 4 | Continuous room (size/decay/amount/bass/front bias), Far frozen as a preset | modes only change level today; unlocks the actual feature | 1–2 wk |
| 5 | Multi-notch elevation model + two-band shadow | a single 5 dB/8.2 kHz dip is not an elevation cue | 1 wk |
| 6 | Measured HRIR profiles + diffuse-field/headphone EQ | removes the synthetic timbre; selection handles individuality | 2–4 wk |
| 7 | Head tracking for AirPods (with a variable ITD) | 3× less in-head in the cited study; the biggest dynamic cue | 2–3 wk |
| 8 | Band-dependent centre extraction + transient-aware, velvet-decorrelated ambience | fixes "vocal behind" and percussive smear | 1–2 wk |
| 9 | Loudness/dynamics: runtime A/B match, true peak, night mode, bass management | addresses "muddy/quiet/boomy" and makes films usable | 1–2 wk |
| 10 | Low-latency mode + latency readout; per-app routing | 44.7 ms is at the lip-sync edge; routing is a product gap | 1 wk |

If only one thing is done: **#1**. If two: **#1 and #2**. They are small, measurable,
and they change every rendered format rather than one preset.

---

## Appendix A — how the measurements were made

A throwaway SwiftPM executable outside the repo, depending on this package by path and
using only the public `Spatializer` API:

```swift
let sp = Spatializer(sampleRate: 48_000, channels: channels,
                     settings: settings, maxFrames: 512)
// 0.10 s lead-in: a quiet 300 Hz tone + noise on the target channel so the content
// detector settles; 0.25 s of silence; a 0.8 impulse at t = 0.35 s; then silence.
// Render in 512-frame blocks, capture L/R.
```

Analysis in the same program:

- latency: output peak index − impulse index;
- ITD: cross-correlation of the first 4 ms across ±64 samples (and onset difference);
- ILD: energy of L vs R in the first 4 ms;
- IACC: normalised zero-lag and peak cross-correlation in a 180 ms tail window;
- RT60: Schroeder backward integration, T20 extrapolated, measured from 250 ms after
  onset (the 30 ms window includes the direct/early field and is not the room's RT);
- band RT/energy: 1-octave RBJ band-pass, same integration;
- LF share: band-passed (<150 Hz) tail energy over total tail energy;
- tail vs direct: 50 ms window energy relative to the first 4 ms.

The numbers in §1 are from that run. For repeatability, the same analysis should be
added as a repo probe (`--render-ir` / `--measure`), not left in a temp directory.

## Appendix B — references

Binaural / externalisation:

- Lavandier, Heine, Perrin (2024), *Comparing the Auditory Distance and Externalization
  of Virtual Sound Sources Simulated Using Nonindividualized Stimuli*, Trends in Hearing.
  https://journals.sagepub.com/doi/full/10.1177/23312165241285695
- Hoppe, van de Par, Flanagin, Ewert (2024), *Combined assessment of auditory distance
  perception and externalization* — dynamic rendering externalises substantially more
  than static (17.1 % vs 5.7 % in-head).
  https://doi.org/10.48550/arxiv.2408.14198
- Nowak, Gerat, Zölzer (DAGA 2023), *Externalization of Static Virtual Sound Sources
  using HRTFs Approximated by Parametric IIR Filters and Room Simulation* — FDN and
  ISM+FDN outperform (short) measured BRIRs; reverberation matters more than early
  reflections.
  https://pub.dega-akustik.de/DAGA_2023/data/articles/000454.pdf
- Jambrošić, Planinec, Horvat (2024), *Validation of sound source localization quality
  in binaural audio synthesis with head-tracking*.
  https://doi.org/10.3397/in_2024_2989
- Bruschi et al. (2024), *A Review on Head-Related Transfer Function Generation for
  Spatial Audio*, Applied Sciences 14(23):11242. https://doi.org/10.3390/app142311242
- Head movement and front/back confusion: *Sound localization with head movement:
  implications for 3-D audio displays*, Frontiers in Neuroscience (2014).
  https://www.frontiersin.org/journals/neuroscience/articles/10.3389/fnins.2014.00210/full

Upmix / primary–ambient extraction:

- Faller & Breebaart, *Binaural Reproduction of Stereo Signals Using Upmixing and
  Diffuse Rendering*, AES 131.
  http://www.jeroenbreebaart.com/papers/aes/aes131.pdf
- Ibrahim, Allam et al. (2016), *Primary-Ambient Extraction in Audio Signals using
  Principal Component Analysis*.
  https://karimibrahim.com/files/2016-09-01-PAE_PCA.pdf
- *Stereo Signal Decomposition and Upmixing to Surround and 3D Formats* (HSU).
  https://openhsu.ub.hsu-hh.de/bitstreams/d2391f49-8092-4bb3-a1ad-85b558655dd7/download
- *Objective Evaluation Techniques for Pairwise Panning-Based Stereo Upmix Algorithms
  for Spatial Audio* (direct-signal leakage into surrounds).
- *Center signal scaling using signal-to-downmix ratios*, DAFx 2013.
  https://www.dafx.de/paper-archive/2013/papers/58.dafx2013_submission_45.pdf

Room / reverberation:

- Jot & Chaigne (1991), FDN; Begault (1994), virtual room for binaural.
- Schlecht & Habets (2020), *Scattering in Feedback Delay Networks* — filtered/velvet
  feedback matrices increase echo density at low cost.
  https://doi.org/10.1109/taslp.2020.3001395
- *Improving artificial room reverberation using velvet noise* (Aalto, 2020) — a
  16-line VFDN matches a 32-line FDN with 59 % fewer operations.
  https://aaltodoc.aalto.fi/items/28883c71-e395-4682-afc4-733d0b0f78ec
- *Optimizing tiny colorless feedback delay networks* (2025) — 4–8 line FDNs can be
  optimised to remove metallic colouration.
  https://link.springer.com/article/10.1186/s13636-025-00401-w
- *Choosing optimal delays for FDNs* (Menzner, DAGA 2014); CCRMA, *Artificial
  Reverberation and Spatialization* (echo/mode density rules of thumb).
- IACC / spaciousness: *Interaural cross correlation (IACC) as a measure of spaciousness
  and envelopment in concert halls*; ISO 3382 Annex B; JND of LEV/ASW.

Datasets:

- SADIE II (University of York): HRIR + BRIR, 20 subjects + 2 dummy heads, SOFA.
  https://www.york.ac.uk/sadie-project/database.html — listed as Apache-2.0 in the
  SONICOM ecosystem; verify the licence file in the release you ship.
- SONICOM HRTF Dataset (Imperial/QMUL): 300 measured + 200 synthetic, SOFA, MIT per the
  extended-dataset paper. https://www.sonicom.eu/tools-and-resources/hrtf-dataset/
- CIPIC (UC Davis): 45 subjects, 1250 directions, anthropometry; commercial use
  permitted with acknowledgement. https://www.ece.ucdavis.edu/cipic/

Platform:

- `CMHeadphoneMotionManager` on macOS 14+: WWDC23 *What's new in Core Motion*.
  https://developer.apple.com/videos/play/wwdc2023/10179/
- Core Audio process taps (macOS 14.2+), stereo mixdown vs device-stream capture:
  https://developer.apple.com/documentation/coreaudio/catapdescription and the
  `coreaudio` Rust binding notes (device streams carry the stream's own channels).
- IAMF / Eclipsa Audio (AOM): royalty-free immersive audio, object-based elements in
  v2.0.0 (2026), open reference decoder and renderer.
  https://aomedia.org/specifications/iamf/
- 3D Tune-In Toolkit (open-source binaural renderer with HRTF/BRIR, near-field and ITD
  customisation) — a useful reference implementation:
  https://github.com/3DTune-In/3dti_AudioToolkit

Listener reports (the themes mapped in §5.4):

- MacRumors, *Eddy Cue Says Spatial Audio on Apple Music…* (pages 2–4): "muddy", "less
  treble", "bass and drums more precise in stereo", "vocals too reverbed", "flatter".
  https://forums.macrumors.com/threads/2299855/
- Audio Science Review, *Spatial Audio & Headphones* (2024).
  https://audiosciencereview.com/forum/index.php?threads/spatial-audio-headphones.56806/
- The Verge (2021), *Apple Music's spatial audio is sometimes amazing but mostly
  inconsistent* — "artificial wideness", unfamiliar vocal placement.
  https://www.theverge.com/2021/6/9/22525028/apple-music-spatial-audio-dolby-atmos-hands-on
- Digital Trends, *Does Apple Music sound weak?* (Atmos loudness/bass perceptions).
  https://www.digitaltrends.com/home-theater/apple-music-sounds-weak/
- Apple Developer Forums thread 832980 — the binaural mode (OFF/NEAR/MID/FAR) metadata
  Apple's renderer does not honour. Useful context for Sfera's own Near/Mid/Far and for
  the "real bypass" A/B in §5.5.

---

*Independent analysis; no Dolby code, data or documentation was used. Sfera remains an
independent experiment and is not affiliated with Dolby Laboratories.*
