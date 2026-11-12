import Foundation

/// Offline (non-real-time) synthesis of keystroke sounds. Runs once per profile.
enum Synth {
    static let sampleRate: Float = 48_000
    static let maxDuration: Float = 0.6

    /// How a key's size changes its sound: bigger keycaps ring lower and longer,
    /// and their stabilisers add a little rattle just after the main impact.
    private struct Shape {
        var freqScale: Float
        var decayScale: Float
        var gain: Float
        var rattles: [Float] // ms after the final impact
    }

    private static func shape(for size: KeySize) -> Shape {
        switch size {
        case .standard: return Shape(freqScale: 1.0, decayScale: 1.0, gain: 1.0, rattles: [])
        case .wide: return Shape(freqScale: 0.86, decayScale: 1.15, gain: 1.1, rattles: [2.2])
        case .space: return Shape(freqScale: 0.72, decayScale: 1.4, gain: 1.25, rattles: [2.0, 4.8])
        }
    }

    static func render(_ impacts: [Impact], size: KeySize, brightness: Float, seed: UInt64) -> [Float] {
        var rng = SynthRNG(seed: seed)
        let shape = shape(for: size)

        var all = impacts
        if let last = impacts.max(by: { $0.at < $1.at }) {
            for (i, offset) in shape.rattles.enumerated() {
                let g: Float = i == 0 ? 1 : 0.7
                all.append(Impact(
                    at: last.at + offset,
                    bursts: [Burst(freq: 3600, q: 4, decay: 0.7, amp: 0.14 * g),
                             Burst(freq: 1500, q: 1.2, decay: 1.2, amp: 0.18 * g)],
                    modes: [Mode(freq: 1900, decay: 5, amp: 0.08 * g)]))
            }
        }

        var duration: Float = 0
        for impact in all {
            let longest = max(impact.modes.map(\.decay).max() ?? 0, impact.bursts.map(\.decay).max() ?? 0)
            duration = max(duration, (impact.at + longest * shape.decayScale * 7) / 1000)
        }
        duration = min(duration + 0.01, maxDuration)

        var out = [Float](repeating: 0, count: Int(duration * sampleRate))
        for impact in all {
            let start = Int(impact.at * rng.jitter(0.12) / 1000 * sampleRate)
            for b in impact.bursts {
                addBurst(&out, at: start,
                         freq: b.freq * (0.6 + 0.4 * shape.freqScale) * rng.jitter(0.06),
                         q: b.q,
                         decay: b.decay / 1000 * shape.decayScale * rng.jitter(0.15),
                         amp: b.amp * rng.jitter(0.15),
                         rng: &rng)
            }
            for m in impact.modes {
                addMode(&out, at: start,
                        freq: m.freq * shape.freqScale * rng.jitter(0.035),
                        decay: m.decay / 1000 * shape.decayScale * rng.jitter(0.1),
                        amp: m.amp * rng.jitter(0.15))
            }
        }

        highpass(&out, cutoff: 35)
        var lp = Biquad.lowpass(freq: brightness, q: 0.707)
        for i in out.indices { out[i] = lp.process(out[i]) * shape.gain }
        return trimmed(out)
    }

    // MARK: - Components

    private static func addBurst(_ out: inout [Float], at start: Int, freq: Float, q: Float,
                                 decay: Float, amp: Float, rng: inout SynthRNG) {
        let attack: Float = 0.00015
        let ring = q / (Float.pi * freq)
        let count = Int((attack + decay * 7 + ring * 7) * sampleRate)
        guard count > 0 else { return }

        var buf = [Float](repeating: 0, count: count)
        let attackSamples = max(1, Int(attack * sampleRate))
        let k = expf(-1 / (decay * sampleRate))
        var env: Float = 1
        for i in 0..<count {
            let e: Float
            if i < attackSamples {
                e = Float(i) / Float(attackSamples)
            } else {
                e = env
                env *= k
            }
            buf[i] = rng.signed() * e
        }

        var bp = Biquad.bandpass(freq: freq, q: q)
        var peak: Float = 0
        for i in 0..<count {
            buf[i] = bp.process(buf[i])
            peak = max(peak, abs(buf[i]))
        }
        guard peak > 0 else { return }
        let scale = amp / peak
        for i in 0..<count where start + i < out.count {
            out[start + i] += buf[i] * scale
        }
    }

    private static func addMode(_ out: inout [Float], at start: Int, freq: Float, decay: Float, amp: Float) {
        let count = min(Int(decay * 7 * sampleRate), out.count - start)
        guard count > 0 else { return }
        let w = 2 * Float.pi * min(freq, sampleRate * 0.45) / sampleRate
        let k = expf(-1 / (decay * sampleRate))
        // Recursive oscillator: cheaper and more accurate than calling sin() per sample.
        let c = 2 * cosf(w)
        var y1: Float = 0, y2 = -sinf(w)
        var env = amp
        for i in 0..<count {
            let y = c * y1 - y2
            y2 = y1
            y1 = y
            out[start + i] += y2 * env
            env *= k
        }
    }

    private static func highpass(_ x: inout [Float], cutoff: Float) {
        let a = expf(-2 * Float.pi * cutoff / sampleRate)
        var prevX: Float = 0, prevY: Float = 0
        for i in x.indices {
            let y = a * (prevY + x[i] - prevX)
            prevX = x[i]
            prevY = y
            x[i] = y
        }
    }

    /// Cuts the silent tail and fades the end so playback never clicks.
    private static func trimmed(_ x: [Float]) -> [Float] {
        let peak = x.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return [0] }
        let floor = peak * 0.0005
        var end = x.count
        while end > 1, abs(x[end - 1]) < floor { end -= 1 }
        var out = Array(x[0..<end])
        let fade = min(out.count, Int(0.004 * sampleRate))
        for i in 0..<fade {
            out[out.count - 1 - i] *= Float(i) / Float(fade)
        }
        return out
    }
}

struct Biquad {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    var z1: Float = 0, z2: Float = 0

    static func bandpass(freq: Float, q: Float, sampleRate: Float = Synth.sampleRate) -> Biquad {
        let w0 = 2 * Float.pi * min(freq, sampleRate * 0.45) / sampleRate
        let alpha = sinf(w0) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: -2 * cosf(w0) / a0, a2: (1 - alpha) / a0)
    }

    static func lowpass(freq: Float, q: Float, sampleRate: Float = Synth.sampleRate) -> Biquad {
        let w0 = 2 * Float.pi * min(freq, sampleRate * 0.45) / sampleRate
        let alpha = sinf(w0) / (2 * q)
        let cw = cosf(w0)
        let a0 = 1 + alpha
        return Biquad(b0: (1 - cw) / 2 / a0, b1: (1 - cw) / a0, b2: (1 - cw) / 2 / a0,
                      a1: -2 * cw / a0, a2: (1 - alpha) / a0)
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Small deterministic PRNG (SplitMix64) so every variant is reproducible.
struct SynthRNG {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    /// Uniform in [-1, 1).
    mutating func signed() -> Float { unit() * 2 - 1 }
    /// 1 ± amount.
    mutating func jitter(_ amount: Float) -> Float { 1 + signed() * amount }
}
