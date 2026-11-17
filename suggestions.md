# Sfera: spatial rendering, mixing, and room improvements

## Recommendation in one paragraph

**Keep today's Far sound, and build an optional improved renderer alongside it.** The biggest opportunity is not simply more reverb: it is a more believable direct sound, source-aware early reflections, better control of early versus late energy, and cleaner mixing. Before tuning that renderer, fix or isolate several code-backed issues: rear-direction timing, coherent gain buildup in the upmixer, sparse native-channel onset attenuation, frozen state when leaving Dry, and room-dependent LFE balance. Make the test harness trustworthy enough to distinguish a genuine improvement from a louder or more compressed version of the same effect.

## Scope and confidence

- Reviewed source at commit `d18a518`, including `Sources/SferaCore`, audio-session/routing code, UI controls, the benchmark, and existing engine/validation documentation.
- This is a **source review and research-backed proposal**, not an auditory evaluation. No listening, live capture, device-routing probes, CPU measurements, or end-to-end latency tests were performed for this review.
- Small independent arithmetic checks confirmed the timing and gain-path examples below. These are not rendered-audio measurements.
- **Observed** means behavior established from source. **Defect** means a contradiction with a stated invariant, model, or safe processing contract. **Experiment** means a plausible improvement whose audible value is not established.
- Research and community inspiration are linked at the end. Reddit searches returned no usable results through the available search service; no Reddit consensus is claimed. An accessible HeSuVi community discussion is used instead, explicitly as anecdotal feedback.
- Only this document is being added; no app or engine changes are implemented here.

## Priorities

| Order | Work | Why | Relative effort |
|---|---|---|---|
| 0 | Preserve a versioned Far reference and strengthen tests | Avoid losing the sound already preferred | Small–medium |
| 1 | Correct coherent upmix gain and phase eligibility | Prevent unintended level/image changes | Medium |
| 1 | Preserve sparse native-channel onsets; add explicit rendering policy | Stop adaptation from changing authored spatial events | Medium |
| 1 | Fix Dry-state lifecycle and smooth controls | Avoid stale tails and discontinuities | Medium |
| 1 | Correct rear ITD and high-rate delay capacity in the new renderer | Make directional geometry consistent | Small–medium |
| 1 | Separate native LFE calibration from room makeup | Keep bass balance and limiter behavior predictable | Medium |
| 1 | Harden buffer handling and routing verification | Protect reliability before adding DSP complexity | Medium |
| 2 | Source-aware early reflections with separate early/late controls | Most promising room-quality experiment | Medium–large |
| 2 | Compare measured HRTFs and headphone compensation | Improve directional spectra and listener fit | Large |
| 2 | Improve extraction stability and transient handling | Preserve clarity while increasing spaciousness | Medium–large |
| 3 | Optional measured BRIR rooms and head tracking | Higher realism ceiling, higher integration cost | Large |

Effort is a relative implementation estimate, not a delivery promise. Audible benefits remain subject to listening tests.

---

## 1. What Far actually does today

### 1.1 Far is a balance preset, not a different room

**Observed:** Near, Mid, and Far use the same eight early reflections, 8-line feedback delay network (FDN), nominal 0.42-second decay, 18 ms late predelay, and damping. The presets change direct gain, room-send gain, and spatial makeup gain.

Evidence: `Sources/SferaCore/Settings.swift:18–45`, `Room.swift:12–22,51–92`, `Spatializer.swift:118,310–317`.

There is a further coupling: the room send is taken from buffers that already contain direct-path gain and speaker-distance gain. Therefore the send setting is not an independent gain from the original speaker feed.

Evidence: `Sources/SferaCore/Binaural.swift:205–208,229–255`.

| Preset | Direct setting | Send setting | Spatial makeup | Effective direct factor | Effective room-input factor |
|---|---:|---:|---:|---:|---:|
| Near | −1.5 dB | −17 dB | +0.9 dB | −0.6 dB | −17.6 dB |
| Mid | −3 dB | −11 dB | +2.3 dB | −0.7 dB | −11.7 dB |
| Far | −6 dB | −6 dB | +4.9 dB | −1.1 dB | −7.1 dB |

These are **gain-path factors**, excluding speaker gain, HRTF filtering, room response, channel summation, and limiting. They are not acoustic direct-to-reverberant energy measurements.

**Interpretation:** Far maintains a roughly similar direct level after makeup while adding substantially more room contribution. Your preference could be for its reflections, enveloping binaural differences, bass balance, or a combination—not necessarily a desire for longer reverb.

### 1.2 Preserve Far before changing anything

**Recommendation:** Keep a selectable **Far Classic / legacy renderer** with the current processing and migrated settings. Save deterministic reference renders and settings for stereo, mono speech, percussion, native surround, and LFE-heavy material. Add an opt-in new engine/preset, initially called something descriptive such as **Far — experimental**, rather than silently replacing Far.

Changing a timing formula or LFE policy changes the sound even if the preset's three dB values remain identical. Reproducing those values alone is not sufficient preservation.

**Acceptance:** Classic matches its saved references within a documented numerical tolerance. New processing has separate correctness tests; intentional improvement must not be forced to null against the old algorithm.

---

## 2. Room processing: the highest-value listening experiments

### R1. Separate distance, room size, and room amount

**Observed:** One preset simultaneously controls direct attenuation, send level, and makeup, while geometry and decay stay fixed.

**Recommendation:** Internally separate:

- Direct level / perceived-distance balance.
- Early-reflection level.
- Late-tail level.
- Room geometry / reflection timing.
- Frequency-dependent decay and damping.
- Diffuseness / width.

Keep the simple preset selector on the main panel; put a few meaningful controls behind an advanced section. Initialize the new model against Far's **effective** gains, accounting for the existing direct×send multiplication.

**Acceptance:** Changing late-tail level need not change early-reflection energy or direct gain. Moving a distance control produces a coherent cue combination, not merely a volume change. Do not label a control in meters unless its model justifies that scale.

### R2. Preserve source direction into early reflections

**Observed:** All speaker sends collapse into two lateral-panned buses. Front/rear directions with the same lateral component cannot retain their original identity through that reduction; height identity also disappears. The room then generates the same fixed reflection pattern from those buses.

Evidence: `Binaural.swift:30,229–255`, `Room.swift:12–20,147–188`.

