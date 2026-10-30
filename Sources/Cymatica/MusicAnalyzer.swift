import Accelerate
import Foundation

/// What the plate needs to know about the music right now.
struct MusicFrame {
    /// Plate excitation, 0 (still) ... ~1.2 (loud passage with an onset).
    var drive: Float = 0
    var onset: Float = 0
    /// Stable dominant pitch class, 0 = C ... 11 = B.
    var pitchClass = 9
    /// Song-section complexity: 0 quiet (simple figures) ... 2 loudest section (intricate).
    var tier = 1
    /// Frequency of the strongest partial in the dominant pitch class.
    var noteHz: Float = 440
    /// 0 = major key, 1 = minor key.
    var minorness: Float = 0
    var silent = true
    var dbfs: Float = -120
    /// Loudness relative to the last minute, 0 ... 1.
    var level: Float = 0
    /// True on the frame a strong onset (kick, snare, chord hit) lands.
    var beat = false
}

/// Magnitude spectrum of the newest samples in the ring. All buffers are preallocated.
final class SpectrumFFT {
    let size: Int
    let bins: Int
    let magnitudes: UnsafeMutablePointer<Float>
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let samples: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>

    init(log2n: Int) {
        self.log2n = vDSP_Length(log2n)
        size = 1 << log2n
        bins = size / 2
        setup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2))!
        window = .allocate(capacity: size)
        vDSP_hann_window(window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        samples = .allocate(capacity: size)
        real = .allocate(capacity: bins)
        imag = .allocate(capacity: bins)
        magnitudes = .allocate(capacity: bins)
        magnitudes.initialize(repeating: 0, count: bins)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        for buffer in [window, samples, real, imag, magnitudes] { buffer.deallocate() }
    }

    func analyze(_ ring: AudioRing) {
        ring.readLatest(into: samples, count: size)
        vDSP_vmul(samples, 1, window, 1, samples, 1, vDSP_Length(size))
        var split = DSPSplitComplex(realp: real, imagp: imag)
        samples.withMemoryRebound(to: DSPComplex.self, capacity: bins) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(bins))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
        imag[0] = 0 // zrip packs the Nyquist term here
        vDSP_zvabs(&split, 1, magnitudes, 1, vDSP_Length(bins))
        var scale = 2 / Float(size)
        vDSP_vsmul(magnitudes, 1, &scale, magnitudes, 1, vDSP_Length(bins))
    }
}

/// Turns raw audio into slow, musical decisions. The plate needs 1–2 s to settle into a
/// figure, so the dominant pitch class only changes when a new one clearly wins and
/// holds, and the complexity tier follows song sections rather than single beats.
final class MusicAnalyzer {
    var sampleRate: Float
    private let ring: AudioRing
    private let harmony = SpectrumFFT(log2n: 14)   // ~0.34 s window, ~3 Hz bins
    private let transient = SpectrumFFT(log2n: 11) // ~43 ms window for onsets
    private let levelWindow: UnsafeMutablePointer<Float>
    private let levelCount = 2048
    private let previousSpectrum: UnsafeMutablePointer<Float>
    private let fluxBins = 512

    private var rawChroma = [Float](repeating: 0, count: 12)
    private var chroma = [Float](repeating: 0, count: 12)
    private var chromaSlow = [Float](repeating: 1.0 / 12, count: 12)
    private var peakMagnitude = [Float](repeating: 0, count: 12)
    private var peakFrequency = [Float](repeating: 0, count: 12)

    private var frame = MusicFrame()
    private var lastWritten = 0
    private var staleFor: Float = 0
    private var silentFor: Float = 100
    private var audibleFor: Float = 0
    private var sinceReset: Float = 0
    private var sectionDb: Float = -30
    private var longDb: Float = -20
    private var fluxMean: Float = 0
    private var onsetEnvelope: Float = 0
    private var sinceBeat: Float = 10
    private var candidate = -1
    private var candidateAge: Float = 0
    private var sinceSwitch: Float = 100
    private var sinceTierSwitch: Float = 100
    private var sinceKeyEstimate: Float = 0
    private var hasPitch = false
    private var harmonyElapsed: Float = 0

    init(ring: AudioRing, sampleRate: Float) {
        self.ring = ring
        self.sampleRate = sampleRate
        levelWindow = .allocate(capacity: levelCount)
        previousSpectrum = .allocate(capacity: fluxBins)
        previousSpectrum.initialize(repeating: 0, count: fluxBins)
    }

    deinit {
        levelWindow.deallocate()
        previousSpectrum.deallocate()
    }

