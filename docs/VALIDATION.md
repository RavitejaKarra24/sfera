# Validation

Everything below was run on this machine (macOS 27, Apple Silicon, Swift 6 Command Line Tools, FiiO KA13 USB DAC at 48 kHz, BlackHole 16ch installed) on 2026-11-04. Commands run from the repository root; `./Scripts/check.sh` runs all of them.

> Toolchain note: the Command Line Tools have no `SwiftUIMacros`, so `@State` / `@Binding` cannot compile here. Views read `@Observable` models directly.

## 1. Build

`swift build -c release`: builds with no compiler warnings. (The linker prints two "search path not found" notes about the Command Line Tools install; they are harmless.)

## 2. Engine tests

`swift test -Xswiftc -load-plugin-library -Xswiftc …/libTestingMacros.dylib`

13 tests: WAV round trip (7.1.4, float32 and 24-bit), binaural ipsilateral energy and ITD, binaural Off mode, limiter ceiling and transparency, BS.1770 loudness and silence, multichannel WAV import, 7.0.4 upmix, the adaptive spatializer (stereo → 5.1 → Atmos detection), and the full `SpatialDiagnostics` suite.

They compile. The test bundle can't be loaded in this sandbox ("library load disallowed by system policy"), so they were not run here. The same checks run in the self-check below.

## 3. Self-check

`Sfera --self-check docs/self-check.json` → **PASS**

| Check | Result |
|---|---|
| Centre-panned tone → C over L/R (default / full extraction) | +7.7 dB / +42.3 dB |
| Hard-left tone kept left (over C / R) | +107 dB / +69 dB |
| Direct sound leaking to surrounds | −49.8 dB |
| Side vs rear ambience, max cross-correlation ±30 ms | 0.10 |
| Upmix energy balance / bypass reconstruction | +0.8 dB / −137 dB |
| Room tail (50–400 ms vs direct) Dry / Near / Mid / Far | none / −30.7 / −24.7 / −19.7 dB |
| Streaming live chain vs offline upmix + render | −105.6 dB |
| Live real-time factor (stereo → 7.0.4 → binaural + room) | 42× |
| Latency stereo / surround | 44.7 ms / 2 ms |
| Spatial vs Original loudness, Dry / Near / Mid / Far | −0.02 / −0.04 / +0.00 / +0.01 LU |
| 7.1.4 bed through the live path, centre balance | +0.5 dB |
| **Adaptive:** stereo on a 16-ch input vs the stereo path | −336.7 dB (identical) |
| **Adaptive:** centre noise → bed path, L/R balance; name | 0.0 dB; "3.1" |
| **Adaptive:** heights named; back to stereo after hold | "Atmos"; yes |
| File → AVAudioEngine source node | 132,300 frames, peak 0.56 |
| Capture ring buffer under jitter | 0 discontinuities |
| 5.1 AAC + H.264 movie: centre on C vs other channels | +146 dB (AAC C L R Ls Rs LFE order remapped) |
| Movie seek to 2.000 s; end of file | frame 96000 exact; reported at 144000 |

## 4. Movie sync

`Sfera --movie-probe` plays a generated 5.1 movie through the real app path (video window, muted AVPlayer, KA13 at −90 dB): **0 ms drift playing, 0 ms after a seek** (host-clock lock from render timestamps; device + stream latency 0.3 ms).

## 5. BlackHole route

`Sfera --surround-probe` plays 16 tagged tones (220 Hz + 110 Hz × channel) into BlackHole, captures them through `SurroundCapture` and checks each channel's dominant tone, then feeds the capture to `AdaptiveSpatializer`.

Result: **every channel arrived in order · detected Atmos · surround path on.** Peak 0.010 for 0.1 written: BlackHole's own volume control was at 0.30 (≈ −20 dB). While BlackHole is the Mac's output, the volume keys set that control.

`Sfera --route-probe` drives the real `ListenModel` (tones on L, R, C and Ltf; Sfera at −90 dB):

| Step | Result |
|---|---|
| Start | Mac output → BlackHole, Sfera → FIIO KA13, "Atmos → Spatial" |
| Pick FIIO KA13 as the Mac's output | respected: stereo route to the KA13, output stays on the KA13 |
| Pick BlackHole again | surround route back, "Atmos → Spatial" |
| Stop | Mac output back on the KA13 |

**Bug found and fixed (2026-11-04).** The user heard nothing and couldn't switch the output to the KA13 while Sfera ran. Earlier probes read BlackHole as exact zeros, even for audio from another process (`say -a`), during that time. I wrongly put this down to the sandbox. With Sfera quit, the same probes pass. The fallback path explains it. When the BlackHole route failed (including on a restart after a device or rate change), Sfera fell back to the process tap, which mutes every other app, while the Mac's output was left on BlackHole. Sfera then played into BlackHole, so the result was silence. Choosing the KA13 also made Sfera move the output back to BlackHole. Now the fallback first returns the Mac's output to the real device and plays to it explicitly. Choosing a real output means stereo to that device, choosing BlackHole means surround. Every route change is logged.

**Second bug (2026-11-05): Atmos from Apple Music was inaudible.** Music was playing a Dolby Atmos track into BlackHole, and every bed channel carried signal, but only at −50…−60 dBFS peak. BlackHole's own volume control stood at −40 dB (scalar 0.375). The volume keys had set it while BlackHole was the Mac's output. Sfera now sets BlackHole's volume and unmutes it when a listening session starts (first 100 %; the middle, 50 % = −32 dB, at the user's request on 2026-11-05); restarts within a session keep the user's setting. After relaunch, the same track measured L −9, R −8, C −10, LFE −13, Ls/Rs −14, Lw/Rw −11, Ltf/Rtf −13/−18, Ltr/Rtr −29/−28 dBFS peak. That is the full 9.1.6 bed at normal level, played by Sfera to the FiiO KA13. `--route-probe` now also checks BlackHole's starting volume.

**Third bug (2026-11-05): Sfera played into BlackHole instead of the headphones.** The new status lines in `~/Library/Logs/Sfera.log` showed `engine running on BlackHole 16ch`, then `engine STOPPED`. AVAudioEngine had been pinned to the KA13, but it jumps to the new default output when the default changes under it, and Sfera switched the Mac to BlackHole after starting the engine. `--route-probe` missed this because it checked Sfera's intended device, not the engine's. Now the Mac is switched first, the engine's real device is verified after start, and a watchdog restarts the route if the engine stops or drifts. The probe now checks the engine's real device at every step. In the live app afterwards: `loopback · Atmos · in −5 dBFS · out −2 dBFS · engine running on FIIO KA13`.

## 6. Snapshots

`docs/screenshots/`: `listen` (BlackHole route, Atmos), `listen-tip` (process tap, stereo, with the Atmos tip), `listen-files`, `listen-movie`. They are rendered from the app's own view hierarchy, with no screen recording.

## 7. Not verified

- Why the BlackHole route failed in the session where the user heard silence (no log existed then; `~/Library/Logs/Sfera.log` records it from now on).
- Whether Apple Music sends Dolby Atmos (DRM-protected) to BlackHole as 16 channels on this Mac. Downmix depends on the same path and was reported working by the user.
- Live capture of Apple Music through the process tap (the user reported it working on 2026-11-03).
- Picture/sound sync on Bluetooth headphones.
- Listening tests of the upmix and binaural renderer.