**Experiment:** Keep the shared late FDN, but generate early reflections from source position or a small directional bus set. A practical progression is front/side/rear/height buses, followed by geometry-derived per-speaker reflection taps if profiling supports it. Precompute image-source paths or another compact room model outside the callback.

Each reflection should have an arrival time, arrival direction including elevation, attenuation, and frequency-dependent wall absorption. Keep source/reflection relationships stable rather than choosing arbitrary independent tap positions.

**Expected benefit:** More distinguishable front/back/height scenes and a room that belongs to the virtual speakers rather than a stereo effect layered over them. This is a hypothesis, not a demonstrated audible defect.

**Acceptance:** A tagged front, rear, and overhead impulse produces appropriately different early responses; summation stays bounded; blinded listening improves externalization or naturalness without sacrificing speech clarity.

### R3. Fix reflection timing geometry, including the back-wall and ceiling paths

**Model defect:** The room computes ITD using `min(θ, π/2) + sin(θ)`. At its actual 180° back-wall reflection this creates about **0.401 ms** of extra delay to one ear. A centered rear source should have zero geometric ITD in a symmetric-head model.

Evidence: `Room.swift:20,63–73`. See the published model in [S2].

The reflection called “ceiling” has azimuth 0 but no elevation field or pinna/elevation processing. Naming a reflection ceiling does not itself provide an overhead cue. Also, the near/far implementation filters only one ear even at centered directions; review that small asymmetry separately from intentional room asymmetry.

**Recommendation:** Share a rear-aware directional-cue calculation with the direct renderer. Add elevation to reflection metadata and validate centered directions. Keep deliberate room asymmetry where useful; do not require every whole-room response to be perfectly symmetric.

**Acceptance:** Isolated front/back median-plane reflections have symmetric geometric delays; mirrored reflection paths mirror their ear responses; ceiling/floor cues differ meaningfully from horizontal ones. Compare the corrected room against Classic, because correcting geometry may alter its preferred spaciousness.

### R4. Improve the early-to-late transition before extending the tail

**Observed:** Explicit early taps occupy 8.7–29.8 ms. The shortest FDN line is about 21.5 ms at 48 kHz, in addition to its 18 ms predelay, so the first late output is around 39.5 ms, before small filter effects. The existing engine already contains energy beyond 30 ms through the FDN.

Evidence: `Room.swift:12–22,75,86–89,170–188`.

**Experiment:** Tune reflection density and diffusion over the first roughly 80 ms, blending sparse arrivals into the late field. Compare extra low-level reflection clusters or a compact input diffuser against the current response, at matched energy. Do not indiscriminately multiply the number or gain of taps.

The externalization review [S1] reports studies in which including reverberation up to about 80 ms helped, with no further benefit from longer segments. This is a useful experiment range, **not a universal optimal cutoff** or a reason to truncate all reverb at 80 ms.

**Acceptance:** Measure echo density, early/late energy and coloration; listen to clicks, speech, piano, and percussion. Reject variants that merely make attacks softer or add a noticeable slap.

### R5. Calibrate frequency-dependent FDN decay and diffusion

**Observed:** The eight lines have length-scaled scalar feedback for nominal RT60, but share one 5.2 kHz damping coefficient. Early/late balance and late output gain are fixed. There is no explicit input-diffusion stage.

Evidence: `Room.swift:22,49,85–92,132–136,170–188`.

**Experiment:** Measure octave-band decay first. If improvement is warranted, design per-line attenuation filters for target decay times by frequency, accounting for line length and filter delay. Compare a denser input/feedback diffusion arrangement against simply expanding the network. [S8] explains why attenuation-filter approximations can produce significant decay-time errors.

Keep modulation optional and subtle. Slowly moving delays may reduce ringing but can also create pitch movement; fixed, well-designed diffusion may be preferable for music fidelity.

**Acceptance:** Stable decay across supported rates, documented bandwise targets, no unexpected growth or narrow ringing, no audible chorus on sustained notes. Measure late-field interaural coherence for mono and stereo excitation: orthogonal output tap vectors alone do not guarantee a perceptually diffuse field for every input.

### R6. Preserve dialogue and avoid double ambience

**Observed:** Native bed channels and generated stereo feeds all contribute to the same room-send policy. The stereo upmixer already distributes delayed/decorrelated ambience, which can then excite another room.

Evidence: `Upmixer.swift:107–126,420–458`, `Spatializer.swift:260–341`, `Binaural.swift:229–255`.

**Experiment:** Permit separate direct-versus-extracted-ambience room sends and an optional lower late send for the center channel. Retain enough directional early energy to keep the center externalized. For authored surround, use restrained defaults and neutral channel trims; do not assume every bed needs more diffuse sound.

A lightweight, slow clarity control could reduce **late** room energy during strong speech/transients while preserving early cues. Make it optional: content-dependent ducking can pump and should not replace a good static room.

**Acceptance:** Speech intelligibility and vocal focus do not worsen at the preferred room setting; existing recorded ambience is not swallowed by additional reverberation. No claim that current Far is muddy is established by this review.

### R7. Smooth room changes and give inactive state a defined lifecycle

**Defect/risk:** Dry exits before advancing head-filter histories, and the room is skipped entirely. With continuing nonzero playback, its old state can remain frozen indefinitely until a room mode returns. Direct/send/makeup and trim also change without an explicit glide.

Evidence: `Binaural.swift:212–226`, `Spatializer.swift:310–313,334–345,366–383`.

**Recommendation:** Ramp scalar gains and crossfade Dry/HRTF processing. Either drain inaudible state to silence or reset it after a fade before re-entry. Do not suddenly revive a previous track's reflection history. For future geometry/filter changes, prepare new state off-thread and use a bounded transition rather than unstable coefficient or delay jumps.

**Acceptance:** Far → sustained Dry playback of different material → Far does not revive old content or create a discontinuity. Test rapid changes at arbitrary callback boundaries. If decay becomes longer, replace fixed sleep assumptions with a bounded, tail-aware policy; today's 1/3-second idle rules are not automatically suitable for new rooms.

### R8. Offer measured-room BRIRs as an optional quality tier

**Experiment:** Add a small, carefully licensed selection of measured binaural room impulse responses (BRIRs): treated studio, listening room, and possibly theater. Compare these against the algorithmic room; do not assume a measured room wins for every listener.

