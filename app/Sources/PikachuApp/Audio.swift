import os
import AVFoundation
import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT
import MLXAudioTTS
import PikachuCore

/// One engine for the mic and Jarvis's voice, with Apple's voice processing on. Echo cancellation needs both on the
/// same engine: then the mic does not hear Jarvis, so you can interrupt by talking. The engine stops when neither is in use.
/// Events only (mic on or off, which mode): never audio or words. For checking behaviour with `log show`.
let voiceLog = Logger(subsystem: "dev.agentpikachu.app", category: "voice")

final class AudioIO: @unchecked Sendable {
    static let shared = AudioIO()
    private(set) var engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var micOn = false
    private var playing = 0
    private var playerFormat: AVAudioFormat?
    private var voiceProcessing = false

    private init() {
        engine.attach(player) // the mic is not touched until first use, so launching never asks for it
        // Wire the voice to the speakers now: a mixer first made while the mic keeps the engine running is never
        // connected to the output, and playing into it crashes ("player started when in a disconnected state").
        engine.connect(player, to: engine.mainMixerNode, format: nil)
    }

    private func run() throws { if !engine.isRunning { engine.prepare(); try engine.start() } }
    private func stopIfIdle() { if !micOn && playing == 0 && engine.isRunning { engine.stop() } }

    /// Echo cancellation (Apple's voice processing) only when Jarvis may talk while you talk (hands-free). macOS turns
    /// other apps' sound down while it is on, so listening for "Hey Jarvis" and note taking (calls!) use the plain mic.
    func startMic(echoCancel: Bool, tap: @escaping AVAudioNodeTapBlock) throws -> AVAudioFormat {
        try lock.withLock {
            if voiceProcessing != echoCancel {
                // Can only be switched while stopped; it also changes the output, so the voice reconnects.
                if engine.isRunning { engine.stop() }
                do { try engine.inputNode.setVoiceProcessingEnabled(echoCancel) } catch { stopIfIdle(); throw error }
                if echoCancel {
                    // Even then, turn other sound down as little as macOS allows.
                    engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
                }
                voiceProcessing = echoCancel; playerFormat = nil
            }
            var format = engine.inputNode.outputFormat(forBus: 0)
            let hardware = engine.inputNode.inputFormat(forBus: 0)
            if !echoCancel, format.sampleRate != hardware.sampleRate || format.channelCount != hardware.channelCount {
                // After echo cancellation is switched off (or the mic changes) the input can keep reporting its old
                // format, and a tap then raises an exception Swift cannot catch: "Hey Jarvis" never came back after a
                // conversation (29 Oct 2026). A fresh engine starts clean, as relaunching does; mid-speech, fail softly.
                guard playing == 0 else { throw CompanionError.dropped }
                replaceEngine()
                format = engine.inputNode.outputFormat(forBus: 0)
                voiceLog.notice("audio engine rebuilt: the mic format had changed")
            }
            engine.inputNode.removeTap(onBus: 0)
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: tap)
            micOn = true
            do { try run() } catch {
                // Never leave a tap or "mic on" behind a start that failed.
                engine.inputNode.removeTap(onBus: 0); micOn = false; stopIfIdle()
                throw error
            }
            voiceLog.notice("mic on, echo cancellation \(echoCancel ? "on" : "off", privacy: .public)")
            return format
        }
    }

    func stopMic() {
        lock.withLock { engine.inputNode.removeTap(onBus: 0); micOn = false; stopIfIdle() }
        voiceLog.notice("mic off")
    }

    func beginPlayback(_ format: AVAudioFormat) throws {
        try lock.withLock {
            if playerFormat != format { engine.connect(player, to: engine.mainMixerNode, format: format); playerFormat = format }
            playing += 1
            try run()
            // Playing into a disconnected graph throws an exception Swift cannot catch: stay silent instead of crashing.
            guard !engine.outputConnectionPoints(for: engine.mainMixerNode, outputBus: 0).isEmpty else {
                playing -= 1; stopIfIdle(); throw CompanionError.dropped
            }
        }
    }

    func endPlayback() { lock.withLock { playing = max(0, playing - 1); stopIfIdle() } }

    /// A fresh engine, as relaunching Jarvis gives: after another app has used the mic, the old one can keep delivering
    /// sound the speech model cannot read. Only while nothing is playing and the mic is off.
    func rebuild() {
        lock.withLock {
            guard !micOn, playing == 0 else { return }
            replaceEngine()
        }
        voiceLog.notice("audio engine rebuilt")
    }

    /// Only with the lock held and nothing playing.
    private func replaceEngine() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.detach(player)
        engine = AVAudioEngine()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        voiceProcessing = false; playerFormat = nil
    }
}

