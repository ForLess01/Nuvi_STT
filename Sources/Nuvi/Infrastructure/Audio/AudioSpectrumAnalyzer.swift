import Foundation
import Accelerate
import AVFoundation

/// Real-time audio spectrum analyzer using Apple's Accelerate framework (vDSP).
/// Performs a fast 512-point FFT with Hann windowing and extracts perceptual
/// energy across Bass (20-250 Hz), Mid (250-2500 Hz), and Treble (2500-8000 Hz).
/// Ultra-optimized with preallocated single-allocation buffers and SIMD operations.
public final class AudioSpectrumAnalyzer: @unchecked Sendable {
    public static let defaultFFTSize = 512

    private let fftSize: Int
    private let halfSize: Int
    private let log2n: vDSP_Length

    private let window: UnsafeMutablePointer<Float>
    private let inputScratch: UnsafeMutablePointer<Float>
    private let sampleRing: UnsafeMutablePointer<Float>
    private var sampleRingCount: Int = 0
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>
    private let fftSetup: FFTSetup
    private var split: DSPSplitComplex
    private let lock = NSLock()

    public init(fftSize: Int = defaultFFTSize) {
        self.fftSize = fftSize
        self.halfSize = fftSize / 2
        self.log2n = vDSP_Length(round(log2(Double(fftSize))))

        self.window = .allocate(capacity: fftSize)
        self.inputScratch = .allocate(capacity: fftSize)
        self.sampleRing = .allocate(capacity: fftSize)
        self.sampleRing.initialize(repeating: 0, count: fftSize)
        self.realp = .allocate(capacity: halfSize)
        self.imagp = .allocate(capacity: halfSize)
        self.magnitudes = .allocate(capacity: halfSize)

        vDSP_hann_window(window, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Nuvi: Failed to allocate vDSP FFT setup")
        }
        self.fftSetup = setup
        self.split = DSPSplitComplex(realp: realp, imagp: imagp)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        window.deallocate()
        inputScratch.deallocate()
        sampleRing.deallocate()
        realp.deallocate()
        imagp.deallocate()
        magnitudes.deallocate()
    }

    /// Analyzes an AVAudioPCMBuffer and returns the resulting spectrum.
    public func analyze(buffer: AVAudioPCMBuffer) -> AudioSpectrum {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0 else {
            return .zero
        }
        let frames = Int(buffer.frameLength)
        let sampleRate = Float(buffer.format.sampleRate)
        return analyze(samples: channels[0], count: frames, sampleRate: sampleRate)
    }

    /// Analyzes a Swift array of Float samples.
    public func analyze(samples: [Float], sampleRate: Float = 44100.0) -> AudioSpectrum {
        samples.withUnsafeBufferPointer { bufferPtr in
            guard let baseAddress = bufferPtr.baseAddress else { return .zero }
            return analyze(samples: baseAddress, count: bufferPtr.count, sampleRate: sampleRate)
        }
    }

    /// Analyzes raw pointer samples with SIMD vectorization and continuous sliding STFT.
    public func analyze(samples: UnsafePointer<Float>, count: Int, sampleRate: Float) -> AudioSpectrum {
        guard count > 0, sampleRate > 0 else { return .zero }

        lock.lock()
        defer { lock.unlock() }

        // 1. Overall RMS level via SIMD
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        guard rms > 0.00001 else {
            vDSP_vclr(sampleRing, 1, vDSP_Length(fftSize))
            sampleRingCount = 0
            return .zero
        }
        let level = min(1.0, max(0.0, rms * 12.0))

        // 2. Sliding STFT window: accumulate continuous waveform history
        if count >= fftSize {
            let offset = count - fftSize
            sampleRing.update(from: samples + offset, count: fftSize)
            sampleRingCount = fftSize
        } else {
            let preserve = fftSize - count
            memmove(sampleRing, sampleRing + count, preserve * MemoryLayout<Float>.stride)
            (sampleRing + preserve).update(from: samples, count: count)
            sampleRingCount = min(fftSize, sampleRingCount + count)
        }

        // 3. Apply Hann window over the continuous 512-sample history
        vDSP_vmul(sampleRing, 1, window, 1, inputScratch, 1, vDSP_Length(fftSize))

        // 4. Convert to split complex and execute in-place real-to-complex FFT
        inputScratch.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPtr in
            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfSize))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

        // 5. Compute magnitude spectrum
        vDSP_zvabs(&split, 1, magnitudes, 1, vDSP_Length(halfSize))

        // 5. Frequency band extraction tuned for human speech acoustics
        // Bass: 40 - 280 Hz (male/female fundamental pitch resonance)
        // Mid: 280 - 2800 Hz (vowel formants F1 and F2, core speech power)
        // Treble: 2800 - 8000 Hz (sibilants, fricatives, consonants)
        let df = sampleRate / Float(fftSize)
        let kb1 = max(1, Int(round(40.0 / df)))
        let kb2 = max(kb1, Int(round(280.0 / df)) - 1)
        let km1 = kb2 + 1
        let km2 = max(km1, Int(round(2800.0 / df)) - 1)
        let kt1 = km2 + 1
        let kt2 = min(halfSize - 1, max(kt1, Int(round(8000.0 / df))))

        var bassPeak: Float = 0
        var midPeak: Float = 0
        var treblePeak: Float = 0

        vDSP_maxv(magnitudes + kb1, 1, &bassPeak, vDSP_Length(kb2 - kb1 + 1))
        vDSP_maxv(magnitudes + km1, 1, &midPeak, vDSP_Length(km2 - km1 + 1))
        vDSP_maxv(magnitudes + kt1, 1, &treblePeak, vDSP_Length(kt2 - kt1 + 1))

        var bassRms: Float = 0
        var midRms: Float = 0
        var trebleRms: Float = 0

        vDSP_rmsqv(magnitudes + kb1, 1, &bassRms, vDSP_Length(kb2 - kb1 + 1))
        vDSP_rmsqv(magnitudes + km1, 1, &midRms, vDSP_Length(km2 - km1 + 1))
        vDSP_rmsqv(magnitudes + kt1, 1, &trebleRms, vDSP_Length(kt2 - kt1 + 1))

        // 6. Normalization, peak/RMS blend, and noise floor rejection
        // Full-scale sine magnitude in vDSP_fft_zrip is N/2 = 256.0.
        let normFactor = Float(halfSize)
        let bassRaw = (bassPeak * 0.75 + bassRms * 0.25) / normFactor
        let midRaw = (midPeak * 0.75 + midRms * 0.25) / normFactor
        let trebleRaw = (treblePeak * 0.75 + trebleRms * 0.25) / normFactor

        func cleanBand(_ val: Float) -> Float {
            let threshold: Float = 0.006
            guard val > threshold else { return 0.0 }
            let gated = (val - threshold) / (1.0 - threshold)
            return min(1.0, max(0.0, sqrt(gated * 1.5)))
        }

        let bass = cleanBand(bassRaw)
        let mid = cleanBand(midRaw)
        let treble = cleanBand(trebleRaw)

        return AudioSpectrum(level: level, bass: bass, mid: mid, treble: treble)
    }
}
