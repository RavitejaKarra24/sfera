# Engine

Everything here is implemented from published references. No Dolby code, symbols, or DSP was copied, extracted, or reconstructed.

## Coordinates

Objects use the Renderer's documented field: `x ∈ [-1, 1]` left→right, `y ∈ [-1, 1]` front→back, `z ∈ [0, 1]` floor→ceiling.

```
azimuth   = atan2(x, −y) · 180/π            (0° front, +90° right)
elevation = asin(z) · 180/π · (60/90)       (ceiling → 60°)
radius    = min(1, √(x² + y²))
```

Bed channels sit at nominal monitoring angles (L/R ±30°, C 0°, Ls/Rs ±110°, Lss/Rss ±90°, Lrs/Rrs ±135°, heights 45°/55°).

## Stereo → spatial upmix

`Render/Upmixer.swift`. STFT with N = 2048, hop 512, periodic Hann on analysis and synthesis (Σw² = 1.5). Each bin keeps an exponentially smoothed covariance (τ = 40 ms):

```
P = [ pLL  c  ]      c = E[L·R*]
    [ c*   pRR ]
λ1,2  = ½(pLL + pRR ± √((pLL − pRR)² + 4|c|²))
ambient power σ² = λ2                       (equal-power uncorrelated ambience model)
gA_ch = √min(1, σ²/p_ch),  gD_ch = √(1 − gA_ch²)
pan   p = atan2(|v_R|, |v_L|)/(π/4) − 1    |v_L|² = (λ1 − pRR)/(λ1 − λ2)
```

**Direct sound.** The steered part `Ŝ` has the energy of both direct channels and the phase of their eigenvector-weighted sum. It is constant-power panned along Lss(−90°)·L(−30°)·C·R(30°)·Rss(90°) at `az = p·30°·(1 + 2·width)`. The steered fraction is `centre · (1 − 2|v_L||v_R|·(1 − max(0, cos∠c)))`, so anti-phase content is never folded into C. The unsteered part stays on L/R.

**Ambience.** Weights `[front 1, side s, rear 0.8s, top-front 0.7h, top-rear 0.6h]` are energy-normalised. Each surround and height output gets its own random-walk phase response (|Δφ| ≤ π/4 per bin, so group delay ≤ N/8) plus a 5–16 ms delay. Height ambience rolls off below 180 Hz. Widened *direct* sound on Lss/Rss bypasses the ambience delay.

**Transparency.** With centre, surround and height at 0, front L/R use `√(gD² + gA²) = 1` and the STFT round trip reconstructs the input to −139 dB.

## Binaural rendering

`Render/BinauralRenderer.swift`. For each source and each 32-sample block:

**1. Interaural time difference (Woodworth)**

```
τ = (a / c) · (|θ| + sin|θ|)        a = 0.0875 m, c = 343 m/s
delay_left  = θ > 0 ? τ·fs : 0      (source right ⇒ left ear lagging)
delay_right = θ < 0 ? τ·fs : 0
```

Fractional delays use linear interpolation in a 129-sample circular line.

**2. Head shadow**

Lateral component `λ = sin θ`, rear factor `r = max(0, 2(|θ|/180 − 0.5))`:

```
shadow_L = clamp(max(λ, 0)·0.95 + r·0.35, 0, 1)
shadow_R = clamp(max(−λ, 0)·0.95 + r·0.35, 0, 1)
fc       = 18000 · (1100/18000)^shadow          → one-pole low-pass per ear
ILD      = 1 − 0.28·shadow                       → contralateral level trim
```

Frontal sources stay bright (shadow 0), lateral sources get a 1.2–4 kHz contralateral cut, rear sources get a 6.7 kHz cut on both ears.

**3. Elevation cue**

`Gain = −5 dB · (elevation/60)` applied as a peaking EQ at 8.2 kHz (Q 1.3) on both ears — the single-notch model of pinna elevation cues.

**4. Distance and size**

```
distance gain = 1 / (1 + 0.7·radius) · 10^(distanceModel dB/20)
size blender  = dry·(1 − 0.35·size) + tap(delay 6–16 samples)·0.35·size
```

**5. Render mode and virtual room** (`Render/BinauralRoom.swift`)