[S5] demonstrates personal BRIR measurement; [S6] documents per-source/per-ear and true-stereo BRIR mapping. Stereo virtualization needs the four source-to-ear paths, not independent left/right stereo effects. Surround needs both ear responses for each speaker, with explicit height coverage or a clearly stated limitation.

**Implementation constraints:** Partitioned convolution, resampling, tail memory, gain calibration, file validation, licensing/attribution, and filter construction off the callback. A full BRIR already includes direct head/room cues: **do not run it through the existing HRTF plus room again**. Either use it as a complete alternate renderer or explicitly separate/replace its components.

**Acceptance:** Verified channel/ear mapping, bounded tail and peaks, no doubled direct arrivals, and a measured CPU/latency budget. Never redistribute captured proprietary commercial-renderer impulses without permission.

---

## 3. Binaural rendering and directional realism

### B1. Use the correct rear-hemisphere ITD model

**Model defect:** The direct renderer applies the frontal `θ + sin(θ)` expression throughout the rear hemisphere. Its ±135° speakers therefore get more ITD than ±90°, rather than returning toward zero behind the head.

Evidence: `Binaural.swift:23–35`, `Layout.swift:19–20`.

For a symmetric spherical head, with `θ = |azimuth|` in radians:

```text
0 ≤ θ ≤ π/2:  ITD = (a/c) × (θ + sin θ)
π/2 < θ ≤ π:  ITD = (a/c) × (π − θ + sin θ)
```

| Azimuth | Current direct formula | Current reflection formula | Rear-aware spherical reference |
|---|---:|---:|---:|
| 0° | 0 ms | 0 ms | 0 ms |
| 90° | 0.656 ms | 0.656 ms | 0.656 ms |
| 135° | 0.781 ms | 0.581 ms | 0.381 ms |
| 180° | 0.801 ms | 0.401 ms | 0 ms |

The direct 180° row evaluates the formula; the current direct layout has no 180° speaker. The room does have a 180° reflection.

**Recommendation:** Correct the new renderer and use one consistent cue model for direct and reflected sound. This is still an approximation: [S2] discusses frequency dependence and limitations of Woodworth itself.

**Acceptance:** Correct signs, left/right mirroring, continuity around 90°, zero geometric ITD at 0/180°, and sample-rate-consistent timing. Audible superiority still needs listening.

### B2. Compare measured HRTFs with the synthetic renderer

**Observed limitation:** Elevation mainly changes a shared 8.2 kHz notch and gain. Heights at the same azimuth share ear-plane ITD/head shadow; rear coloration is a simple heuristic. This cannot reproduce the full direction-dependent spectra of real ears, head, and torso.

Evidence: `Binaural.swift:23–39,160–174,236–305`.

**Experiment:** Retain the cheap synthetic renderer, and prototype a measured head-related impulse response (HRIR) renderer using SOFA data. Start with a small set of meaningfully different profiles and a brief level-matched listening selection, not hundreds of unexplained files. SADIE provides human/mannequin HRIR and BRIR data [S4]; libmysofa provides loading/interpolation/resampling support [S3]. Check dataset licenses independently of library licenses.

A measured HRTF is not automatically personalized. Research on externalization benefits of individualization is mixed [S1], although direction/elevation errors and listener fit remain important reasons to compare profiles.

**Architecture:** The current azimuth-sharing optimization is valid for today's separable model. It cannot be carried over unchanged when different elevations have different per-ear filters. Precompute fixed speaker filters off-thread, then benchmark short FIR versus partitioned convolution. Respect SOFA coordinates: their positive azimuth convention can differ from Sfera's positive-right convention.

**Acceptance:** Verified orientation, preserved embedded delays, consistent normalization, and localization tests that measure elevation/front-back errors separately from preference and tonal brightness.

### B3. Separate speaker calibration from the current “distance” heuristic

**Observed:** `distanceGain` derives gain from projected horizontal radius and scales elevation by 90/60. It yields approximately 0.588 at ear level, 0.789 at 45°, and 1 at 60°—about **+2.5 to +4.6 dB** for heights relative to ear-plane feeds, before other processing.

Evidence: `Binaural.swift:42–51`.

**Recommendation:** Treat this as legacy voicing, not physical distance. In the new model, separate speaker calibration, actual source radius, HRTF normalization, and direct-to-room balance. If sources sit on an equal-radius sphere, elevation alone should not imply a shorter physical distance.

**Acceptance:** Equal-level channel tests reveal deliberate rather than accidental height emphasis. Do not remove the gain without a matched-level comparison: some of today's preferred sound may depend on it.

### B4. Size delays for supported rates and evaluate interpolation quality

**Conditional defect:** The fractional-delay buffer clamps requested delay to **127 samples**. At 192 kHz the current ±135° formula requests about 150 samples, so timing is truncated.

Evidence: `Binaural.swift:59–70`. A corrected horizontal model reduces this particular maximum, but capacity should still derive from supported rates and model bounds rather than a magic constant.

**Recommendation:** Allocate sufficient delay storage at initialization. Compare linear interpolation against a higher-order fractional-delay design; linear interpolation introduces frequency-dependent attenuation that varies with fractional position. Improve it only if response tests/listening justify the cost. Room reflections currently round ear offsets to whole samples; fractional reflection delays are another measurable refinement.

**Acceptance:** No silent clamping at supported rates, correct impulse timing, bounded response error across fractional positions, and no regressions in real-time deadlines.

### B5. Add head tracking only as an optional, capability-checked feature

**Experiment:** World-fixed virtual speakers can provide useful dynamic cues and reduce front/back ambiguity [S1]. Tracking should rotate both direct cues and directional room components consistently, not merely pan final stereo.

**Prerequisites:** First verify motion-data availability, permissions, update rate, and latency on supported Mac/headphone combinations. Do not promise that all AirPods or arbitrary headphones expose usable tracking. Support fixed-head fallback, recenter, sensor-loss handling, and an explicit off switch. Prepare/interpolate filters safely without file loading or allocations in the callback.

**Acceptance:** Measured motion-to-audio latency and stability, no zipper noise during motion, no distracting recenter drift, and a subjective improvement over the static renderer. Arbitrary pitch/yaw automation is not a substitute for actual tracking.