/// Mic capture into memory, converted to 16 kHz mono. Nothing is written to disk.
/// Push-to-talk collects samples until stop(); hands-free gets each chunk as it arrives via `onChunk`.
final class MicRecorder: Recorder, @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var onChunk: (([Float]) -> Void)?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PushToTalk.sampleRate, channels: 1, interleaved: false)!

    func start() throws { try start(onChunk: nil) }

    func start(echoCancel: Bool = false, onChunk: (([Float]) -> Void)?) throws {
        lock.withLock { samples.removeAll(keepingCapacity: true); self.onChunk = onChunk }
        var converter: AVAudioConverter?
        var mono: AVAudioFormat?
        let format = try AudioIO.shared.startMic(echoCancel: echoCancel) { [weak self] buffer, _ in
            guard let self, let converter, let mono, let first = buffer.floatChannelData?[0],
                  let single = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength) else { return }
            // The first channel: with voice processing it is the cleaned-up voice (mixing them all gives silence).
            single.frameLength = buffer.frameLength
            single.floatChannelData![0].update(from: first, count: Int(buffer.frameLength))
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * self.target.sampleRate / mono.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return single
            }
            guard let data = out.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            let handler = self.lock.withLock { self.onChunk }
            if let handler { handler(chunk) } else { self.lock.withLock { self.samples.append(contentsOf: chunk) } }
        }
        mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)
        converter = mono.flatMap { AVAudioConverter(from: $0, to: target) }
        if converter == nil { AudioIO.shared.stopMic(); throw CompanionError.dropped }
    }

    func stop() -> [Float] {
        AudioIO.shared.stopMic()
        return lock.withLock { let s = samples; samples.removeAll(); onChunk = nil; return s }
    }
}

/// Qwen3-ASR 0.6B (8-bit) running locally on the GPU. Loaded once, on first use.
actor QwenTranscriber: Transcriber {
    private var model: Qwen3ASRModel?
    private var context = ""
    private var vocabulary: [String] = []

    func setVocabulary(_ words: [String]) { vocabulary = words; context = SpeechScript.context(vocabulary: words) }

    func load() async throws -> Qwen3ASRModel {
        if let model { return model }
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("models/qwen3-asr") else { throw CompanionError.dropped }
        // The library writes tokenizer.json next to the weights, and the bundle is read-only, so work on a copy.
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("qwen3-asr")
        if !FileManager.default.fileExists(atPath: work.path) { try FileManager.default.copyItem(at: bundled, to: work) }
        let loaded = try await Qwen3ASRModel.fromModelDirectory(work)
        model = loaded
        return loaded
    }

    func transcribe(_ samples: [Float], sampleRate: Double) async throws -> String {
        let model = try await load()
        let audio = MLXArray(samples)
        let first = model.generate(audio: audio, context: context)
        // English or Hindi only. Any other language (Marathi for English said with an Indian accent) is a wrong guess,
        // so it is transcribed again as English.
        let keep = SpeechScript.accepts(language: first.language, text: first.text)
        if !keep { voiceLog.notice("speech taken for \(first.language ?? "another language", privacy: .public): transcribed again as English") }
        let text = keep ? first.text : model.generate(audio: audio, context: context, language: "English").text
        // On noise the model can read back its list of expected words: that was never said.
        // Why a short clip came back empty, for tuning (events only, never the words).
        if SpeechScript.isContextEcho(text, vocabulary: vocabulary) { voiceLog.notice("transcript dropped: the model read back its word list"); return "" }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { voiceLog.notice("transcript empty: the model heard no words") }
        return text
    }
}

/// Whether another app (a call, a recording) is using a microphone right now. False when macOS cannot say.
enum MicUse {
    static func othersUsing() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var list = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &list, 0, nil, &size, &ids) == noErr else { return false }
        let me = getpid()
        return ids.contains { id in
            guard let pid: pid_t = read(id, kAudioProcessPropertyPID), pid != me else { return false }
            return (read(id, kAudioProcessPropertyIsRunningInput) as UInt32?) == 1
        }
    }

    private static func read<T: FixedWidthInteger>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}

/// Kokoro 82M, local. Sentences with Devanagari use a Hindi voice; everything else the English voice chosen in Settings.
final class KokoroVoice: Voice, @unchecked Sendable {
    static let defaultVoice = "am_michael"
    static let hindiVoice = "hm_omega"
    static let defaultSpeed = 1.25
    /// English voices offered in Settings: Kokoro's American and British male and female voices.
    static let choices = ["am_michael", "am_fenrir", "am_puck", "bm_george", "bm_fable", "bm_lewis", "bm_daniel", "af_heart", "af_bella", "bf_emma"]

    private var model: KokoroModel?
    private let io = AudioIO.shared

