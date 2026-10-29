import Accelerate
import Foundation
import OnnxRuntimeBindings

/// Smart Turn v3 (pipecat-ai/smart-turn-v3, BSD-2): listens to how a sentence ends and says whether you have finished
/// talking, so Jarvis can answer after a short pause without cutting you off mid-thought. Runs on the CPU in about 20 ms.
public final class SmartTurn {
    static let sampleRate = 16000
    static let window = 8 * sampleRate // the model hears the last 8 s

    private let session: ORTSession

    public init(modelPath: String) throws {
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(4)
        session = try ORTSession(env: ORTEnv(loggingLevel: .warning), modelPath: modelPath, sessionOptions: options)
    }

    /// How sure the model is that the speech (16 kHz mono) is a finished turn, 0 to 1.
    public func probability(_ audio: [Float]) throws -> Float {
        let features = WhisperFeatures.logMel(Self.lastWindow(audio))
        let input = try ORTValue(tensorData: NSMutableData(bytes: features, length: features.count * 4), elementType: .float,
                                 shape: [1, NSNumber(value: WhisperFeatures.mels), NSNumber(value: WhisperFeatures.frames)])
        let out = try session.run(withInputs: ["input_features": input], outputNames: ["logits"], runOptions: nil)
        guard let data = try out["logits"]?.tensorData() else { return 0 }
        return data.bytes.load(as: Float.self) // already a probability: the model ends in a sigmoid
    }

    /// The last 8 s, with silence added in front when shorter, then scaled to zero mean and unit variance (as in training).
    static func lastWindow(_ audio: [Float]) -> [Float] {
        let tail = audio.suffix(window)
        var x = [Float](repeating: 0, count: window - tail.count) + tail
        var mean: Float = 0, std: Float = 0
        vDSP_normalize(x, 1, nil, 1, &mean, &std, vDSP_Length(x.count))
        let scale = 1 / (std * std + 1e-7).squareRoot()
        x = x.map { ($0 - mean) * scale }
        return x
    }
}

/// Whisper's log-mel features (80 mels, 25 ms windows every 10 ms), matching Hugging Face's WhisperFeatureExtractor.
enum WhisperFeatures {
    static let mels = 80, frames = 800
    static let nFFT = 400, hop = 160, bins = nFFT / 2 + 1

    /// 8 s of 16 kHz audio to 80 x 800 features, row-major by mel.
    static func logMel(_ audio: [Float]) -> [Float] {
        let half = nFFT / 2
        // Centered frames: the audio is mirrored at both ends (numpy's "reflect").
        let padded = Array(audio[1...half].reversed()) + audio + Array(audio[(audio.count - half - 1)..<(audio.count - 1)].reversed())
        let count = 1 + (padded.count - nFFT) / hop // 801; the last is dropped below, as Whisper does
        var framed = [Float](repeating: 0, count: count * nFFT)
        for f in 0..<count { for n in 0..<nFFT { framed[f * nFFT + n] = padded[f * hop + n] * hann[n] } }
        // ponytail: a DFT as two matrix products (400 is not a power of two); about 5 ms here, fine once per pause.
        var re = [Float](repeating: 0, count: count * bins), im = re
        vDSP_mmul(framed, 1, cosTable, 1, &re, 1, vDSP_Length(count), vDSP_Length(bins), vDSP_Length(nFFT))
        vDSP_mmul(framed, 1, sinTable, 1, &im, 1, vDSP_Length(count), vDSP_Length(bins), vDSP_Length(nFFT))
        var power = [Float](repeating: 0, count: count * bins)
        vDSP_vmma(re, 1, re, 1, im, 1, im, 1, &power, 1, vDSP_Length(power.count))
        var mel = [Float](repeating: 0, count: count * mels)
        vDSP_mmul(power, 1, filters, 1, &mel, 1, vDSP_Length(count), vDSP_Length(mels), vDSP_Length(bins))
        var out = [Float](repeating: 0, count: mels * frames)
        for f in 0..<frames { for m in 0..<mels { out[m * frames + f] = log10(max(mel[f * mels + m], 1e-10)) } }
        let floor = (out.max() ?? 0) - 8
        return out.map { (max($0, floor) + 4) / 4 }
    }

    static let hann: [Float] = (0..<nFFT).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nFFT))) }
    static let cosTable: [Float] = table(cos)
    static let sinTable: [Float] = table(sin)
    private static func table(_ f: (Double) -> Double) -> [Float] { // nFFT x bins
        (0..<nFFT).flatMap { n in (0..<bins).map { k in Float(f(2 * Double.pi * Double(k * n) / Double(nFFT))) } }
    }

    /// Slaney-style mel filters, bins x mels, as librosa and Whisper make them.
    static let filters: [Float] = {
        func mel(_ hz: Double) -> Double { hz < 1000 ? 3 * hz / 200 : 15 + log(hz / 1000) * 27 / log(6.4) }
        func hz(_ mel: Double) -> Double { mel < 15 ? 200 * mel / 3 : 1000 * exp((mel - 15) * log(6.4) / 27) }
        let top = mel(8000)
        let edges = (0..<(mels + 2)).map { hz(top * Double($0) / Double(mels + 1)) }
        var out = [Float](repeating: 0, count: bins * mels)
        for b in 0..<bins {
            let f = 8000 * Double(b) / Double(bins - 1)
            for m in 0..<mels {
                let down = (f - edges[m]) / (edges[m + 1] - edges[m]), up = (edges[m + 2] - f) / (edges[m + 2] - edges[m + 1])
                out[b * mels + m] = Float(max(0, min(down, up)) * 2 / (edges[m + 2] - edges[m]))
            }
        }
        return out
    }()
}
