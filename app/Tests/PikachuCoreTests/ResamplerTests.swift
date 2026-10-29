import XCTest
import AVFoundation
@testable import PikachuCore

final class ResamplerTests: XCTestCase {
    /// 1 s of a 440 Hz tone at 48 kHz stereo, fed in 4096-frame buffers like the mic tap, must come out as ~16000 clean mono samples.
    func testDownsamplesInChunksWithoutGlitches() throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let r = try XCTUnwrap(Resampler(from: input))
        var out: [Float] = []
        var t = 0
        while t < 48_000 {
            let n = min(4096, 48_000 - t)
            let buf = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            for c in 0..<2 { for i in 0..<n { buf.floatChannelData![c][i] = 0.5 * Float(sin(2 * .pi * 440 * Double(t + i) / 48_000)) } }
            out += r.push(buf)
            t += n
        }
        XCTAssertEqual(Double(out.count), 16_000, accuracy: 200)
        // A clean 440 Hz tone crosses zero ~880 times per second; glitches or gaps add or remove crossings.
        let body = Array(out.dropFirst(400).dropLast(400))
        let crossings = zip(body, body.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        let expected = 880.0 * Double(body.count) / 16_000
        XCTAssertEqual(Double(crossings), expected, accuracy: expected * 0.02)
        let peak = body.map(abs).max() ?? 0
        XCTAssertEqual(peak, 0.5, accuracy: 0.08)
    }
}
