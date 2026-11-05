# Validation

Sfera 1.0, measured 2026-11-05 on an M4 MacBook Air with Swift 6.4 (Command Line Tools). `./Scripts/check.sh` runs everything below.

## 1. Build

`swift build -c release` builds with no warnings. The Command Line Tools SDK implements SwiftUI's `@State` as a macro whose plugin only ships with Xcode, so the UI uses no `@State`. The panel page lives on the controller, and buttons use a `ButtonStyle`. That keeps `swift build` working with or without Xcode.

## 2. Classic gate: the 1.0 sound must not drift

`Bench/run.sh` extracts the engine from commit `d18a518` into `Bench/.classic` (built as `ClassicCore`, never edited) and renders the same input through it and through the working tree. This is the reference for the **Classic** sound, including Far. Any new renderer is added next to it, and Classic must keep matching. `Bench/run.sh --classic` runs only this gate.

| Configuration | Cases | Result (2026-11-05) |
|---|---|---|
| 48 kHz, 512-frame blocks | stereo upmix and 9.1.6 Atmos in Dry/Near/Mid/Far; Original (stereo and fold-down); stereo on the 16 ch loopback; extreme upmix + LFE + 4 dB; 5.1 film; Far → Original mid-stream; stereo → Atmos → stereo switching; loud stereo and loud Atmos (limiting) | bit-identical |
| 44.1 kHz, irregular blocks 1…1024 | Far and Dry (stereo, Atmos), Original, loopback stereo, switching, loud | bit-identical |
| 96 kHz, irregular blocks 1…256 | same | bit-identical |
| 48 kHz, 64-frame blocks | same | bit-identical |

The limit is −140 dB re signal, which allows only float-rounding noise. Mutation checks: changing Far's room send from −6 to −6.1 dB fails 9+ cases at about −37 dB. A NaN in the output fails as "non-finite output". A build error stops the bench with exit 1.

Every comparison in the bench fails on any non-finite sample, and a failed build exits 1. Before 2026-11-05 a NaN output measured as a perfect −400 dB, and `run.sh` ran the previous binary after a failed build.

**Limiter.** Loud stereo and loud Atmos must come out at or below the −0.3 dBFS ceiling, with the limiter actually engaged: both peak at −1.50 dBFS, the threshold. The old "loud stereo" case peaked at −4.1 dBFS and never reached the limiter. Its input is now 6 dB hotter.

**Known defect: limiter release stalls at −0.002 dB.** After a limited burst, quiet material comes out 0.99977× (−0.002 dB) for good. The release rebuilds its distance to unity from the rounded Float gain every sample, so it stalls where one step is smaller than half a Float ULP, at 1 − 2.3·10⁻⁴. That is 0.9's stall, and the comment in `Limiter.process` claiming otherwise is wrong. The bench reports it as a known defect (⚠, not a failure) and will say when it passes. The amount is far below audibility.

## 3. Refined renderer, its room, and switching

`Bench/run.sh --refined` runs the Classic gate plus these; the full bench runs them too. Values from 2026-11-05.

**Openness (the gate for every Refined change).** The listener prefers Classic's image: vocal in the head, instruments around it, backing vocals behind. The first Refined put everything between the ears (ENGINE.md, "Tried and reverted"). So Refined must not make the two ears more alike than Classic does. Measure: IACC, the largest normalised interaural cross-correlation within ±1 ms (1 = identical ears = inside the head). Margins are a quarter or less of the just-noticeable difference (about 0.08 near IACC 1, about 0.35 near 0; Gabriel & Colburn 1981): 0.02 for direct + room and whole mixes, 0.05 for the tail alone.