| Mode | Direct path | Room send |
|---|---|---|
| Off | constant-power stereo pan (no HRTF) | none |
| Near | HRTF, −1.5 dB | −17 dB |
| Mid | HRTF, −3 dB | −11 dB |
| Far | HRTF, −6 dB | −6 dB |

Sends are lateral-panned into a shared bus (HP 160 Hz, LP 7 kHz) that feeds eight early reflections (8.7–29.8 ms, at ±55°, ±60°, 0° ceiling, ±115°/120°, ±85°/90°, 180°), each with its own ITD and far-ear shadow. A late tail comes from an 8-line Hadamard FDN (1031–2861 samples at 48 kHz, RT60 0.42 s, 5.2 kHz loop damping, 18 ms predelay) with orthogonal L/R taps.

**6. LFE**

Bass-managed at the crossover (default 80 Hz) and folded into both ears at +5.5 dB, matching the documented binaural LFE treatment.

Output then passes the look-ahead limiter (−1.5 dB threshold, −0.3 dB ceiling, 2 ms look-ahead, 160 ms release) and the output gain stage.

## Loudness (ITU-R BS.1770-4)

K-weighting is the standard two-stage filter (high shelf +4 dB @ 1.68 kHz, high-pass 38 Hz); at 48 kHz the reference coefficients are used verbatim, otherwise RBJ designs are substituted.

```
block loudness  = −0.691 + 10·log₁₀(Σ_ch w_ch · mean(z²))
channel weights = 1.0 (L/R/C), 1.41 (surround/height), 0 (LFE)
gating          = 400 ms blocks, 75 % overlap
                  absolute gate −70 LUFS, relative gate (mean − 10 LU)
integrated      = −0.691 + 10·log₁₀(mean energy of gated blocks)
LRA             = 95th − 10th percentile of gated 3 s short-term values
true peak       = 4× polyphase windowed-sinc interpolation around local maxima
```

## ADM import (ITU-R BS.2076)

ADM BWF masters can be played as files. BS.2076 azimuth is positive anticlockwise (left) and Cartesian Y = +1 is front; internally azimuth is positive right and y = −1 is front, converted at the boundary. A tree-based XML walk resolves `audioProgramme → audioContent → audioObject → audioPackFormat/audioChannelFormat → audioBlockFormat`. Positions accept Cartesian and spherical forms, `rtime`/`duration` become keyframes, and `chna` binds each object to its WAV track.

## Live listening

`Live/StreamingUpmixer.swift` is the same PCA upmix as `Upmixer`, restructured to allocate nothing on the audio thread: fixed STFT buffers, per-speaker overlap-add rings, a 2048-sample latency. `Upmixer.upmix` is now a wrapper around it, so offline and live output are the same code.

`Live/LiveSpatializer.swift` chooses a path from the input layout: stereo/mono → upmix → binaural; multichannel beds → binaural directly; a 2-channel "BIN" layout passes through. Each virtual speaker uses the precomputed HRTF cue (`BinauralRenderer.cue`) and distance gain, and the room send feeds a streaming `BinauralRoomProcessor`. The Original path is delayed by the same latency and folded to stereo, and makeup gains (measured: Off +0.4, Near +0.9, Mid +2.3, Far +4.9 dB) keep Spatial and Original at equal BS.1770 loudness. Switching crossfades over 30 ms. A 2 ms look-ahead limiter (monotonic-deque window minimum) protects the output. Settings reach the render thread through an `OSAllocatedUnfairLock` read with `withLockIfAvailable`, so the audio thread never blocks.

The app side (`Sources/Sfera/Live`): `SystemAudioCapture` creates a Core Audio process tap (`CATapDescription`, muted when tapped) on every process except Sfera, wraps it in a private aggregate device and writes its IOProc buffers into `AudioRingBuffer` (lock-free SPSC with priming and bounded backlog). `LiveOutput` pulls from the ring (or from an in-memory `FilePlayback`) through an `AVAudioSourceNode`.

## Surround from other apps (BlackHole)

A process tap only hears what macOS has already folded to stereo. For real surround, Sfera uses BlackHole 16ch the way Downmix does:

