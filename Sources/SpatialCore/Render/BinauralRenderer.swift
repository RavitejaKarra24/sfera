import Foundation

/// Synthetic-HRTF binaural renderer.
///
/// The spatialisation model is an independent implementation built from published
/// psychoacoustics rather than a measured HRIR set: Woodworth interaural time
/// difference, frequency-dependent contralateral head shadow, a rear-hemisphere
/// shadow term, and an elevation-dependent spectral notch. It is not the Dolby
/// binaural renderer and makes no claim of numerical equivalence.
public enum BinauralRenderer {
    private struct Voice {
        var notchL = Biquad()
        var notchR = Biquad()
        var shadowL = OnePole()
        var shadowR = OnePole()
        var delayL = FractionalDelay(maxDelaySamples: 128)
        var delayR = FractionalDelay(maxDelaySamples: 128)
        var spread = FractionalDelay(maxDelaySamples: 32)
        var azimuth = 0.0
        var elevation = 0.0
        var gain: Float = 0
        var size = 0.0
        var initialized = false
    }

    private static let speedOfSound = 343.0
    private static let headRadius = 0.0875
    static let maxITD = headRadius / speedOfSound * (.pi + 1)

    /// Static binaural cues for one direction. Shared by the offline renderer and the
    /// live engine so both apply identical HRTF-model parameters.
    public struct Cue: Sendable {
        public var shadowCutoffL: Double
        public var shadowCutoffR: Double
        public var notchGainDB: Double
        public var delayL: Float
        public var delayR: Float
        public var ildL: Float
        public var ildR: Float
        /// Constant-power lateral pan: used for room sends and the Off (stereo) render mode.
        public var panL: Float
        public var panR: Float
    }

    public static func cue(azimuth: Double, elevation: Double, sampleRate: Double) -> Cue {
        let lateral = sin(azimuth * .pi / 180)
        let rear = max(0, (abs(azimuth) / 180 - 0.5) * 2)
        let shadowLeft = min(max(max(lateral, 0) * 0.95 + rear * 0.35, 0), 1)
        let shadowRight = min(max(max(-lateral, 0) * 0.95 + rear * 0.35, 0), 1)
        let elevationNorm = min(max(elevation / 60.0, 0), 1)
        let itdSeconds = abs(maxITD * (abs(azimuth) * .pi / 180 + sin(abs(azimuth) * .pi / 180)) / (.pi + 1))
        let panAngle = (lateral + 1) * .pi / 4
        return Cue(
            shadowCutoffL: 18000 * pow(1100.0 / 18000.0, shadowLeft),
            shadowCutoffR: 18000 * pow(1100.0 / 18000.0, shadowRight),
            notchGainDB: -5.0 * elevationNorm,
            delayL: azimuth > 0 ? Float(itdSeconds * sampleRate) : 0,
            delayR: azimuth < 0 ? Float(itdSeconds * sampleRate) : 0,
            ildL: Float(1 - 0.28 * shadowLeft),
            ildR: Float(1 - 0.28 * shadowRight),
            panL: Float(cos(panAngle)),
            panR: Float(sin(panAngle))
        )
    }

    /// Distance gain for a bed channel or object on the unit sphere (radius 1).
    public static func distanceGain(radius: Double) -> Float { Float(1.0 / (1.0 + 0.7 * radius)) }

