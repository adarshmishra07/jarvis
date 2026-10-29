import AVFoundation

/// Converts mic buffers (any rate, any channel count) to 16 kHz mono Float32, keeping converter state across buffers.
public final class Resampler {
    public static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let converter: AVAudioConverter
    private let ratio: Double

    public init?(from input: AVAudioFormat) {
        guard let c = AVAudioConverter(from: input, to: Self.target) else { return nil }
        converter = c
        ratio = Self.target.sampleRate / input.sampleRate
    }

    public func push(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }
}