### B6. Add target-aware, optional headphone compensation

**Experiment:** Headphone response and fit can mask or exaggerate the spectra carrying spatial cues. Add per-device compensation with explicit bypass, conservative boost limits, and enough preamp headroom. [S4] and [S6] provide useful examples of headphone-response/compensation data associated with binaural rendering.

Do not assume that “flat,” a consumer preference target, and the compensation expected by a particular HRIR/BRIR dataset are interchangeable. Document the renderer's equalization convention, avoid double compensation, and do not independently flatten every directional HRTF into the same spectrum—that would remove localization information. Aggressive inverse boosts at narrow high-frequency notches are especially sensitive to fit and measurement variation.

**Acceptance:** Compare at matched loudness with the user's actual headphones; check final peaks and limiter reduction; preserve directional spectral differences. Offer manual balance/trim where useful, without claiming headphone-model EQ is individualized ear calibration.

---

## 4. Stereo extraction and mixing quality

### U1. Fix coherent direct-path recombination

**Defect relative to energy-preservation claims:** Partial steering splits a correlated source using square-root gains, then adds the steered and retained portions into overlapping speaker destinations. Constant-power splitting does not preserve energy when those correlated portions recombine coherently.

Evidence: `Upmixer.swift:318–355,389–418`.

For ideal left-only input, width 0, and extraction `f`, both portions land on L:

```text
Y_L = [sqrt(f) + sqrt(1 − f)] × X
f = 0.5  → approximately +3.01 dB
f = 0.75 → approximately +2.71 dB
```

This is before head rendering and limiting. End-point-only tests can miss it.

**Recommendation:** Define the intended invariant—speaker-domain energy, stereo reconstruction, or binaural loudness—and redesign partial direct remapping accordingly. Consider coherent interpolation or normalization of the remapping itself. Do not hide the issue with fast whole-output gain normalization.

**Acceptance:** Sweep source pan, extraction, and width; separately measure speaker energy and binaural output. A control should not create an unexplained gain peak simply because two copies meet in the same speaker.

### U2. Separate center extraction from lateral widening and phase eligibility

**Observed:** `centerExtraction` controls all direct steering, including widening. Setting it to zero also defeats this direct-width mechanism. The comment that anti-phase content is never folded into C is too broad: equal-level anti-phase content suppresses steering, but unequal-level anti-phase content can still be steered toward C.

Evidence: `Upmixer.swift:143–156,324–350,369–409`.

For `L = X`, `R = −0.5X`, the formula leaves `steer = 0.2 × focus` in the ideal rank-one case.

**Recommendation:** Distinguish center anchoring, lateral stage width, and ambience spread. Use phase/coherence confidence to determine center eligibility, while preserving the original complex stereo relationship for rejected material.

**Acceptance:** Test unequal polarity-inverted pairs, quadrature signals, interchannel delays, and naturally wide stereo recordings. Preserve vocal stability without unnecessarily collapsing stereo effects. Anti-phase content remaining on L/R is not sufficient proof of preservation after cross-ear binaural summation.

### U3. Compare reconstructive extraction and confidence-linked steering

**Observed limitation:** The current covariance-driven masks estimate energy and panning; they are not a complete complex principal-component projection followed by an exactly reconstructive residual. A dominant uncorrelated instrument can look direct, and correlated recorded ambience can look like foreground.

Evidence: `Upmixer.swift:299–355`.

**Experiment:** Compare the existing method with complex projection/residual extraction, confidence-weighted steering, and gentle frequency-band linking. Retreat toward stable stereo when the scene is ambiguous. For interchannel-time-difference material, compare delay-aware analysis rather than assuming low zero-lag correlation means diffuse ambience. [S9] discusses these model assumptions and alternatives.

**Acceptance:** Known mixtures of panned sources plus ambience, changing source overlaps, and delay-panned stereo retain stable images and plausible residuals. More exact decomposition is not automatically more pleasant; benchmark against Classic.

### U4. Protect attacks and smooth the spatial estimate

**Observed:** There is a fixed 2048-sample window and a 40 ms covariance smoother, but no explicit transient-protection branch. Covariance is already smoothed; adding indiscriminate extra smoothing could make steering slower rather than better.

Evidence: `Upmixer.swift:15–16,78,299–309`.

**Experiment:** Use onset/spectral-flux confidence, asymmetric attack/release, and controlled spatial-mask changes. Compare reducing diffuse sends during attacks against preserving attacks on a properly latency-aligned direct path. Avoid random per-bin image changes and reduce steering confidence around overlapping sources.

**Acceptance:** Measure impulse/pre-arrival energy and attack envelopes at every hop offset; listen to drums, plucked strings, speech consonants, and piano. Any parallel bypass must have explicitly designed latency, phase, and gain—adding raw audio around the STFT is not a drop-in fix.

### U5. Validate decorrelation and frequency-dependent energy distribution

**Observed:** Ambience uses fixed random-walk phase curves plus short delays. This can decorrelate broadband material, but a sustained narrowband signal still has a deterministic relationship between outputs. A bounded phase step per FFT bin does not establish a globally causal all-pass response after windowed overlap-add synthesis.

Evidence: `Upmixer.swift:107–126,420–458`.

**Experiment:** Measure broadband and narrowband interchannel coherence, impulse spreading, and pre-arrival energy. Compare causal all-pass or compact diffusion designs. Keep low-frequency coherence controlled and avoid new per-frame random phases, which can create modulation or musical noise.

Separately, the ambience normalization includes height weights **before** the low-frequency height rolloff. Energy removed from those height feeds is not redistributed, so increasing Height can change low-frequency ambience balance.

Evidence: `Upmixer.swift:147–152,426–428`.

**Recommendation:** If Height should change spatial distribution rather than tone, normalize destination weights per frequency after the height curve. Preserve the existing behavior in Classic.

### U6. Add a simple virtual-speaker mode without forced upmix

**Experiment:** Offer **stereo speakers in a room**: L/R virtual speakers with HRTF and room, but no PCA redistribution. This separates speaker externalization from immersive upmix strength and provides a useful comparison for acoustic recordings and already-wide music.

For ideal dual mono, the current covariance is rank one and extracted diffuse ambience vanishes; the room can still externalize it. Do not generate unnecessary surround/height energy merely to light more dots.