1. **Layout.** `LoopbackLayout.install` sets BlackHole's preferred channel layout on both scopes to L R C LFE Ls Rs Lrs Rrs Lw Rw Ltf Rtf Ts Vhc Ltr Rtr. Players (Music, IINA, QuickTime) then send every bed channel instead of a stereo fallback. These are the same labels as Downmix.
2. **Rates.** Both devices are set to the loopback's rate (what the player picked) if the output supports it, otherwise to the output's rate. A BlackHole rate change restarts the route.
3. **Capture.** `SurroundCapture` builds a private aggregate device: main sub-device = your real output (the clock), plus BlackHole with drift compensation. Its IOProc skips the output's own input streams and writes BlackHole's interleaved channels into a 16-channel `AudioRingBuffer` (2048-frame target).
4. **Routing.** The system default output becomes BlackHole; Sfera's `AVAudioEngine` output unit is pinned to the real device with `setDeviceID`. The previous default is saved (`listen.restoreOutputUID`) and restored on stop, on quit, or on the next launch after a crash. If you pick another physical output while Sfera runs, Sfera adopts it and moves the default back to BlackHole.

`AdaptiveSpatializer` sits between the ring and the output. It runs two `LiveSpatializer`s on the same input: a stereo one on channels 1–2 (upmix, ≈45 ms) and a bed one on all 16 channels (2 ms). The bed path is delayed by the difference, so both are time-aligned and can crossfade (50 ms) without a jump. Per block, it marks every channel whose peak is over −80 dBFS. If any channel beyond L/R was active within the last 3 s, the bed path is selected; otherwise the stereo path is. The same mask names the format: any height channel → "Atmos", wides/rears → "7.1", sides → "5.1", C/LFE → "3.1", else "Stereo".

## Files and movies

`Live/StreamingFile.swift` streams the audio track of anything AVFoundation can read. When a file has several audio tracks, it picks the one with the most channels, so a film's 5.1 wins over a stereo commentary. A background thread decodes with `AVAssetReader` into an `AudioRingBuffer`, which holds about 2.7 s, so a long movie never sits in memory. Channel order comes from the track's channel-layout tags (AAC stores C L R Ls Rs LFE), and every channel becomes a speaker in the binaural renderer.

Seeking is lock-free: the main thread bumps a generation counter; the decoder stops and acknowledges; the render thread flushes and acknowledges; the decoder restarts there. After a seek the render thread waits for 4096 frames before playing, so the first callback can't underrun and click. WAV/BWF go through Sfera's own parser instead (for ADM objects); other unreadable formats fall back to the ffmpeg importer.

Movies: `VideoWindowController` shows the picture with a muted `AVPlayer`. Each render cycle that plays a full buffer records the pair (item frame, IO host time). From that, `LiveOutput.audibleTime(atHostTime:)` subtracts the spatializer look-ahead and the device + stream latency Core Audio reports, which gives the item time reaching the ears at any host time. The player is then locked with `setRate(1, time:atHostTime:)`. It is re-locked only after a seek, a pause, or more than 20 ms of drift.

## Verification anchors

- Binaural: right-side source produces higher right-ear energy and an earlier right-ear peak; both asserted in tests.
- Upmix (`SpatialDiagnostics`): centre-panned tone lands in C (+7.7 dB over L/R at default, +42 dB at full extraction); hard-left tone stays left (> 60 dB); direct leak to surrounds −50 dB; side vs rear ambience max cross-correlation 0.10 over ±30 ms; energy balance +0.8 dB; bypass reconstruction −137 dB.
- Room: tail energy (50–400 ms vs direct) −30.7 / −24.7 / −19.7 dB for Near / Mid / Far; dry render has none; Off mode is identical in both ears for a centred source.
- Live: streaming chain matches offline upmix + render to −106 dB; Spatial vs Original within 0.05 LU in every room mode.
- Adaptive: stereo on a 16-channel input is identical to the stereo path (−337 dB); centre noise switches to the bed path with 0.0 dB balance and is named "3.1"; heights are named "Atmos"; it returns to stereo after the hold.
- Limiter: 2.0 full-scale input never exceeds the −0.3 dB ceiling; quiet material passes bit-near-transparent.
- Loudness: a −20 dBFS 1 kHz stereo tone measures −20.0 LUFS ±1.5 and −20.6 dBTP.
