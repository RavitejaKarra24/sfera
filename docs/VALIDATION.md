# Validation

Sfera 1.0, measured 2026-11-05 on an M4 MacBook Air with Swift 6.4 (Command Line Tools). `./Scripts/check.sh` runs everything below.

## 1. Build

`swift build -c release` builds with no warnings. The Command Line Tools SDK implements SwiftUI's `@State` as a macro whose plugin only ships with Xcode, so the UI uses no `@State`. The panel page lives on the controller, and buttons use a `ButtonStyle`. That keeps `swift build` working with or without Xcode.

## 2. Same output as 0.9

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
| Loud stereo / loud Atmos, limiter working | −106 / −88 dB | −107 / −87 dBFS |

Everything apart from the switch fades is at or below −83 dB, and in steady state far below anything audible.

**The −83 dB under surround is 0.9's own error.** 0.9 crossfaded two complete chains with `w += (t − w)·c`. In Float that glide stalls at 1 − 7·10⁻⁵ instead of 1, so 0.9 always mixed its stereo upmix into Atmos at −83 dB. The bench shows this directly: 0.9's adaptive output vs 0.9's own surround chain alone is also −83 dB. Against that surround chain, 1.0 is −89 to −91 dB. The rest is the 80 Hz LFE low-pass rounding differently (correlation 0.9999999996).

**Second 0.9 artifact.** 0.9's limiter release stalled the same way at 2.3·10⁻⁴ below unity (−0.002 dB) after any limiting, which made "stereo again" after a switch differ by a constant −73 dB. 1.0 glides by decaying the remaining distance and snaps to the target.

**During a switch** the two engines differ by up to −34 dB for about 250 ms. 0.9 crossfaded two rendered outputs (each with its own room); 1.0 crossfades the speaker feeds into one renderer and room. Both fade over 50 ms between time-aligned signals, so neither jumps; they're just different fades.

## 3. CPU

Same bench: one core, release build, 512-frame blocks. Per second of audio:

| What's playing | 0.9 | 1.0 | |
|---|---|---|---|
| Stereo via process tap | 2.35 % | 0.73 % | 3.2× less |
| Stereo song via BlackHole | 3.57 % | 0.76 % | 4.7× less |
| 5.1 film via BlackHole | 3.55 % | 0.22 % | 16× less |
| 9.1.6 Atmos via BlackHole | 3.57 % | 0.32 % | 11× less |
| Nothing playing | 2.53 % | 0.08 % | 30× less |

These count the DSP only. The app adds less on top than 0.9 did: no ring buffer, no AVAudioEngine, no second thread hop, no always-on 20 Hz UI timer.

**Live** (`Sfera --cpu-probe 10`, a real BlackHole session at −90 dB, process CPU time including the probe's own tone writer and Core Audio's IO threads): 4.9 % playing stereo, 1.1 % with nothing playing. Sampling shows the render IOProc at about 2.5 %. That is higher than the bench because macOS runs light real-time threads on efficiency cores at low clock. The rest is Core Audio's aggregate-device work for two IO threads. Sampling also found the 16-channel deinterleave using `vDSP_mmov` with one column per row, which was slow. A strided `vDSP_vsmul` brought the silent case down from 1.55 % to 1.05 %.

## 4. BlackHole round trip

`Sfera --surround-probe` plays 16 tagged tones (220 Hz + 110 Hz × channel) into BlackHole while a real `Session` (aggregate device, IOProc, spatializer at −90 dB) records what it receives:

```
surround-probe: 16 channels at 48000 Hz · 376 IO cycles · 192000 frames recorded · input peak 0.063 · output peak -100.7 dBFS (−90 dB trim)
surround-probe: every channel arrived in order · detected Atmos · rendered in the IO cycle
```

## 5. Routing

`Sfera --route-probe` drives the real `Controller` through the Sound-menu cases, with Sfera at −90 dB:

| Step | Result |
|---|---|
| Start | Mac → BlackHole 16ch · Sfera loopback → L27q-4A · IO running · BlackHole volume 0.50 |
| Pick L27q-4A in Sound | Mac → L27q-4A · Sfera switches to the tap route on L27q-4A (decision correct; tap IO see below) |
| Pick BlackHole again | Mac → BlackHole 16ch · Sfera loopback → L27q-4A · IO running |
| Stop | Mac → L27q-4A |

The probe puts the Mac's output and BlackHole's volume back as they were.

**Process tap.** In the shell these checks ran from, a process tap gets 0 IO cycles. That limit was the same for 0.9 (see its notes). `Sfera --tap-probe` from your own Terminal confirms the route.

## 6. Snapshots

`docs/screenshots/`: `atmos`, `stereo`, `stereo-tap` (no BlackHole: amber notice with Get), `original`, `off`, `settings`. They're rendered with `ImageRenderer` from the panel's own views (`Sfera --snapshot`). All controls are drawn in SwiftUI so that snapshots show them; `Link` doesn't render there, so the Get button is a `Button`.

## 7. Carried over from 0.9

The routing rules are 0.9's, after three bugs found on 2026-11-04/05:

1. When the BlackHole route failed, 0.9 fell back to the tap while leaving the Mac on BlackHole, which meant silence. The fallback now returns the Mac's output to the real device first.
2. BlackHole's own volume (set by the volume keys while it's the output) had been left at −40 dB. Each session now starts it at the middle (−32 dB).
3. AVAudioEngine followed the default output to BlackHole. 1.0 has no AVAudioEngine: the IOProc lives on an aggregate device whose clock is your real output, so it can't move.

## 8. Not verified

- Listening tests of 1.0 against 0.9. The bench says they're the same to −83 dB in steady state, but switch fades are different (section 2).
- The process tap in a normal user session (run `--tap-probe` and `--route-probe` from Terminal).
- Whether Apple Music sends Dolby Atmos (DRM-protected) to BlackHole as 16 channels on this Mac. Downmix depends on the same path and was reported working by the user.
- Behaviour on a FiiO KA13 (not connected during these runs; the probes used L27q-4A and AirPods Pro).