**Acceptance:** Transparent delayed stereo at the extraction stage, intentional speaker cross-ear cues at the rendering stage, and independent comparison against both Original and full upmix.

---

## 5. Bass, loudness, limiting, and authored surround

### M1. Decouple native LFE from the room preset

**Observed coupling:** Main feeds receive room-mode direct attenuation; LFE does not. Both later receive spatial makeup. From Mid to Far the main direct factor changes −0.7 → −1.1 dB, while LFE makeup rises +2.3 → +4.9 dB. LFE therefore rises **3 dB relative to the main direct path**.

Evidence: `Spatializer.swift:66,310–331,366–381`, `Settings.swift:18–45`.

**Recommendation:** Define an explicit headphone LFE reference, optional trim, and how it relates to perceived-distance changes. Do not mechanically add a theatrical +10 dB boost without establishing the decoded PCM convention. The current `dbToGain(5.5) × 0.5` is approximately −0.52 dB **per ear before filtering**, not +5.5 dB per ear.

All native LFE also passes an 80 Hz low-pass. Evaluate authored 80–120 Hz content separately from generated bass enhancement; the current second-order 80 Hz filter attenuates 120 Hz by about 7.8 dB.

**Acceptance:** Swept native LFE and correlated main/LFE fixtures across every mode; no unexplained bass increase or limiter ducking when only Room changes. Recalibrate makeup after deciding the new bass policy.

### M2. Describe generated LFE honestly

**Observed:** Optional generated LFE is a filtered mono sum added to the headphone output while bass remains in the main feeds. It is bass enhancement, not complementary crossover redistribution.

Evidence: `Upmixer.swift:461–468`, `Spatializer.swift:319–331`.

**Recommendation:** Keep it off by default, label its effect clearly, and separate it from native LFE calibration. If genuine bass management is wanted, design complementary filters and verify phase/summation. Headphones do not require a virtual subwoofer channel merely to reproduce low frequencies.

At high rates the fixed FFT gives coarse bass resolution: at 192 kHz its bin spacing is 93.75 Hz, leaving only one positive bin below 160 Hz. A time-domain generated-bass filter is worth comparing, with proper latency alignment.

### M3. Make A/B matching more defensible

**Observed:** Fixed makeup values were calibrated on partly correlated pink noise with default upmix. They cannot guarantee equal loudness for every track, native bed, setting, or headphone. The code applies makeup to the spatial path; Original is the delayed source/downmix reference.

Evidence: `Settings.swift:38–45`, `Spatializer.swift:348–385`.

**Recommendation:** Measure gated loudness across a representative corpus, report residual mismatch, and offer a small manual A/B offset or a deliberate calibration step. If a measured offset is used, freeze it during comparisons; avoid fast normalization that changes dynamics.

The surround Original path drops LFE and normalizes using configured channel capacity, not just active content. Identical six-channel content in a six-channel versus sixteen-channel processor can therefore produce a different reference level.

Evidence: `Spatializer.swift:143–156,395–407`.

Define a documented downmix policy, including LFE, headroom, and layout normalization. Do not change gains sample-by-sample as channels become active: that would pump the reference.

**Acceptance:** Loudness comparisons cover mono, sparse/dense stereo, native beds, and correlated channels. Log matching offset and limiter reduction so a louder/compressed variant is not mistaken for a spatial improvement.

### M4. Improve limiter transparency and add true-peak awareness

**Observed:** The limiter is stereo-linked and sample-peak based, with a −1.5 dB threshold, −0.3 dB sample ceiling, 2 ms lookahead, and 160 ms release. Bass peaks can reduce the entire mix, including dialogue and room energy. A sample ceiling is not a guarantee about reconstructed intersample peaks.

Evidence: `Room.swift:214–260`. See [S10] for the sample-peak/true-peak distinction.

**Recommendation:** First expose gain reduction and limiting occupancy. Compare a smoother attack envelope that uses the available lookahead, and oversampled true-peak detection with an explicitly tested output ceiling. Avoid making multiband limiting the first solution: crossover and independent gain changes can affect spatial coherence.

Also directly test release recovery. The current expression stores only the rounded Float gain, not an independently decaying residual or explicit snap-to-unity; the comment claiming full recovery is not sufficient proof against a numerical stall.

**Acceptance:** Finite bounded output; isolated/alternating-ear peaks; high-frequency intersample-peak fixtures; loud bass with speech; recovery to documented unity tolerance; and transparent-mode transitions. A detector alone does not guarantee compliant true-peak limiting—verify the final output.

### M5. Preserve native sparse events and separate format from activity

**Observed:** Any non-L/R activity above −80 dBFS selects the native bed, held for three seconds. A 50 ms time-constant exponential fades toward it while all input audio is delayed 2048 samples.

Evidence: `Spatializer.swift:188–205,217–243,272–288`.

For a fresh isolated native event at 48 kHz, the bed weight is only approximately `1 − exp(−2048/2400) = 0.574` when its delayed onset arrives: roughly **−4.8 dB**, depending on block alignment/state. Events absent from the stereo upmix can thus be attenuated at entry. A real surround program can also revert to upmix during a long front-only passage.

**Recommendation:** Provide **Auto / Stereo upmix / Native bed** policies. Prefer trustworthy source layout information where available, but do not mistake BlackHole's 16-channel capacity for proof that all playback is native surround. In Auto, deliberately use the existing delay as detection lookahead or preserve newly active native channels independently of the L/R transition. Simply delaying detection would discard that useful lookahead.

Separately, any height activity is currently labeled “Atmos,” and the UI expands it to “9.1.6 bed.” PCM activity alone proves neither a codec nor a complete layout, and certainly not object metadata.

Evidence: `Layout.swift:44–51`, `Sources/Sfera/Controller.swift:161`.

**Acceptance:** Single-sample and short C/rear/height events after long stereo/front-only gaps retain intended onset level. Show transport layout, observed activity, and rendering policy separately; use labels such as “multichannel with height” when provenance is unknown.

---

## 6. Latency, numerical robustness, and integration

### E1. Make latency explicit and offer purposeful quality modes

