import AppKit
import AVFoundation
import CoreGraphics
import MLX
import PikachuCore

/// Debug aid: `open -n Pikachu.app --args -snapshot ask|graph|...` writes the window to <container>/snapshot.png after a delay, then quits.
/// Uses the app's own window, so it needs no screen-recording permission.
enum Snapshot {
    @MainActor
    static func scheduleIfRequested(model: AppModel) {
        if UserDefaults.standard.string(forKey: "micProbe") != nil { return micProbe() }
        // -wakeProbe "a.m4a|b.m4a": transcribes files in the app's folder and writes what was heard and what the wake word
        // made of it to <container>/wakeprobe.txt, then quits.
        if let probe = UserDefaults.standard.string(forKey: "wakeProbe") {
            Task { @MainActor in
                var out: [String] = []
                for name in probe.split(separator: "|") {
                    let start = Date()
                    let file = await model.prepareFile?(URL(fileURLWithPath: NSHomeDirectory() + "/" + name))
                    let ms = Int(Date().timeIntervalSince(start) * 1000) // the first one includes loading the model
                    let heard = file.map { String(decoding: $0.data, as: UTF8.self) } ?? "(nothing)"
                    out.append("\(name)\t\(heard)\t\(String(describing: WakeWord.parse(heard)))\t\(ms)")
                }
                try? out.joined(separator: "\n").write(toFile: NSHomeDirectory() + "/wakeprobe.txt", atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }
        // -speakProbe "It is 22 degrees.|...": renders each sentence in Jarvis's voice to <container>/speak-N.wav, then quits.
        // Transcribing those files back (-wakeProbe) shows what the voice actually said.
        if let probe = UserDefaults.standard.string(forKey: "speakProbe") {
            Task { @MainActor in
                let voice = KokoroVoice()
                try? await Task.sleep(for: .seconds(3)) // speech recognition loads at launch: measure the voice on its own
                var stats: [String] = ["before\tactive \(Memory.activeMemory >> 20) MB"]
                for (i, sentence) in probe.split(separator: "|").enumerated() {
                    let started = Date()
                    defer { stats.append("\(i + 1)\t\(Int(Date().timeIntervalSince(started) * 1000)) ms\tactive \(Memory.activeMemory >> 20) MB\tcache \(Memory.cacheMemory >> 20) MB\tpeak \(Memory.peakMemory >> 20) MB") }
                    guard let clip = await voice.render(String(sentence)),
                          let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: clip.sampleRate, channels: 1, interleaved: false),
                          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count)) else { continue }
                    buffer.frameLength = AVAudioFrameCount(clip.samples.count)
                    clip.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: clip.samples.count) }
                    let file = try? AVAudioFile(forWriting: URL(fileURLWithPath: NSHomeDirectory() + "/speak-\(i + 1).wav"), settings: format.settings)
                    try? file?.write(from: buffer)
                }
                try? stats.joined(separator: "\n").write(toFile: NSHomeDirectory() + "/speakprobe.txt", atomically: true, encoding: .utf8) // MLX memory after each sentence
                NSApp.terminate(nil)
            }
            return
        }
        // -turnProbe "a.raw|b.raw": 16 kHz float32 speech files in the app's folder, each run through the hands-free
        // listener with Smart Turn and then quiet. Writes how long after the speech the turn ended to <container>/turnprobe.txt.
        if let probe = UserDefaults.standard.string(forKey: "turnProbe") {
            let turn = Bundle.main.resourceURL.flatMap { try? SmartTurn(modelPath: $0.appendingPathComponent("models/smart-turn.onnx").path) }
            var out = ["model \(turn == nil ? "not loaded" : "loaded")"]
            for name in probe.split(separator: "|") {
                guard let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/" + name) else { out.append("\(name)\tmissing"); continue }
                var vad = VoiceActivity()
                var p: Float = -1, ms = 0
                if let turn { vad.endCheck = { speech in let t = Date(); p = (try? turn.probability(speech)) ?? 0; ms = Int(Date().timeIntervalSince(t) * 1000); return p > 0.5 } }
                var speech = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                while let last = speech.last, abs(last) < 0.001 { speech.removeLast() } // timed from the last sound
                _ = vad.feed(speech)
                var quiet = 0
                while quiet < 100, !vad.feed([Float](repeating: 0, count: 480)).contains(where: { $0 != .started }) { quiet += 1 }
                out.append("\(name)\tended \((quiet + 1) * 30) ms after the speech\tp=\(String(format: "%.2f", p))\tcheck \(ms) ms")
            }
            try? out.joined(separator: "\n").write(toFile: NSHomeDirectory() + "/turnprobe.txt", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
            return
        }
        guard UserDefaults.standard.string(forKey: "snapshot") != nil else { return }
        let asks = (UserDefaults.standard.string(forKey: "snapshotAsk") ?? "").split(separator: "|").map(String.init)
        // -snapshotAttach "a.m4a|b.heic": files in the app's own folder, attached before the first question.
        let files = (UserDefaults.standard.string(forKey: "snapshotAttach") ?? "").split(separator: "|").map { URL(fileURLWithPath: NSHomeDirectory() + "/" + $0) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !files.isEmpty { await model.attach(files) }
            for q in asks { model.question = q; await model.ask() }
        }
        let delay = asks.isEmpty ? 6.0 : 30.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]) else {
                try? "no window image".write(toFile: NSHomeDirectory() + "/snapshot.txt", atomically: true, encoding: .utf8); NSApp.terminate(nil); return
            }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSHomeDirectory() + "/snapshot.png"))
            NSApp.terminate(nil)
        }
    }

    /// Debug aid: `-micProbe 1` runs the hands-free mic for 3 s and writes the chunk count and peak loudness
    /// (never audio) to <container>/micprobe.txt, then quits.
    @MainActor
    /// `-micProbe switch` first listens with echo cancellation, as a conversation does, then switches to the plain mic.
    static func micProbe(switched: Bool = false) {
        if !switched, UserDefaults.standard.string(forKey: "micProbe") == "switch" {
            let talk = MicRecorder()
            do { try talk.start(echoCancel: true) { _ in } } catch {
                try? "echo cancellation start failed: \(error)".write(toFile: NSHomeDirectory() + "/micprobe.txt", atomically: true, encoding: .utf8); NSApp.terminate(nil); return
            }
            // Jarvis talks during a conversation: play 1 s of silence (nothing audible) through the same player.
            let io = AudioIO.shared
            if let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false),
               let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000), (try? io.beginPlayback(format)) != nil {
                silence.frameLength = 24_000
                io.player.scheduleBuffer(silence, completionCallbackType: .dataPlayedBack) { _ in io.endPlayback() }
                io.player.play()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                _ = talk.stop()
                micProbe(switched: true)
            }
            return
        }
        let mic = MicRecorder()
        let box = ProbeBox()
        do { try mic.start { chunk in box.add(chunk) } } catch {
            try? "start failed: \(error)".write(toFile: NSHomeDirectory() + "/micprobe.txt", atomically: true, encoding: .utf8); NSApp.terminate(nil); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            _ = mic.stop()
            let f = AudioIO.shared.engine.inputNode.outputFormat(forBus: 0)
            try? (box.report + " input=\(f.sampleRate)Hz ch=\(f.channelCount) fmt=\(f.commonFormat.rawValue) interleaved=\(f.isInterleaved)").write(toFile: NSHomeDirectory() + "/micprobe.txt", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}

private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks = 0, samples = 0
    private var peak: Float = 0
    func add(_ c: [Float]) {
        let rms = c.isEmpty ? 0 : (c.reduce(0) { $0 + $1 * $1 } / Float(c.count)).squareRoot()
        lock.withLock { chunks += 1; samples += c.count; peak = max(peak, rms) }
    }
    var report: String { lock.withLock { "chunks=\(chunks) seconds=\(Double(samples) / 16_000) peakRMS=\(peak)" } }
}