    func update(dt: Float) -> MusicFrame {
        // A stalled stream (tap stopped, device gone) must read as silence, not as a
        // frozen copy of the last second of music.
        let written = ring.totalWritten
        if written == lastWritten { staleFor += dt } else { staleFor = 0; lastWritten = written }

        ring.readLatest(into: levelWindow, count: levelCount)
        var rms: Float = 0
        vDSP_rmsqv(levelWindow, 1, &rms, vDSP_Length(levelCount))
        let db = staleFor > 0.25 ? -120 : 20 * log10f(max(rms, 1e-7))
        frame.dbfs = db

        sinceReset += dt
        if db > -57 {
            // Back after a long pause (new listening session): restart the loudness
            // reference at the middle tier instead of judging against stale levels.
            if silentFor > 10 {
                sectionDb = db
                longDb = db
                sinceReset = 0
                sinceTierSwitch = 0
                frame.tier = 1
            }
            silentFor = 0
            audibleFor += dt
            sectionDb = ema(sectionDb, db, tau: sinceReset < 4 ? 0.5 : 2.5, dt: dt)
            // Learn the new level quickly at first (songs often fade in), then slowly.
            longDb = ema(longDb, db, tau: sinceReset < 4 ? 1 : 60, dt: dt)
        } else {
            audibleFor = 0
            if db < -62 { silentFor += dt }
        }
        frame.silent = silentFor > 0.6

        updateOnsets(dt: dt)
        // Harmony moves slowly; 30 analyses a second are plenty for the long FFT.
        harmonyElapsed += dt
        if harmonyElapsed >= 1.0 / 30 {
            updateHarmony(dt: harmonyElapsed)
            harmonyElapsed = 0
        }
        updateTier(dt: dt)

        let level = clamp((db - (longDb - 12)) / 24)
        let target: Float = frame.silent ? 0 : min(0.45 + 0.5 * level + 0.25 * onsetEnvelope, 1.2)
        frame.drive = ema(frame.drive, target, tau: target > frame.drive ? 0.06 : 0.35, dt: dt)
        frame.onset = onsetEnvelope
        frame.level = frame.silent ? 0 : level
        return frame
    }

    // MARK: - Onsets (spectral flux)

    private func updateOnsets(dt: Float) {
        transient.analyze(ring)
        var flux: Float = 0
        for bin in 1..<fluxBins {
            let value = log1pf(1000 * transient.magnitudes[bin])
            flux += max(0, value - previousSpectrum[bin])
            previousSpectrum[bin] = value
        }
        fluxMean = ema(fluxMean, flux, tau: 1.2, dt: dt)
        let onset = frame.silent ? 0 : clamp((flux / (fluxMean + 1e-3) - 1.6) / 2)
        onsetEnvelope = max(onsetEnvelope * expf(-dt / 0.14), onset)
        // A beat is a strong onset at least 0.3 s after the previous one.
        sinceBeat += dt
        frame.beat = onset > 0.45 && sinceBeat > 0.3
        if frame.beat { sinceBeat = 0 }
    }

    // MARK: - Harmony (chroma)

    private func updateHarmony(dt: Float) {
        harmony.analyze(ring)
        guard !frame.silent, measureChroma() else { return }
        for index in 0..<12 {
            chroma[index] = ema(chroma[index], rawChroma[index], tau: 0.7, dt: dt)
            chromaSlow[index] = ema(chromaSlow[index], rawChroma[index], tau: 6, dt: dt)
        }

        var best = 0
        var total: Float = 0
        for index in 0..<12 {
            total += chroma[index]
            if chroma[index] > chroma[best] { best = index }
        }
        let clarity = chroma[best] / max(total / 12, 1e-6)

        sinceSwitch += dt
        if !hasPitch {
            // Wait until the long FFT window holds only music, not the silence before it.
            if clarity > 1.4, audibleFor > 0.4 { switchPitch(to: best) }
        } else if best == frame.pitchClass {
            candidate = -1
            candidateAge = 0
        } else {
            if best != candidate { candidate = best; candidateAge = 0 } else { candidateAge += dt }
            let decisive = chroma[best] > chroma[frame.pitchClass] * 1.22
            if candidateAge > 0.3, sinceSwitch > 2.2, decisive, clarity > 1.5 {
                switchPitch(to: best)
            }
        }

        sinceKeyEstimate += dt
        if sinceKeyEstimate > 0.5 {
            sinceKeyEstimate = 0
            frame.minorness = ema(frame.minorness, estimateMinor() ? 1 : 0, tau: 3, dt: 0.5)
        }
    }

    private func switchPitch(to pitchClass: Int) {
        frame.pitchClass = pitchClass
        let hz = peakFrequency[pitchClass]
        frame.noteHz = hz > 0 ? hz : 261.63 * powf(2, Float(pitchClass) / 12)
        hasPitch = true
        sinceSwitch = 0
        candidate = -1
        candidateAge = 0
    }