**Observed:** All paths, including Original and native beds, inherit the 2048-sample upmix delay plus about 2 ms limiter lookahead. Base algorithmic delay is approximately **48.4 ms at 44.1 kHz, 44.7 ms at 48 kHz, and 23.3 ms at 96 kHz**, excluding direction-specific delays, Core Audio buffers, drift compensation, and Bluetooth.

Evidence: `Upmixer.swift:30`, `Spatializer.swift:109–121,217–228`, `Room.swift:214–215`.

**Recommendation:** Display algorithmic delay separately from measured or unknown end-to-end delay. Compare a lower-latency FFT mode for video/games against the existing music mode, or a native-bed-only path without STFT delay. Explicitly trade off seamless switching, frequency resolution, and extraction quality. A 1024-point FFT is an experiment, not a free equivalent replacement.

Fixed FFT size also changes the analysis duration/resolution across rates. Compare rate-scaled FFT sizes with a fixed internal DSP rate and high-quality conversion; include conversion cost/latency and avoid unnecessary double resampling. Do not force higher hardware sample rates just to reduce the sample-count delay.

**Acceptance:** Offline impulse timing across rates and block partitions, followed separately by actual wired/Bluetooth end-to-end measurements and video lip-sync checks.

### E2. Define safe numerical and public API contracts

**Recommendation:** Validate positive finite sample rate, capacities, frame counts, and bounded settings before constructing or updating the engine. The public process method silently truncates oversized requests; zero/negative counts also need an explicit contract. Session already chunks normal callbacks, so this is a library/API weakness rather than a demonstrated oversized-call app bug.

Evidence: `Spatializer.swift:96–110,178–193`, `Sources/Sfera/Session.swift:78–81`.

Guard mathematically bounded covariance quantities before square roots/divisions; have a defined nonfinite-input recovery policy that cannot poison delay/reverb history indefinitely. Normalize biquad coefficients in Double before final conversion and test low-frequency response against a Double reference. Float state alone is not proof of instability.

Evidence: `Upmixer.swift:313–350`, `Filters.swift:26–40`.

**Acceptance:** Invalid parameters are rejected or safely sanitized off-thread; randomized valid inputs stay finite; reset restores deterministic behavior; no allocating/logging error path is introduced in the callback.

### E3. Validate audio buffer layouts rather than assuming one stream

**Conditional correctness/safety issue:** Session counts source channels but reads one input buffer plus an optional planar-right buffer. General multistream/planar surround is not mapped fully. The second planar input/output copies use lengths derived from the first buffer without independently validating the other buffer's size.

Evidence: `Sources/Sfera/Session.swift:67–112,150`.

**Recommendation:** Prepare a validated stream/channel map before starting audio. Support advertised arrangements correctly or reject unsupported ones clearly. Bound every copy by the actual source/destination buffer capacity. This does not establish that the normal interleaved BlackHole route is currently broken.

**Acceptance:** Synthetic buffer-list tests for interleaved 2/16-channel, planar 2/16-channel, multiple stereo streams, nil data, unequal lengths, and mono output. These tests need no audible hardware probe.

### E4. Verify routing writes and preserve recovery information

**Observed risk:** Critical default-output changes are not checked; restoration deletes the saved output UID even if the device is absent or the write fails. Layout/rate changes also lack a fully verified readback path.

Evidence: `Controller.swift:255,286,328–335`, `Session.swift:152–158`.

**Recommendation:** Check status and resulting layout/rate/route, retain restoration information until success or explicit user resolution, and distinguish degraded operation from a healthy surround route. Preserve the existing fallback-to-real-output behavior; do not rewrite routing merely to add DSP features.

Consider a user-selected output and a **pause rather than switch to speakers on unplug** policy. Automatic fallback can be undesirable for privacy or unexpected volume. Remember output/headphone profiles and restore device state where appropriate; current BlackHole startup volume is deliberately set to 0.5, so any revised policy must preserve usable volume keys without surprise jumps.

**Acceptance:** Inject failed writes, absent saved devices, denied permissions, unplug/replug, rate changes, sleep/wake, interrupted startup, and crash recovery. A running IOProc or a plausible UI label is not proof that the intended signal route works.

### E5. Preserve real-time strengths and measure worst cases

Keep initialization-time allocation, shared late reverb, SIMD analysis, batched FFT/transcendental work, skipped unused transforms, and idle behavior. These are valuable foundations, not things to discard for a more elaborate room.

**Recommendation:** Give every quality feature a CPU/memory/latency budget. File parsing, SOFA/BRIR resampling, filter preparation, and large graph construction stay off the callback. Use safe lifetime ownership when swapping prepared state. Profile transitions and wake/reset as well as steady state: clearing histories on wake can cost more than average throughput suggests.

**Acceptance:** Callback median/p99/maximum, deadline margin, and underruns on the actual installed app at small buffers, high rates, 16-channel Far, upmix↔bed transitions, and full wake. Existing average DSP benchmarks do not establish that budget for a new renderer.

---

## 7. Small app changes that make audio tuning more useful

1. **Keep the main panel simple.** Preserve Room and Spatial/Original; add advanced controls only where they correspond to independent engine parameters. Do not expose every reflection tap as a normal-user slider.
2. **Make applicability clear.** Current Centre/Width/Surround/Height controls tune stereo upmix, not native-bed trims (`UI/Panel.swift:261–269`). Explain or dim them during native playback. If adding native trims, keep neutral defaults and separate them from upmix settings.
3. **Show actual diagnostics.** Sample rate, selected renderer/profile, transport channel map, algorithmic latency, input/output levels, limiter reduction, and route health. Keep meters atomic/low-rate and mostly inactive with the panel closed.
4. **Make the sound field honest.** Generated upmix dots are currently schematic, not measured generated-feed activity (`UI/SoundField.swift:127–133`). Either say so or drive them from per-feed energy; do not imply all heights are active for mono just because the target layout includes them.
5. **Add a safe channel audition.** A deliberately quiet, explicit test can identify L/R/C/rear/height routing, with an immediate stop. Avoid surprising full-level test tones or background diagnostic playback.
6. **Save comparison presets.** Per-headphone/device presets, copy/reset, and a temporary A/B comparison slot. Persist renderer/profile version and calibration, so an update does not silently change Far.
7. **Expose errors independently of route notes.** The current route-note branch can suppress the error branch (`UI/Panel.swift:131–151`). A degraded route should remain actionable.
8. **Improve control accessibility.** Custom switches currently expose generic On/Off labels rather than their purpose (`UI/Theme.swift:66`). Verify purpose/state, keyboard adjustment for custom sliders, focus, VoiceOver, and reduced-motion behavior. These are static review opportunities, not a completed accessibility audit.
9. **Keep anti-double-processing guidance visible.** Already-binaural tracks and upstream headphone spatialization can be degraded by another HRTF/room pass. Provide a clear bypass/exclusion workflow. Automatic detection from arbitrary stereo is not reliably solvable by channel count alone.

