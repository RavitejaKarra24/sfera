# Engine

Everything here is implemented from published references. No Dolby code, symbols, or DSP was copied, extracted, or reconstructed.

## Speakers

Channels sit at nominal monitoring angles (azimuth positive right, 0° front): C 0°, L/R ±30°, Lw/Rw ±60°, Lss/Rss ±90°, Lrs/Rrs ±135°. The heights are front ±30° and rear ±135° at 45° elevation, front-height centre 0° at 45°, and top centre at 60°. `Layout.swift` lists them in BlackHole's 16-channel order (L R C LFE Lss Rss Lrs Rrs Lw Rw Ltf Rtf Ts Vhc Ltr Rtr).

## Stereo → spatial upmix

`Upmixer.swift`. STFT with N = 2048, hop 512, periodic Hann on analysis and synthesis (Σw² = 1.5). Each bin keeps an exponentially smoothed covariance (τ = 40 ms):

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

`Binaural.swift`. For each speaker and each 32-sample block:

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

**4. Distance**

```
distance gain = 1 / (1 + 0.7·radius) · 10^(distanceModel dB/20)
```

**5. Render mode and virtual room** (`Room.swift`)

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

## Real-time chain

`Spatializer.swift` takes 2–16 planar input channels and returns binaural stereo. It never allocates or blocks on the audio thread. Settings arrive through an `OSAllocatedUnfairLock` that the render thread only tries (`withLockIfAvailable`), and meters go out through atomics.

**What's arriving.** Per block, every channel whose peak is over −80 dBFS is marked active. A channel stays active for 3 s after its last signal. If anything beyond L/R is active, the bed is rendered from its own channels; otherwise channels 1–2 are upmixed. The same mask names the format: any height → "Atmos", wides/rears → "7.1", sides → "5.1", C/LFE → "3.1", else "Stereo".

**One renderer for both paths.** The upmix has 2048 samples of latency, so every input goes through a 2048-sample delay line. Bed and upmix then become time-aligned feeds for the same speaker slots. A switch crossfades the *feeds* (one-pole, 50 ms) into a single head renderer, room and limiter. 0.9 ran two complete chains and crossfaded their outputs, so the arithmetic differs at about −83 dB (see VALIDATION).

**Original.** The A/B path folds the delayed inputs to stereo: front L/R at unity, centre and everything else at −3 dB to its side, LFE dropped, normalised when more than two channels are summed. It then applies the makeup for the current room mode (Off +0.4, Near +0.9, Mid +2.3, Far +4.9 dB, measured to BS.1770 in 0.9) and crossfades with Spatial over 30 ms. It's computed only while it's audible.

**Limiter.** −1.5 dB threshold, −0.3 dB ceiling, 2 ms look-ahead (monotonic-deque window minimum), 160 ms release. While Original plays on its own, it only catches overs above 0 dBFS.

### Doing less work

- **Speaker groups.** Speakers at the same azimuth (e.g. L and Ltf) get the same ITD and shadow, so their elevation-filtered feeds are summed first and share one delay line and one shadow filter per ear. The elevation notch is the same on both ears, so it runs once per height bus, not twice.
- **Sleeping parts.** A speaker group or height bus stops computing after 1 s of exact silence; the LFE path and the room after 3 s. They restart from a cleared state, which is where their decaying state was heading anyway.
- **Upmix sleeps during surround.** While a bed is playing and the 3 s hold can't expire within 0.5 s, the upmixer doesn't run. It's reset and woken 0.5 s before it could be needed, which is enough to refill its 2048-sample frame and overlap-add history.
- **Dormant.** After 3 s of digital silence the whole chain stops, apart from the input level check, and writes silence. The first non-zero sample wakes it.
- **Vectorised upmix analysis.** Per hop, the covariance update and the 2×2 eigen-solve run 8 bins at a time with SIMD8 and no branches. Pan angles use `vvatan2f`, the constant-power pan pair uses one `vvsincosf`, ambience decorrelation is `vDSP_zvmul`, and unused outputs skip their inverse FFT.

**Glides that finish.** 0.9 moved gains with `w += (t − w)·c`. In Float that stalls a few ULPs short of the target, which left the upmix at −83 dB under Atmos and the limiter 0.002 dB below unity. Glides now track the remaining distance (`d *= r; w = t − d`) and snap to the target when `|d| < 1e−6`.

## Audio path

`Sources/Sfera/Session.swift`. One private aggregate device and one IOProc:

1. **Layout.** `LoopbackLayout.install` sets BlackHole's preferred channel layout on both scopes to L R C LFE Ls Rs Lrs Rrs Lw Rw Ltf Rtf Ts Vhc Ltr Rtr. Players (Music, IINA, QuickTime) then send every bed channel instead of a stereo fallback. These are the same labels as Downmix.
2. **Rates.** Both devices are set to the loopback's rate (what the player picked) if the output supports it, otherwise to the output's rate. A rate change restarts the session.
3. **Aggregate.** The main sub-device is your real output (the clock). The second member is BlackHole with drift compensation, or, without BlackHole, a process tap (`CATapDescription` on every process except Sfera, muted when tapped). `kAudioDevicePropertyIOProcStreamUsage` switches off the streams Sfera doesn't use (a headset's microphone, BlackHole's output side), so Core Audio doesn't move them.
4. **IO cycle.** The IOProc deinterleaves the input into the spatializer's planar buffers (`vDSP_vsmul` with a stride), renders, and writes L/R straight to the output stream (interleaved, planar or mono). There's no ring buffer and no AVAudioEngine, which saves 0.9's 2048-frame ring buffer (about 43 ms) and a thread hop.
5. **Routing** (`Controller.swift`). The system default output becomes BlackHole and the previous default is saved (`listen.restoreOutputUID`). It's restored on stop, on quit, or on the next launch after a crash. If you pick another physical output while Sfera runs, Sfera plays stereo to it and leaves your choice alone. Core Audio property listeners (default output, device list, rate, device alive) drive all of this. Sessions are built and torn down on a background queue, because Core Audio can block for minutes while macOS shows a permission prompt; the menu bar and Quit keep working, and the panel says when it's waiting on macOS. A 1 Hz watchdog notices when a session's IO stops for 3 s. It tears the session down, lets the Mac play directly, and retries after 3 s, 10 s and 30 s. If the IO still doesn't run, Sfera turns off and says why (for the tap: macOS isn't delivering system audio, usually because a permission was just granted and the app needs a relaunch).
