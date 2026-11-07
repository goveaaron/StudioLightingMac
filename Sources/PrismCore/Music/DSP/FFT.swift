import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Forward real FFT returning one-sided power spectra with **mathematical DFT scaling**
/// (`X[k] = Σ x[n]·e^(−2πikn/N)`), so the vDSP and portable implementations agree exactly
/// up to rounding. Uses vDSP on Apple platforms and a portable radix-2 FFT elsewhere.
///
/// Not thread-safe: one instance per analysis path. All buffers are allocated in `init`.
public final class RealFFT {
    /// Transform size N (a power of two ≥ 8).
    public let size: Int
    let log2Size: Int
    private let half: Int

    // Portable implementation (always built; used on Linux and by the parity test on macOS).
    private let re: UnsafeMutablePointer<Float>
    private let im: UnsafeMutablePointer<Float>
    private let cosT: UnsafeMutablePointer<Float>   // cos(2πt/M), t < M/2
    private let sinT: UnsafeMutablePointer<Float>   // −sin(2πt/M)
    private let postCos: UnsafeMutablePointer<Float> // cos(2πk/N), k ≤ M
    private let postSin: UnsafeMutablePointer<Float> // −sin(2πk/N)
    private let bitrev: UnsafeMutablePointer<Int32>

    #if canImport(Accelerate)
    private let setup: FFTSetup
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    #endif

    /// Returns nil unless `size` is a power of two between 8 and 65 536.
    public init?(size: Int) {
        guard size >= 8, size <= 65_536, size & (size - 1) == 0 else { return nil }
        self.size = size
        var l = 0
        while (1 << l) < size { l += 1 }
        log2Size = l
        half = size / 2
        let m = half

        #if canImport(Accelerate)
        guard let s = vDSP_create_fftsetup(vDSP_Length(l), FFTRadix(kFFTRadix2)) else { return nil }
        setup = s
        realp = .allocate(capacity: m)
        realp.initialize(repeating: 0, count: m)
        imagp = .allocate(capacity: m)
        imagp.initialize(repeating: 0, count: m)
        #endif

        re = .allocate(capacity: m)
        re.initialize(repeating: 0, count: m)
        im = .allocate(capacity: m)
        im.initialize(repeating: 0, count: m)
        let quarter = max(1, m / 2)
        cosT = .allocate(capacity: quarter)
        sinT = .allocate(capacity: quarter)
        for t in 0..<quarter {
            let a = 2 * Double.pi * Double(t) / Double(m)
            cosT[t] = Float(cos(a))
            sinT[t] = Float(-sin(a))
        }
        postCos = .allocate(capacity: m + 1)
        postSin = .allocate(capacity: m + 1)
        for k in 0...m {
            let a = 2 * Double.pi * Double(k) / Double(size)
            postCos[k] = Float(cos(a))
            postSin[k] = Float(-sin(a))
        }
        bitrev = .allocate(capacity: m)
        let bits = l - 1
        for i in 0..<m {
            var x = i, r = 0
            for _ in 0..<bits { r = (r << 1) | (x & 1); x >>= 1 }
            bitrev[i] = Int32(r)
        }
    }

    deinit {
        #if canImport(Accelerate)
        vDSP_destroy_fftsetup(setup)
        realp.deallocate()
        imagp.deallocate()
        #endif
        re.deallocate(); im.deallocate()
        cosT.deallocate(); sinT.deallocate()
        postCos.deallocate(); postSin.deallocate()
        bitrev.deallocate()
    }

    /// Writes `|X[k]|²` for `k = 0 … N/2` (N/2 + 1 values) of the real input `x` (N samples).
    public func powerSpectrum(_ x: UnsafePointer<Float>, into power: UnsafeMutablePointer<Float>) {
        #if canImport(Accelerate)
        accelerated(x, power)
        #else
        portable(x, power)
        #endif
    }

    /// The portable implementation regardless of platform (used by the vDSP parity test).
    public func portablePowerSpectrum(_ x: UnsafePointer<Float>, into power: UnsafeMutablePointer<Float>) {
        portable(x, power)
    }

    #if canImport(Accelerate)
    private func accelerated(_ x: UnsafePointer<Float>, _ power: UnsafeMutablePointer<Float>) {
        let m = half
        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        x.withMemoryRebound(to: DSPComplex.self, capacity: m) { cx in
            vDSP_ctoz(cx, 2, &split, 1, vDSP_Length(m))
        }
        vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2Size), FFTDirection(kFFTDirection_Forward))
        // vDSP's real forward FFT returns 2× the mathematical DFT; DC is packed in realp[0]
        // and Nyquist in imagp[0].
        let dc = realp[0] * 0.5
        let ny = imagp[0] * 0.5
        power[0] = dc * dc
        power[m] = ny * ny
        for k in 1..<m {
            let r = realp[k] * 0.5, i = imagp[k] * 0.5
            power[k] = r * r + i * i
        }
    }
    #endif

    private func portable(_ x: UnsafePointer<Float>, _ power: UnsafeMutablePointer<Float>) {
        let m = half
        // Pack even/odd samples as one complex sequence of length M = N/2.
        for n in 0..<m {
            let j = Int(bitrev[n])
            re[j] = x[2 * n]
            im[j] = x[2 * n + 1]
        }
        // Iterative radix-2 decimation-in-time FFT (input already bit-reversed).
        var len = 2
        while len <= m {
            let h = len / 2
            let step = m / len
            var start = 0
            while start < m {
                var tw = 0
                for k in 0..<h {
                    let a = start + k, b = a + h
                    let wr = cosT[tw], wi = sinT[tw]
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                    tw += step
                }
                start += len
            }
            len <<= 1
        }
        // Split into the spectrum of the real sequence.
        for k in 0...m {
            let ka = k == m ? 0 : k
            let kb = k == 0 ? 0 : m - k
            let ar = re[ka], ai = im[ka]
            let cr = re[kb == m ? 0 : kb], ci = im[kb == m ? 0 : kb]
            let fer = 0.5 * (ar + cr), fei = 0.5 * (ai - ci)
            let forr = 0.5 * (ai + ci), foi = -0.5 * (ar - cr)
            let wr = postCos[k], wi = postSin[k]
            let xr = fer + (wr * forr - wi * foi)
            let xi = fei + (wr * foi + wi * forr)
            power[k] = xr * xr + xi * xi
        }
    }

    /// Periodic Hann window of length `n` (`0.5 − 0.5·cos(2πi/n)`).
    public static func hann(_ n: Int) -> [Float] {
        (0..<max(1, n)).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
    }
}