---

## 8. Validation: prove improvements independently of legacy equivalence

### 8.1 Repair the existing harness first

The current compatibility benchmark is valuable, but it cannot establish perceptual quality or catch defects shared by both engines.

Concrete gaps:

- **Nonfinite errors can look perfect.** `db(x)` returns −400 when `x > 0` is false, including NaN. Fail on nonfinite samples and metrics before comparison (`Bench/Sources/Bench/main.swift:165–187`).
- **Per-channel mode only prints.** `--channels` exits without assertions; L/R-only stimuli also do not force native-bed rendering (`:200–210`).
- **A build failure can be swallowed.** `Bench/run.sh:13` permits the pipeline to fail and then attempts to run the binary; an older artifact could give misleading results.
- **Hardware checks are nonfatal.** `Scripts/check.sh` still ends with a success-looking completion message when route/tap checks fail. Report **passed / failed / skipped / blocked** separately; strict runtime validation should fail when a required check does not work.
- **Callbacks are not proof of captured audio.** The tap probe's callback-based success criterion needs a known-signal check (`Sources/Sfera/Probe.swift:239`).
- **The reference runner needs care.** Missing channels repeat the last source channel, output tails are not flushed, and limiter tests do not independently assert meaningful gain reduction (`Bench/Sources/Bench/main.swift:91–110,286–295`).
- **Most equivalence tests use 48 kHz / 512 frames.** Add rate/partition coverage and independent peak/onset assertions, not only whole-program RMS differences.
- **No dedicated Swift test target exists.** Add one for DSP invariants and synthetic buffer/routing-policy tests (`Package.swift`).

Keep Classic equivalence tests. Add separate expected behavior for the new renderer instead of loosening old thresholds until intentional changes pass.

### 8.2 Objective acceptance matrix

| Area | Required fixtures | What to establish |
|---|---|---|
| Reconstruction | Neutral extraction settings; impulses, noise, DC/Nyquist | Correct latency and null behavior; no changed FFT normalization without proof |
| Direct mixing | L-only/R-only, pan sweep, extraction/width sweeps | No unintended coherent gain peak; defined energy/loudness policy |
| Phase handling | Equal/unequal inversion, quadrature, delay-panned stereo | Appropriate center eligibility and stable original relationships |
| Transients | Impulses at every hop offset, percussion, speech attacks | Pre-arrival energy, attack retention, consistent placement |
| Native adaptation | Isolated C/rear/height events after long front-only gaps | Onset preservation and policy stability |
| Directional cues | Each speaker/reflection separately; mirrored positions | Correct ear/sign conventions, ITD, elevation response and gain |
| Room | Per-source impulses, mono/stereo noise, sustained notes | Bandwise decay, early/late energy, echo density, interaural coherence, no growth/ringing |
| Bass | Native/generated LFE sweeps; correlated main+LFE | Intentional bandwidth, phase and room-independent reference |
| Limiting | Sparse peaks, alternating ears, bass+speech, intersample peaks | Final ceiling, gain reduction, recovery and image stability |
| Lifecycle | Rapid settings changes, Dry re-entry, silence/wake, reset | No stale tails/clicks; deterministic reset and safe sleep behavior |
| Rates/blocks | 44.1/48/88.2/96/192 kHz where supported; tiny/odd/random/large blocks | No delay clipping, dropped samples or unexplained partition dependence |
| Robustness | Invalid settings, nonfinite samples, malformed buffer lists | Defined rejection/recovery; bounded finite output |
| Runtime | Packaged app, BlackHole and process tap, wired DAC/Bluetooth | Actual signal delivery, route restoration, deadline margin, latency |

For stable settings require partition-invariant sample streams within numerical tolerance. Adaptive decisions currently depend on callback boundaries; either make them sample-time based or document/test a bounded transition tolerance.

### 8.3 Listening acceptance for an improved Far

1. Use current Far as the main reference, plus Original and the optional stereo-speaker mode.
2. Change one family at a time: timing, reflection directionality, early/late balance, HRTF, extraction, or bass. Avoid a giant “everything improved” preset that hides causality.
3. Match programme loudness closely using an agreed tolerance, record the applied offset, and compare at similar limiter activity. A practical initial matching target is within roughly 0.5 LU where feasible; this is an evaluation target, not a claim about current matching accuracy.
4. Randomize/hide variant names and use repeatable excerpts. ABX can test audibility; use separate preference/localization ratings to decide whether a detectable difference is better.
5. Include dry mono speech, acoustic music, dense pop, percussion, wide electronic tracks, natural recorded reverberation, sparse native surround, and authored height/LFE material. Use lawful local fixtures; no upload of personal audio is required.
6. Rate **outside-the-head impression, frontal distance, vocal focus, front/back errors, elevation, tonal naturalness, transient clarity, fatigue, and overall preference** separately.
7. Test the user's normal headphones first, then other fits/devices/listeners if broad product claims are intended. Generic HRTF improvements need not generalize to every person.
8. Keep an experiment only if it improves the intended attributes without an unacceptable loss of clarity, tone, comfort, or reliability. Farther/wider/more reverberant is not automatically better.

### 8.4 What remains unverified

Existing `docs/VALIDATION.md` explicitly leaves listening, normal-user process-tap capture, actual Apple Music Atmos delivery, and KA13 behavior unverified. Those historical notes were read, not rerun or converted into new evidence here. Tagged 16-channel test tones establish channel transport, not Apple Music codec provenance or object rendering.

The full `Scripts/check.sh` was intentionally not run for this document-only review: it builds, changes real audio routes during probes, and rewrites screenshots. Future implementation should run appropriate offline tests first and perform authorized device-path acceptance separately.

---