    /// Peak-picked chroma: only spectral peaks vote, weighted by how close they sit to an
    /// equal-tempered pitch. Drums and noise have few clean peaks, so they barely count.
    private func measureChroma() -> Bool {
        let magnitudes = harmony.magnitudes
        let binHz = sampleRate / Float(harmony.size)
        let low = max(2, Int(65 / binHz))
        let high = min(harmony.bins - 2, Int(4200 / binHz))
        var peak: Float = 0
        vDSP_maxv(magnitudes + low, 1, &peak, vDSP_Length(high - low))
        for index in 0..<12 { rawChroma[index] = 0; peakMagnitude[index] = 0 }
        guard peak > 1e-5 else { return false }

        let floor = peak * 0.05
        for bin in low...high {
            let magnitude = magnitudes[bin]
            guard magnitude > floor, magnitude > magnitudes[bin - 1], magnitude >= magnitudes[bin + 1] else { continue }
            let a = logf(magnitudes[bin - 1] + 1e-9), b = logf(magnitude + 1e-9), c = logf(magnitudes[bin + 1] + 1e-9)
            let curvature = a - 2 * b + c
            let offset = curvature < 0 ? 0.5 * (a - c) / curvature : 0
            let hz = (Float(bin) + offset) * binHz
            let midi = 69 + 12 * log2f(hz / 440)
            let nearest = midi.rounded()
            let weight = powf(magnitude / peak, 0.6) * max(0, 1 - 2 * abs(midi - nearest)) * Self.bandWeight(hz)
            guard weight > 0 else { continue }
            let pitchClass = ((Int(nearest) % 12) + 12) % 12
            rawChroma[pitchClass] += weight
            if magnitude > peakMagnitude[pitchClass] {
                peakMagnitude[pitchClass] = magnitude
                peakFrequency[pitchClass] = hz
            }
        }

        let strongest = rawChroma.max() ?? 0
        guard strongest > 0 else { return false }
        for index in 0..<12 { rawChroma[index] /= strongest }
        return true
    }

    private static func bandWeight(_ hz: Float) -> Float {
        smoothstep(55, 110, hz) * (1 - 0.6 * smoothstep(1200, 4000, hz))
    }

    // Krumhansl–Kessler key profiles.
    private static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    private func estimateMinor() -> Bool {
        var bestMajor: Float = -2, bestMinor: Float = -2
        for root in 0..<12 {
            bestMajor = max(bestMajor, correlation(Self.majorProfile, root: root))
            bestMinor = max(bestMinor, correlation(Self.minorProfile, root: root))
        }
        return bestMinor > bestMajor
    }

    private func correlation(_ profile: [Float], root: Int) -> Float {
        var meanX: Float = 0, meanY: Float = 0
        for index in 0..<12 { meanX += chromaSlow[index]; meanY += profile[index] }
        meanX /= 12
        meanY /= 12
        var covariance: Float = 0, varianceX: Float = 0, varianceY: Float = 0
        for index in 0..<12 {
            let x = chromaSlow[(index + root) % 12] - meanX
            let y = profile[index] - meanY
            covariance += x * y
            varianceX += x * x
            varianceY += y * y
        }
        return covariance / max(sqrtf(varianceX * varianceY), 1e-9)
    }

    // MARK: - Song sections

    /// Loudness of the current section relative to the last minute of listening.
    /// Choruses climb to the intricate tier, intros and breakdowns fall to simple figures.
    private func updateTier(dt: Float) {
        sinceTierSwitch += dt
        guard !frame.silent else { return }
        let relative = sectionDb - longDb
        let boundaries: [Float] = [-3.5, 1.5] // between tier 0|1 and 1|2
        let hysteresis: Float = 0.75
        var desired = frame.tier
        if desired < 2, relative > boundaries[desired] + hysteresis {
            desired += 1
        } else if desired > 0, relative < boundaries[desired - 1] - hysteresis {
            desired -= 1
        }
        if desired != frame.tier, sinceTierSwitch > 5 {
            frame.tier = desired
            sinceTierSwitch = 0
        }
    }
}

/// A slow chord progression for `--demo` and snapshots, so the plate can be judged
/// without any audio.
struct DemoDriver {
    private var time: Float = 0
    private let progression = [0, 9, 5, 7, 2, 11, 4, 9]

    mutating func next(dt: Float) -> MusicFrame {
        time += dt
        let step = Int(time / 4.5)
        var frame = MusicFrame()
        frame.pitchClass = progression[step % progression.count]
        frame.tier = (step / progression.count) % 3
        frame.drive = 0.85 + 0.15 * sinf(time * 0.7)
        frame.silent = false
        frame.noteHz = 261.63 * powf(2, Float(frame.pitchClass) / 12)
        frame.minorness = [9, 2, 4, 11].contains(frame.pitchClass) ? 1 : 0
        frame.dbfs = -14
        frame.level = 0.7
        frame.beat = Int(time * 2) != Int((time - dt) * 2)
        frame.onset = frame.beat ? 1 : 0
        return frame
    }
}

@inline(__always) func ema(_ current: Float, _ target: Float, tau: Float, dt: Float) -> Float {
    current + (target - current) * (1 - expf(-dt / tau))
}

@inline(__always) func clamp(_ value: Float, _ low: Float = 0, _ high: Float = 1) -> Float {
    min(max(value, low), high)
}

@inline(__always) func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = clamp((x - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
}