| Check (Far) | Classic | Refined Small / Medium / Large |
|---|---|---|
| Stereo mix through upmix, head and room: centred vocal + guitar panned left + ambience | 0.74 | 0.73 / 0.74 / 0.74 |
| … the vocal alone (also on L and R, as the upmix leaves it) | 0.87 | 0.87 / 0.87 / 0.88 |
| … the guitar alone | 0.64 | 0.64 / 0.64 / 0.64 |
| … the ambience alone | 0.23 | 0.23 / 0.23 / 0.23 |
| Impulse on each of 12 speakers, direct + room, 0–0.5 s (C, L, Lss, Lrs, Ltf, Ltr shown) | 0.94, 0.68, 0.45, 0.52, 0.64, 0.49 | Medium 0.94, 0.68, 0.46, 0.52, 0.64, 0.50; all within 0.02 |
| Room alone, 0–80 ms (limit 0.35) | 0.16–0.23 | 0.18–0.26 (the first Refined room: 0.93–0.99 for C) |
| Room alone, 80–500 ms | 0.07–0.11 | 0.08–0.10 |

**Renderer** (impulses and tones through the full engine):

| Check | Classic | Refined |
|---|---|---|
| Rendered interaural lag: L, Lss, Lrs, Ltf, Ltr, C, Cts | 0.27, 0.67, 0.79, 0.27, 0.79, 0, 0 ms | identical (largest difference 0.000 ms) |
| Upmix level vs input: hard left, centre, half left | +2.49, 0.00, +2.21 dB | the same (shared upmix) |
| New rear-only event in a bed, first 30 ms | −2.78 dB | 0.00 dB |
| LFE vs centre at 45 Hz, Dry / Near / Mid / Far | +6.7 / +5.1 / +6.6 / +9.5 dB | +9.7 / +9.6 / +9.6 / +9.5 dB (spread 0.20, limit 0.25; same with default bass in room) |
| Quiet after a limited burst (5.1 bed), vs the same burst kept below the limiter | −72.8 dB (known stall) | −113.7 dB, unlimited −110.1 dB: the limiter leaves nothing above the Far path's float rounding floor |

**Room** (Far, impulse responses of the head renderer + room, default room settings):

