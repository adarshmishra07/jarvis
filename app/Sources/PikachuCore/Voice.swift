import Foundation

public protocol Recorder: AnyObject, Sendable {
    func start() throws
    /// Stops and returns 16 kHz mono samples. Audio lives only in memory.
    func stop() -> [Float]
}

public protocol Transcriber: Sendable {
    func transcribe(_ samples: [Float], sampleRate: Double) async throws -> String
}

/// Synthesized speech, ready to play.
public struct AudioClip: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public init(samples: [Float], sampleRate: Double) { self.samples = samples; self.sampleRate = sampleRate }
}

public protocol Voice: AnyObject, Sendable {
    /// Turns text into audio. Can run while another clip plays.
    func render(_ text: String) async -> AudioClip?
    /// Plays a clip and returns when it has been heard (or stopped).
    func play(_ clip: AudioClip, _ text: String) async
    func stop()
}

/// Hold to talk: press starts recording, release transcribes and hands the text on.
/// Short taps, silence and the usual speech-model hallucinations on noise are dropped, so nothing is sent.
@MainActor
public final class PushToTalk {
    public enum State: Equatable { case idle, recording, transcribing }

    public nonisolated static let sampleRate = 16_000.0
    static let minSeconds = 0.4
    static let minRMS: Float = 0.005
    static let noise: Set<String> = ["you", "thank you", "thanks", "thank you for watching", "thanks for watching", "bye", "okay", "ok", "hmm", "uh", "um"]

    public private(set) var state: State = .idle
    public var onState: ((State) -> Void)?
    private let recorder: Recorder
    private let transcriber: Transcriber
    private let onText: (String) async -> Void

    public init(recorder: Recorder, transcriber: Transcriber, onText: @escaping (String) async -> Void) {
        self.recorder = recorder; self.transcriber = transcriber; self.onText = onText
    }

    private func set(_ s: State) { state = s; onState?(s) }

    public func press() {
        guard state == .idle else { return }
        do { try recorder.start(); set(.recording) } catch { set(.idle) }
    }

    public func release() async {
        guard state == .recording else { return }
        var samples = recorder.stop()
        set(.transcribing)
        defer { samples.removeAll(); set(.idle) }
        guard Self.usable(samples) else { return }
        guard let text = try? await transcriber.transcribe(samples, sampleRate: Self.sampleRate), let clean = Self.cleaned(text) else { return }
        await onText(clean)
    }

    nonisolated static let stopWords: Set<String> = ["wait", "stop", "hold", "on", "ruko", "bas", "okay", "ok", "enough", "pause", "shh", "quiet", "goodbye", "bye"]
    /// Its name, as speech-to-text writes it: "Jarvis, stop" needs no greeting first.
    nonisolated static let names: Set<String> = ["jarvis", "jervis", "javis", "jarwis", "jarvice"]
    private nonisolated static let filler: Set<String> = ["okay", "ok", "on"]

    /// Only "wait", "stop", "hold on", "Jarvis, stop", "goodbye Jarvis" and the like: meant to silence Jarvis, not to be asked.
    public nonisolated static func isStopPhrase(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        return !words.isEmpty && words.count <= 4 && words.allSatisfy { stopWords.contains($0) || names.contains($0) }
            && words.contains { stopWords.contains($0) && !filler.contains($0) }
    }

    /// Words a sentence does not end on: "then there is a call at" was a pause to think, not the whole question.
    private nonisolated static let danglingWords: Set<String> = [
        "a", "an", "the", "at", "to", "for", "with", "of", "in", "on", "about", "and", "or", "but", "so", "then", "because",
        "is", "are", "my", "your", "um", "uh", "like", "कि", "और", "के", "की", "का", "में", "को", "से",
    ]

    /// True when the transcript stops on a word no sentence ends with, so more is probably coming.
    public nonisolated static func soundsUnfinished(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespaces).hasSuffix("?") else { return false }
        // Devanagari vowel signs are not letters on their own, so words split on anything but letters and marks.
        let words = text.lowercased().unicodeScalars.split { !($0.properties.isAlphabetic || $0.properties.generalCategory == .nonspacingMark || $0.properties.generalCategory == .spacingMark) }
        guard let last = words.last else { return false }
        return danglingWords.contains(String(String.UnicodeScalarView(last)))
    }

    /// The transcript, or nil when it is too short or one of the usual hallucinations on noise.
    public static func cleaned(_ text: String) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = clean.lowercased().trimmingCharacters(in: .punctuationCharacters).trimmingCharacters(in: .whitespaces)
        return clean.count >= 3 && !noise.contains(key) ? clean : nil
    }

    public static func usable(_ samples: [Float]) -> Bool {
        guard Double(samples.count) / sampleRate >= minSeconds else { return false }
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        return rms >= minRMS
    }
}

/// Speaks sentences one after another as they stream in. The next sentence is rendered while the current one plays,
/// so there is no gap between them. `cancel` stops now and drops the rest (barge-in).
@MainActor
public final class Speaker {
    private let voice: Voice
    private var renderTail: Task<AudioClip?, Never>?
    private var playTail: Task<Void, Never>?
    private var generation = 0
    /// Sentences queued or playing. Above zero means Jarvis is talking.
    public private(set) var pending = 0

    public init(voice: Voice) { self.voice = voice }

    /// `onStart` runs as the sentence starts playing, so the screen shows only what has been said.
    public func enqueue(_ sentence: String, onStart: (() -> Void)? = nil) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let voice = self.voice, gen = generation
        let previousRender = renderTail, previousPlay = playTail
        pending += 1
        // Renders run one at a time, each starting as soon as the one before it is done, not when it has been heard.
        let render = Task { () -> AudioClip? in
            _ = await previousRender?.value
            guard !Task.isCancelled else { return nil }
            return await voice.render(text)
        }
        renderTail = render
        playTail = Task { @MainActor [weak self] in
            await previousPlay?.value
            let clip = await render.value
            defer { if let self, self.generation == gen { self.pending -= 1 } }
            guard let self, self.generation == gen, !Task.isCancelled else { return }
            onStart?() // the text shows even if the voice failed to render
            if let clip { await voice.play(clip, text) }
        }
    }

    public func cancel() {
        generation += 1
        pending = 0
        renderTail?.cancel(); playTail?.cancel()
        renderTail = nil; playTail = nil
        voice.stop()
    }

    public func drain() async { await playTail?.value }
}
