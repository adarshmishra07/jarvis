import AppKit
import AVFoundation
import CoreGraphics
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
                for (i, sentence) in probe.split(separator: "|").enumerated() {
                    guard let clip = await voice.render(String(sentence)),
                          let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: clip.sampleRate, channels: 1, interleaved: false),
                          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count)) else { continue }
                    buffer.frameLength = AVAudioFrameCount(clip.samples.count)
                    clip.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: clip.samples.count) }
                    let file = try? AVAudioFile(forWriting: URL(fileURLWithPath: NSHomeDirectory() + "/speak-\(i + 1).wav"), settings: format.settings)
                    try? file?.write(from: buffer)
                }
                NSApp.terminate(nil)
            }
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
    static func micProbe() {
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