## 9. Suggested implementation sequence

### Phase A — Protect the baseline and establish trustworthy tests

Preserve Classic and saved fixtures. Fix finite checks, build failure propagation, asserted channel tests, tail flushing, and strict/skipped runtime reporting. Add independent gain, timing, phase, LFE, lifecycle, and buffer-layout tests.

**Exit:** The suite can detect the specific problems described here; it cannot mistake NaN, a stale build, silence, or a skipped device test for success.

### Phase B — Correctness without a wholesale sound redesign

Address coherent remapping, center phase eligibility, sparse native onsets, Dry lifecycle, high-rate delay bounds, and native-LFE policy. Add output/limiter diagnostics and explicit rendering policy. Correct geometry in the opt-in renderer while leaving Classic available.

**Exit:** Deterministic tests pass, the installed route remains reliable, and controls do not introduce unexplained gain or state discontinuities.

### Phase C — A focused “better Far” prototype

Start with **source-aware early reflections + independently adjustable early/late balance + calibrated bass/loudness**. Keep the present late FDN initially. Compare variants at matched loudness; then evaluate diffusion/decay and transient-aware sends if needed.

**Exit:** The user prefers a repeatable variant to Classic on normal listening material without an unacceptable clarity or fatigue penalty. This is the first meaningful perceptual milestone—not merely a successful build.

### Phase D — Raise the realism ceiling

Compare measured HRTF profiles and coherent headphone compensation, then optional BRIR rooms. Consider head tracking after platform capabilities and performance are verified. Offer quality/latency tiers only when they solve a demonstrated use case.

**Exit:** Gains justify the additional CPU, latency, data/licensing complexity, and user controls.

### Avoid as default approaches

- Longer/louder reverb, wider panning, more height, or louder bass as automatic “improvements.”
- Fast loudness normalization to hide mixing gain errors.
- Mandatory AI source separation before simpler DSP is evaluated; it adds model, latency, artifact, and resource costs.
- Claiming object-based Atmos reconstruction from a PCM bed or codec identity from active channels.
- Combining full BRIR rendering with another complete HRTF/room pass.
- Removing the low-CPU renderer or silently changing existing saved Far preferences.
- Copying proprietary DSP, unlicensed impulse captures, or treating forum preferences as controlled evidence.

---

## 10. Sources and how they inform this proposal

### Research and standards

- **[S1] Best et al. — [Sound Externalization: A Review of Recent Research](https://pmc.ncbi.nlm.nih.gov/articles/PMC7488874/).** Read the review's discussion of reverberation, binaural information, listener variation, and dynamic cues. Supports directional reflections and controlled externalization tests; does not establish a universally best room, HRTF, or reverb duration.
- **[S2] Aaronson & Hartmann — [Testing, correcting, and extending the Woodworth model for interaural time difference](https://pmc.ncbi.nlm.nih.gov/articles/PMC3985894/).** Read the front/rear formulas and model limitations. Direct support for the rear-hemisphere geometry finding, not a guarantee of listener preference.
- **[S8] Schlecht & Habets — [Accurate Reverberation Time Control in Feedback Delay Networks](https://dafx.de/paper-archive/2017/papers/DAFx17_paper_11.pdf).** Consulted the indexed abstract/technical excerpt, not a full paper reproduction. Supports designing frequency-dependent attenuation in relation to line length and measuring actual decay.
- **[S9] He & Gan — [Applying Primary Ambient Extraction for Immersive Spatial Audio Reproduction](https://sigport.org/sites/default/files/HeG15_Applying%20Primary%20Ambient%20Extraction%20for%20Immersive%20Spatial%20Audio%20Reproduction-IEEE%20approved.pdf).** Consulted indexed technical excerpts on PCA/masking, model assumptions, smoothing, time differences, and decorrelation. Inspiration for comparisons, not proof that a replacement beats this implementation.
- **[S10] ITU-R — [BS.1770-1: Algorithms to measure audio programme loudness and true-peak audio level](https://www.itu.int/dms_pubrec/itu-r/rec/bs/R-REC-BS.1770-1-200709-S!!PDF-E.pdf).** Consulted the indexed Annex 2 excerpt explaining reconstructed peaks and oversampled estimation. This older edition is cited for that distinction; choose and validate against the applicable current revision before claiming standards compliance.

### Open implementations and datasets

- **[S3] [libmysofa documentation](https://hoene.github.io/libmysofa/).** Read API documentation for SOFA loading, resampling, interpolation, normalization, coordinates, and delay units. In particular, float filter delays are seconds; mishandling those units would break localization. Loading support does not provide the real-time convolver itself.
- **[S4] University of York — [SADIE II database](https://www.york.ac.uk/sadie-project/database.html).** Read the database description: HRIRs, BRIRs, headphone responses, measurement directions, and multiple sample rates. Dataset redistribution rights and metadata must be verified before bundling.
- **[S5] [Impulcifer](https://github.com/jaakkopasanen/Impulcifer).** Read project documentation describing personalized measured-room speaker virtualization. Useful inspiration for an optional advanced workflow; its stronger promotional claims are not substituted for the more qualified research findings in [S1].
- **[S6] ASH Listening Set — [Accessing the BRIRs](https://github.com/ShanonPearce/ASH-Listening-Set/wiki/Accessing-the-BRIRs).** Read per-source/per-ear, true-stereo, and HeSuVi channel mappings. Useful for avoiding ear/order mistakes when evaluating BRIR import; formats are not interchangeable by assumption.

### Community inspiration, not scientific evidence

- **[S7] [HeSuVi discussion on HardForum](https://hardforum.com/threads/hesuvi-a-headphone-surround-virtualizations-for-equalizer-apo.1955893/).** Read participants' contrasting preferences for reverb/profile switching and concerns about clarity or exaggerated processing. The useful product lesson is easy comparison and independent room control—not that any particular commercial algorithm or forum recommendation is objectively superior. This is not Reddit, and no claim of Reddit coverage is made.

## Bottom line

**The strongest first prototype is Far's existing sense of space, with cleaner direct mixing, preserved native onsets, better directional early reflections, independent early/late balance, and stable bass/loudness.** Measured HRTFs, measured rooms, and tracking can raise the ceiling later. Preserve what already sounds good, and require listening evidence before calling a more complicated renderer better.