    private func load() async throws -> KokoroModel {
        if let model { return model }
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("models/kokoro") else { throw CompanionError.dropped }
        let processor = KokoroMultilingualProcessor()
        try await processor.prepare(for: "en-us")
        try await processor.prepare(for: "hi")
        let loaded = try await KokoroModel.fromModelDirectory(dir, textProcessor: processor)
        model = loaded
        return loaded
    }

    func warmUp() async { _ = try? await load() }

    func render(_ text: String) async -> AudioClip? {
        // Kokoro's Hindi is hard to follow: Hindi script is read by the Mac's own Hindi voice, still on the Mac.
        if text.unicodeScalars.contains(where: { (0x0900...0x097F).contains($0.value) }), let clip = await AppleVoice.render(text, language: "hi-IN") { return clip }
        let text = SpokenNumbers.expand(text) // the voice mangles digits ("22", "23:16"): say them as words
        let defaults = UserDefaults.standard
        // A Mac voice picked in Settings (Enhanced or Premium, downloaded in macOS settings).
        if let id = defaults.string(forKey: "voice"), id.hasPrefix(AppleVoice.prefix),
           let clip = await AppleVoice.render(text, identifier: String(id.dropFirst(AppleVoice.prefix.count)), speed: defaults.object(forKey: "voiceSpeed") as? Double ?? Self.defaultSpeed) { return clip }
        guard let model = try? await load() else { return nil }
        let english = defaults.string(forKey: "voice").flatMap { Self.choices.contains($0) ? $0 : nil } ?? Self.defaultVoice
        let speed = defaults.object(forKey: "voiceSpeed") as? Double ?? Self.defaultSpeed
        model.speed = Float(min(1.6, max(0.8, speed)))
        let hindi = text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
        guard let audio = try? await model.generate(text: text, voice: hindi ? Self.hindiVoice : english, refAudio: nil, refText: nil, language: nil, generationParameters: model.defaultGenerationParameters) else { return nil }
        let samples = audio.asArray(Float.self)
        return samples.isEmpty ? nil : AudioClip(samples: samples, sampleRate: Double(model.sampleRate))
    }

    func play(_ clip: AudioClip, _ text: String) async {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: clip.sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(clip.samples.count)
        clip.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: clip.samples.count) }
        guard (try? io.beginPlayback(format)) != nil else { return }
        defer { io.endPlayback() }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            io.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in done.resume() }
            io.player.play()
        }
    }

    func stop() { io.player.stop() }
}

/// The Mac's built-in voice for a language (the best quality installed), rendered to samples instead of played,
/// so it goes through the same player and can be interrupted the same way.
enum AppleVoice {
    @MainActor private static var busy: [AVSpeechSynthesizer] = [] // kept alive until each render finishes

    /// How a Mac voice is stored in the "voice" setting, before its identifier.
    static let prefix = "apple:"

    /// English Mac voices good enough to talk with (Enhanced or Premium), as (setting value, name).
    static func choices() -> [(id: String, name: String)] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") && $0.quality != .default }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
            .map { (prefix + $0.identifier, "\($0.name) (\($0.language), Mac \($0.quality == .premium ? "Premium" : "Enhanced"))") }
    }

    @MainActor static func render(_ text: String, language: String) async -> AudioClip? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        guard let voice = voices.max(by: { $0.quality.rawValue < $1.quality.rawValue }) else { return nil }
        return await render(text, voice: voice, rate: AVSpeechUtteranceDefaultSpeechRate)
    }

    /// A chosen Mac voice. `speed` is the Settings slider (1.0 normal), mapped onto the Mac's speech rate.
    @MainActor static func render(_ text: String, identifier: String, speed: Double) async -> AudioClip? {
        guard let voice = AVSpeechSynthesisVoice(identifier: identifier) else { return nil }
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(min(1.4, max(0.8, speed)))
        return await render(text, voice: voice, rate: min(rate, AVSpeechUtteranceMaximumSpeechRate))
    }

    @MainActor private static func render(_ text: String, voice: AVSpeechSynthesisVoice, rate: Float) async -> AudioClip? {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        let synth = AVSpeechSynthesizer()
        busy.append(synth)
        defer { busy.removeAll { $0 === synth } }
        var samples: [Float] = []
        var rate = 0.0
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            synth.write(utterance) { buffer in
                guard !finished else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { finished = true; done.resume(); return }
                rate = pcm.format.sampleRate
                let n = Int(pcm.frameLength)
                if let f = pcm.floatChannelData?[0] { samples += UnsafeBufferPointer(start: f, count: n) }
                else if let i = pcm.int16ChannelData?[0] { samples += UnsafeBufferPointer(start: i, count: n).map { Float($0) / 32768 } }
            }
        }
        return samples.isEmpty || rate == 0 ? nil : AudioClip(samples: samples, sampleRate: rate)
    }
}