| Check | Classic | Refined |
|---|---|---|
| Room energy, 0–80 ms / after 80 ms, ten bed speakers, Small / Medium / Large | reference | +0.02 / +0.00, +0.00 / +0.00, +0.00 / −0.00 dB (limit ±1) |
| C's room energy per 20 ms at 100 / 150 / 200 ms (re Classic's total) | −23 / −31 / −40 dB | −25 / −35 / −43 dB (no swell; limit +2 dB over Classic) |
| T30 at 125 / 500 / 1k / 2k / 4k / 8k Hz | 0.41 0.42 0.40 0.38 0.32 0.26 s | 0.52 0.50 0.46 0.37 0.28 0.20 s |
| Decay setting vs measured at 1 kHz (limit ±12 %; 125 Hz ≥ 1.1×, 8 kHz ≤ 0.8×) | — | Medium 0.45 → 0.46 s; Small 0.45 → 0.45; Medium 0.8 → 0.80; Large 0.8 → 0.83 |
| Reflection delays, Small / Medium / Large | 8.7–29.8 ms | 8.0–27.4 / 8.7–29.8 (Classic's, within 0.02 ms) / 11.3–38.7 ms |
| Tail energy at 63 Hz re Classic, bass in room 0 / 0.25 (default) / 0.5 / 1 | — | −6.7 / −2.4 / +1.1 / +4.7 dB |

Changing the room while a 100 Hz tone plays (same metric as below): size Medium → Large ×1.05, → Small ×1.03, decay 0.45 → 1.2 s ×1.00, early −12 dB and tail +6 dB ×1.00, bass 0.25 → 1 ×1.06. After a size change the old room is gone (−149.3 dB re signal on a 5.1 bed; without the change it would still be at −5.8 dB). Refined Far runs finite and limited at 44.1 kHz (irregular blocks ≤ 1024), 96 kHz (≤ 256) and 192 kHz (4096-frame blocks), stereo and 9.1.6, every room size.

**Switching.** A 100 Hz tone with a change at 2 s; the largest sample-to-sample step within 43 ms before to 125 ms after it, relative to the largest step in a steady stretch before (1–1.9 s) or after (2.6–3.5 s). A discontinuity shows as ×2 and more; the dip and the room building up again move the level smoothly and stay under the ×1.25 limit.

| Change | 1.0 (`d18a518`) | Classic now | Refined |
|---|---|---|---|
| Far → Mid | ×2.10 | ×1.09 | ×1.08 |
| Far → Dry | ×7.95 | ×1.00 | ×1.00 |
| Dry → Far | ×11.09 | ×1.10 | ×1.10 |
| Far: Classic → Refined / Refined → Classic | — | ×1.10 / ×1.10 | |

**No stale room.** Far with loud noise on a 5.1 bed, Dry with a quiet tone for 2 s, then Far again, compared with the same run starting from silence: −334 dB (Classic), −282 dB (Refined). In 1.0 the old room returned at −13.7 dB re signal (stereo).

**Why the stale-room and limiter checks use a 5.1 bed.** On stereo, the upmixer's steering still remembers loud material for a few seconds, so a stereo run compares that state too, not just the room or the limiter. The bench prints the stereo figures for reference (now −262 dB for both renderers).

The gate in §2 has no mid-stream room or renderer changes, so the new switching behaviour (which also applies to Classic) doesn't affect it.

## 4. Same output as 0.9

`Bench/run.sh` extracts the 0.9 engine from git commit `2b61cdd` (`Bench/.legacy`, built as the `LegacyCore` target) and runs both engines on identical input: 512-frame blocks at 48 kHz, noise and tones shaped like music, at levels where the limiter is idle (separate loud cases test it working). "diff" is the RMS of the difference relative to the RMS of the 0.9 output; "worst sample" is the largest single-sample difference.

| Case | diff | worst sample |
|---|---|---|
| Stereo upmix, room Dry / Near / Mid / Far | −138 / −111 / −105 / −101 dB | ≤ −113 dBFS |
| Stereo, extreme upmix settings + LFE + 4 dB gain | −106 dB | −116 dBFS |
| Stereo, Original (A/B) | identical | identical |
| Stereo, Spatial → Original switch | −110 dB | −118 dBFS |
| 9.1.6 Atmos via BlackHole, Dry / Mid / Far | −83 dB | ≤ −104 dBFS |
| same, vs 0.9's surround chain on its own | −90 dB | ≤ −113 dBFS |
| 5.1 film via BlackHole | −83 dB (−89 vs 0.9's surround chain) | −103 dBFS |
| Stereo song via BlackHole (upmixed) | −105 dB | −118 dBFS |
| Atmos, Original (fold-down) | −143 dB | −165 dBFS |
| Stereo → Atmos → held → stereo, steady parts | −106 / −83 / −91 / −106 dB | ≤ −105 dBFS |
| Whole switching programme, including both fades | −54 dB | −52 dBFS |
| Loud stereo / loud Atmos, limiter working | −102 / −88 dB | −97 / −87 dBFS |

Everything apart from the switch fades is at or below −83 dB, and in steady state far below anything audible.

**The −83 dB under surround is 0.9's own error.** 0.9 crossfaded two complete chains with `w += (t − w)·c`. In Float that glide stalls at 1 − 7·10⁻⁵ instead of 1, so 0.9 always mixed its stereo upmix into Atmos at −83 dB. The bench shows this directly: 0.9's adaptive output vs 0.9's own surround chain alone is also −83 dB. Against that surround chain, 1.0 is −89 to −91 dB. The rest is the 80 Hz LFE low-pass rounding differently (correlation 0.9999999996).

**Limiter release.** 0.9's limiter release stalls at 2.3·10⁻⁴ below unity (−0.002 dB) after any limiting. 1.0's does too (see section 2), so the loud cases match.

**During a switch** the two engines differ by up to −34 dB for about 250 ms. 0.9 crossfaded two rendered outputs (each with its own room); 1.0 crossfades the speaker feeds into one renderer and room. Both fade over 50 ms between time-aligned signals, so neither jumps; they're just different fades.

## 5. CPU

Same bench: one core, release build, 512-frame blocks. Per second of audio:

| What's playing | 0.9 | 1.0 | |
|---|---|---|---|
| Stereo via process tap | 2.35 % | 0.73 % | 3.2× less |
| Stereo song via BlackHole | 3.57 % | 0.76 % | 4.7× less |
| 5.1 film via BlackHole | 3.55 % | 0.22 % | 16× less |
| 9.1.6 Atmos via BlackHole | 3.57 % | 0.32 % | 11× less |
| Nothing playing | 2.53 % | 0.08 % | 30× less |

Those are the Classic renderer. Refined (its own room tail): stereo 0.78 % vs Classic 0.72 %, 9.1.6 Atmos 0.36 % vs 0.32 %.

These count the DSP only. The app adds less on top than 0.9 did: no ring buffer, no AVAudioEngine, no second thread hop, no always-on 20 Hz UI timer.

**Live** (`Sfera --cpu-probe 10`, a real BlackHole session at −90 dB, process CPU time including the probe's own tone writer and Core Audio's IO threads): 4.9 % playing stereo, 1.1 % with nothing playing. Sampling shows the render IOProc at about 2.5 %. That is higher than the bench because macOS runs light real-time threads on efficiency cores at low clock. The rest is Core Audio's aggregate-device work for two IO threads. Sampling also found the 16-channel deinterleave using `vDSP_mmov` with one column per row, which was slow. A strided `vDSP_vsmul` brought the silent case down from 1.55 % to 1.05 %.

## 6. BlackHole round trip

`Sfera --surround-probe` plays 16 tagged tones (220 Hz + 110 Hz × channel) into BlackHole while a real `Session` (aggregate device, IOProc, spatializer at −90 dB) records what it receives:

```
surround-probe: 16 channels at 48000 Hz · 376 IO cycles · 192000 frames recorded · input peak 0.063 · output peak -100.7 dBFS (−90 dB trim)
surround-probe: every channel arrived in order · detected Atmos · rendered in the IO cycle
```

## 7. Routing

`Sfera --route-probe` drives the real `Controller` through the Sound-menu cases, with Sfera at −90 dB:

| Step | Result |
|---|---|
| Start | Mac → BlackHole 16ch · Sfera loopback → L27q-4A · IO running · BlackHole volume 0.50 |
| Pick L27q-4A in Sound | Mac → L27q-4A · Sfera switches to the tap route on L27q-4A (decision correct; tap IO see below) |
| Pick BlackHole again | Mac → BlackHole 16ch · Sfera loopback → L27q-4A · IO running |
| Stop | Mac → L27q-4A |

The probe puts the Mac's output and BlackHole's volume back as they were.

**Process tap.** In the shell these checks ran from, a process tap gets 0 IO cycles. That limit was the same for 0.9 (see its notes). `Sfera --tap-probe` from your own Terminal confirms the route.

## 8. Snapshots

`docs/screenshots/`: `atmos`, `stereo`, `stereo-tap` (no BlackHole: amber notice with Get), `original`, `off`, `settings`. They're rendered with `ImageRenderer` from the panel's own views (`Sfera --snapshot`). All controls are drawn in SwiftUI so that snapshots show them; `Link` doesn't render there, so the Get button is a `Button`.

## 9. Carried over from 0.9

The routing rules are 0.9's, after three bugs found on 2026-11-04/05:

1. When the BlackHole route failed, 0.9 fell back to the tap while leaving the Mac on BlackHole, which meant silence. The fallback now returns the Mac's output to the real device first.
2. BlackHole's own volume (set by the volume keys while it's the output) had been left at −40 dB. Each session now starts it at the middle (−32 dB).
3. AVAudioEngine followed the default output to BlackHole. 1.0 has no AVAudioEngine: the IOProc lives on an aggregate device whose clock is your real output, so it can't move.

## 10. Not verified

- Listening to the revised Refined (Classic's image with the new room). The first Refined failed by ear while passing every check it had; the openness gate in §3 was added for that reason, but only the listener can confirm it.
- Listening tests of 1.0 against 0.9. The bench says they're the same to −83 dB in steady state, but switch fades are different (section 3).
- `Scripts/check.sh` reports hardware probes that don't pass as "not passed" at the end instead of finishing with a success line. `STRICT=1` makes them fatal.
- The process tap in a normal user session (run `--tap-probe` and `--route-probe` from Terminal).
- Whether Apple Music sends Dolby Atmos (DRM-protected) to BlackHole as 16 channels on this Mac. Downmix depends on the same path and was reported working by the user.
- Behaviour on a FiiO KA13 (not connected during these runs; the probes used L27q-4A and AirPods Pro).
