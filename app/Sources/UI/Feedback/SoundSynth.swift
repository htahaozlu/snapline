import Foundation

/// Code-synthesized UI sounds (DESIGN §6). Pure functions: no I/O, no playback.
///
///     s(t) = A·env(t)·[sin(2πft) + 10^(−14/20)·sin(4πft)]
///     env(t) = min(t/t_a, 1)·exp(−max(t − t_a, 0)/τ),  last 3 ms linear fade,
///     A normalizes the peak to the target dBFS. 48 kHz mono 16-bit.
enum SoundSynth {
    static let sampleRate = 48_000

    /// One tone: frequency glides exponentially from `f0` to `f1` (equal for a steady tone).
    struct Tone: Equatable {
        var f0: Double
        var f1: Double
        var duration: Double   // s
        var attack: Double     // t_a, s
        var decay: Double      // τ, s
        init(_ f: Double, duration: Double, attack: Double, decay: Double) {
            f0 = f; f1 = f; self.duration = duration; self.attack = attack; self.decay = decay
        }
        init(glide f0: Double, to f1: Double, duration: Double, attack: Double, decay: Double) {
            self.f0 = f0; self.f1 = f1; self.duration = duration; self.attack = attack; self.decay = decay
        }
    }

    /// A sound: tones separated by silent gaps, normalized as a whole.
    struct Spec: Equatable {
        var name: String
        var parts: [Part]
        var peakDBFS: Double
        enum Part: Equatable { case tone(Tone), gap(Double) }

        var duration: Double {
            parts.reduce(0) { acc, p in
                switch p { case .tone(let t): return acc + t.duration; case .gap(let g): return acc + g }
            }
        }
    }

    /// Size class → pitch (§6 table): Maximize 1174.7 · Two-thirds 1318.5 · Half 1568 ·
    /// Third 1760 · Quarter 2093 Hz.
    enum Size: String, CaseIterable {
        case maximize, twoThirds, half, third, quarter
        var frequency: Double {
            switch self {
            case .maximize: return 1174.7
            case .twoThirds: return 1318.5
            case .half: return 1568
            case .third: return 1760
            case .quarter: return 2093
            }
        }
    }

    static func tick(_ size: Size) -> Spec {
        Spec(name: "tick-\(size.rawValue)", parts: [.tone(Tone(size.frequency, duration: 0.040, attack: 0.001, decay: 0.007))], peakDBFS: -20)
    }

    static func tickSoft(_ size: Size) -> Spec {
        Spec(name: "tick-soft-\(size.rawValue)", parts: [.tone(Tone(size.frequency, duration: 0.034, attack: 0.001, decay: 0.006))], peakDBFS: -24)
    }

    static let thud = Spec(name: "thud", parts: [.tone(Tone(glide: 330, to: 247, duration: 0.070, attack: 0.002, decay: 0.020))], peakDBFS: -24)

    static let ready = Spec(name: "ready", parts: [
        .tone(Tone(1318.5, duration: 0.040, attack: 0.002, decay: 0.018)),
        .gap(0.024),
        .tone(Tone(1760, duration: 0.070, attack: 0.002, decay: 0.018)),
    ], peakDBFS: -20)

    /// Code ceiling (§6): nothing louder than −12 dBFS.
    static let ceilingDBFS = -12.0
    static let fade = 0.003
    static let secondHarmonic = pow(10, -14.0 / 20.0)

    /// Float samples before normalization (exactly 0 at the first and last sample of each tone).
    static func raw(_ spec: Spec) -> [Double] {
        let sr = Double(sampleRate)
        var out: [Double] = []
        out.reserveCapacity(Int(spec.duration * sr) + 2)
        for part in spec.parts {
            switch part {
            case .gap(let g):
                out += [Double](repeating: 0, count: Int((g * sr).rounded()))
            case .tone(let t):
                let n = Int((t.duration * sr).rounded())
                let fadeN = max(2, Int((fade * sr).rounded()))
                let ratio = t.f1 / t.f0
                var phase = 0.0
                for i in 0..<n {
                    let time = Double(i) / sr
                    let f = t.f0 == t.f1 ? t.f0 : t.f0 * pow(ratio, time / t.duration)
                    let env = min(time / t.attack, 1) * exp(-max(time - t.attack, 0) / t.decay)
                    var s = env * (sin(phase) + secondHarmonic * sin(2 * phase))
                    // Last 3 ms: linear fade to exactly 0 on the last sample.
                    let fromEnd = n - 1 - i
                    if fromEnd < fadeN { s *= Double(fromEnd) / Double(fadeN - 1) }
                    out.append(s)
                    phase += 2 * Double.pi * f / sr
                }
            }
        }
        return out
    }

    /// 16-bit PCM normalized so the peak sits at `spec.peakDBFS` (clamped to the ceiling).
    static func render(_ spec: Spec) -> [Int16] {
        let x = raw(spec)
        let peak = x.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return x.map { _ in 0 } }
        let target = pow(10, min(spec.peakDBFS, ceilingDBFS) / 20) * 32767
        let gain = target / peak
        return x.map { Int16(clamping: Int(($0 * gain).rounded())) }
    }

    /// Peak level of PCM samples in dBFS (full scale = 32767).
    static func peakDBFS(_ samples: [Int16]) -> Double {
        let p = samples.reduce(0) { max($0, abs(Int($1))) }
        return p == 0 ? -.infinity : 20 * log10(Double(p) / 32767)
    }

    /// RIFF/WAVE container, PCM 16-bit mono.
    static func wav(_ samples: [Int16], sampleRate: Int = SoundSynth.sampleRate) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var le = v.littleEndian; d.append(Data(bytes: &le, count: 4)) }
        func u16(_ v: UInt16) { var le = v.littleEndian; d.append(Data(bytes: &le, count: 2)) }
        let dataBytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        samples.withUnsafeBufferPointer { buf in
            for s in buf { u16(UInt16(bitPattern: s)) }
        }
        return d
    }
}
