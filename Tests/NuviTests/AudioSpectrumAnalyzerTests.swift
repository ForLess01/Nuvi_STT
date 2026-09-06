import XCTest
import AVFoundation
@testable import Nuvi

final class AudioSpectrumAnalyzerTests: XCTestCase {
    private let analyzer = AudioSpectrumAnalyzer()
    private let sampleRate: Float = 44100.0
    private let frameCount = 512

    private func makeSineWave(frequency: Float, sampleRate: Float = 44100.0, count: Int = 512) -> [Float] {
        (0..<count).map { i in
            sin(Float(i) * 2.0 * .pi * frequency / sampleRate)
        }
    }

    func testSilenceProducesZero() {
        let silence = [Float](repeating: 0, count: frameCount)
        let spectrum = analyzer.analyze(samples: silence, sampleRate: sampleRate)

        XCTAssertEqual(spectrum, .zero)
        XCTAssertEqual(spectrum.level, 0)
        XCTAssertEqual(spectrum.bass, 0)
        XCTAssertEqual(spectrum.mid, 0)
        XCTAssertEqual(spectrum.treble, 0)
    }

    func testEmptySamplesProduceZero() {
        let spectrum = analyzer.analyze(samples: [], sampleRate: sampleRate)
        XCTAssertEqual(spectrum, .zero)
    }

    func test100HzSineWaveDominatesBass() {
        let samples = makeSineWave(frequency: 100.0, sampleRate: sampleRate, count: frameCount)
        let spectrum = analyzer.analyze(samples: samples, sampleRate: sampleRate)

        XCTAssertGreaterThan(spectrum.level, 0.5, "Level should reflect active audio signal")
        XCTAssertGreaterThan(spectrum.bass, 0.5, "100 Hz tone should strongly excite bass band")
        XCTAssertGreaterThan(spectrum.bass, spectrum.mid, "Bass should be significantly higher than mid for 100 Hz tone")
        XCTAssertGreaterThan(spectrum.bass, spectrum.treble, "Bass should be significantly higher than treble for 100 Hz tone")
        XCTAssertLessThan(spectrum.treble, 0.1, "Treble energy should be near zero for 100 Hz tone")
    }

    func test1000HzSineWaveDominatesMid() {
        let samples = makeSineWave(frequency: 1000.0, sampleRate: sampleRate, count: frameCount)
        let spectrum = analyzer.analyze(samples: samples, sampleRate: sampleRate)

        XCTAssertGreaterThan(spectrum.level, 0.5, "Level should reflect active audio signal")
        XCTAssertGreaterThan(spectrum.mid, 0.5, "1000 Hz tone should strongly excite mid band")
        XCTAssertGreaterThan(spectrum.mid, spectrum.bass, "Mid should be significantly higher than bass for 1000 Hz tone")
        XCTAssertGreaterThan(spectrum.mid, spectrum.treble, "Mid should be significantly higher than treble for 1000 Hz tone")
        XCTAssertLessThan(spectrum.bass, 0.1, "Bass energy should be near zero for 1000 Hz tone")
        XCTAssertLessThan(spectrum.treble, 0.1, "Treble energy should be near zero for 1000 Hz tone")
    }

    func test5000HzSineWaveDominatesTreble() {
        let samples = makeSineWave(frequency: 5000.0, sampleRate: sampleRate, count: frameCount)
        let spectrum = analyzer.analyze(samples: samples, sampleRate: sampleRate)

        XCTAssertGreaterThan(spectrum.level, 0.5, "Level should reflect active audio signal")
        XCTAssertGreaterThan(spectrum.treble, 0.5, "5000 Hz tone should strongly excite treble band")
        XCTAssertGreaterThan(spectrum.treble, spectrum.bass, "Treble should be significantly higher than bass for 5000 Hz tone")
        XCTAssertGreaterThan(spectrum.treble, spectrum.mid, "Treble should be significantly higher than mid for 5000 Hz tone")
        XCTAssertLessThan(spectrum.bass, 0.1, "Bass energy should be near zero for 5000 Hz tone")
        XCTAssertLessThan(spectrum.mid, 0.1, "Mid energy should be near zero for 5000 Hz tone")
    }

    func testAVAudioPCMBufferAnalysis() {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            XCTFail("Failed to allocate test AVAudioPCMBuffer")
            return
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let channelData = buffer.floatChannelData![0]
        let sine = makeSineWave(frequency: 1000.0, sampleRate: sampleRate, count: frameCount)
        for i in 0..<frameCount {
            channelData[i] = sine[i]
        }

        let spectrum = analyzer.analyze(buffer: buffer)
        XCTAssertGreaterThan(spectrum.mid, 0.5)
        XCTAssertGreaterThan(spectrum.mid, spectrum.bass)
        XCTAssertGreaterThan(spectrum.mid, spectrum.treble)
    }

    func testAudioSpectrumEquatabilityAndProperties() {
        let spec1 = AudioSpectrum(level: 0.5, bass: 0.8, mid: 0.3, treble: 0.1)
        let spec2 = AudioSpectrum(level: 0.5, bass: 0.8, mid: 0.3, treble: 0.1)
        let spec3 = AudioSpectrum(level: 0.5, bass: 0.2, mid: 0.3, treble: 0.1)

        XCTAssertEqual(spec1, spec2)
        XCTAssertNotEqual(spec1, spec3)
        XCTAssertEqual(AudioSpectrum.zero, AudioSpectrum(level: 0, bass: 0, mid: 0, treble: 0))
    }
}