    public static func render(
        sources: [RenderSource],
        frames: Int,
        settings: RenderSettings,
        progress: ((Double) -> Void)? = nil
    ) -> (PlanarAudio, RenderStats) {
        let sampleRate = settings.sampleRate
        var stats = RenderStats()
        stats.frames = frames
        guard frames > 0 else {
            return (PlanarAudio(silenceChannels: 2, frames: 0, sampleRate: sampleRate), stats)
        }

        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        let blockSize = 32
        let blockCount = (frames + blockSize - 1) / blockSize
        let maxDelaySamples = Float(maxITD * sampleRate + 2)

        var voices: [Int: Voice] = [:]
        var lfe = [Float](repeating: 0, count: frames)
        var hasLFE = false
        var sendL = [Float](repeating: 0, count: frames)
        var sendR = [Float](repeating: 0, count: frames)
        var roomUsed = false

        for (sourceIndex, source) in sources.enumerated() {
            if case .bed(.lfe) = source.kind {
                hasLFE = true
                let g = AudioMath.dbToGain(source.gainDB)
                for i in 0..<min(frames, source.audio.count) { lfe[i] += source.audio[i] * g }
                progress?(Double(sourceIndex + 1) / Double(max(sources.count, 1)))
                continue
            }
            var voice = voices[source.id] ?? Voice()
            let gainLinear = AudioMath.dbToGain(source.gainDB + source.distance.attenuationDB)
            let framesForSource = min(frames, source.audio.count)
            let bypass = source.distance == .off
            let roomSend = settings.binauralRoom ? AudioMath.dbToGain(source.distance.roomSendDB) : 0
            if roomSend > 0 { roomUsed = true }

            for block in 0..<blockCount {
                let start = block * blockSize
                let end = min(start + blockSize, framesForSource)
                if start >= end { break }
                let time = Double(start) / sampleRate
                let point = source.bedPosition ?? source.position(at: time)
                let sphere = point.spherical
                let targetAz = sphere.azimuth
                let targetEl = sphere.elevation
                let targetGain = gainLinear * Self.distanceGain(radius: sphere.radius)
                let targetSize = source.size(at: time)

                if !voice.initialized {
                    voice.azimuth = targetAz
                    voice.elevation = targetEl
                    voice.gain = targetGain
                    voice.size = targetSize
                    voice.initialized = true
                }

                let cue = Self.cue(azimuth: targetAz, elevation: targetEl, sampleRate: sampleRate)
                voice.shadowL.setCutoff(cue.shadowCutoffL, sampleRate: sampleRate)
                voice.shadowR.setCutoff(cue.shadowCutoffR, sampleRate: sampleRate)
                // Retune in place: rebuilding the biquad here reset its state every block,
                // which put a 1.5 kHz buzz (fs/32) on every elevated source.
                let notch = Biquad.peaking(frequency: 8200, gainDB: cue.notchGainDB, q: 1.3, sampleRate: sampleRate)
                voice.notchL.setCoefficients(notch)
                voice.notchR.setCoefficients(notch)
                let delayLeft = cue.delayL, delayRight = cue.delayR
                let ildLeft = cue.ildL, ildRight = cue.ildR
                let panL = cue.panL, panR = cue.panR

                let startGain = voice.gain
                let startSize = voice.size
                let count = end - start
                guard count > 0 else { continue }
                let gainStep = (targetGain - startGain) / Float(count)
                let sizeStep = (targetSize - startSize) / Double(count)

                if bypass {
                    for i in 0..<count {
                        let g = (startGain + gainStep * Float(i))
                        let x = source.audio[start + i] * g
                        left[start + i] += x * panL
                        right[start + i] += x * panR
                    }
                    voice.gain = targetGain
                    continue
                }

                for i in 0..<count {
                    let x = source.audio[start + i]
                    if roomSend > 0 {
                        let s = x * (startGain + gainStep * Float(i)) * roomSend
                        sendL[start + i] += s * panL
                        sendR[start + i] += s * panR
                    }
                    let sizeNow = startSize + sizeStep * Double(i)
                    let gainNow = startGain + gainStep * Float(i)
                    let spreadTap = voice.spread.process(x, delay: Float(6 + 10 * sizeNow))
                    let diffused = x * Float(1 - 0.35 * sizeNow) + spreadTap * Float(0.35 * sizeNow)

                    let l = voice.delayL.process(voice.shadowL.process(voice.notchL.process(diffused)), delay: delayLeft)
                    let r = voice.delayR.process(voice.shadowR.process(voice.notchR.process(diffused)), delay: delayRight)
                    left[start + i] += l * gainNow * ildLeft
                    right[start + i] += r * gainNow * ildRight
                }

                voice.azimuth = targetAz
                voice.elevation = targetEl
                voice.gain = targetGain
                voice.size = targetSize
            }
            voices[source.id] = voice
            if case .object = source.kind { stats.renderedObjects += 1 } else { stats.renderedBedChannels += 1 }
            progress?(Double(sourceIndex + 1) / Double(max(sources.count, 1)))
        }

        if roomUsed {
            let room = BinauralRoom.process(sendL: sendL, sendR: sendR, sampleRate: sampleRate)
            for i in 0..<frames {
                left[i] += room.left[i]
                right[i] += room.right[i]
            }
        }

        // Bass management: the LFE is folded into the binaural pair, matching the
        // documented +5.5 dB binaural LFE treatment.
        if hasLFE, settings.bass.enabled {
            var filterL = Biquad.lowPass(frequency: settings.bass.crossoverHz, sampleRate: sampleRate)
            var filterR = Biquad.lowPass(frequency: settings.bass.crossoverHz, sampleRate: sampleRate)
            let g = AudioMath.dbToGain(settings.bass.lfeToStereoDB)
            for i in 0..<frames {
                let s = lfe[i] * g * 0.5
                left[i] += filterL.process(s)
                right[i] += filterR.process(s)
            }
        }

        let gain = AudioMath.dbToGain(settings.outputGainDB)
        if gain != 1 {
            for i in 0..<frames { left[i] *= gain; right[i] *= gain }
        }

        var audio = PlanarAudio(sampleRate: sampleRate, channels: [left, right])
        let limited = LookaheadLimiter.process(audio, settings: settings.limiter)
        audio = limited.audio
        stats.limitingDB = limited.maxReductionDB
        stats.peak = audio.peak()
        _ = maxDelaySamples
        return (audio, stats)
    }
}
