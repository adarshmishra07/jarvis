import Foundation

/// Finds where speech starts and ends in a live 16 kHz mono stream, for hands-free talk.
/// ponytail: a fixed loudness bar; add a learned noise floor if noisy rooms trigger it.
public struct VoiceActivity {
    public enum Event: Equatable { case started, ended([Float]) }

    static let frame = 480        // 30 ms
    static let startFrames = 4    // 120 ms of speech before it counts
    static let endFrames = 23     // about 700 ms of quiet ends a sentence
    static let checkFrames = 7    // with an end check: asked after 210 ms of quiet...
    static let checkedEndFrames = 40 // ...and if it says you are not done, 1.2 s of quiet still ends the turn
    static let leadIn = 10        // 300 ms kept from before the start, so the first word is not clipped
    static let maxFrames = 1000   // 30 s cap per sentence

    /// Loudness (RMS) that counts as speech. Calibration knob.
    public var threshold: Float = 0.015
    /// True while Jarvis talks: leftover echo is quieter than you, so only louder speech counts.
    public var raised = false
    /// Whether the speech so far is a finished turn (Smart Turn). Asked once per pause; without it a fixed pause ends it.
    public var endCheck: (([Float]) -> Bool)?

    private var carry: [Float] = []
    private var recent: [[Float]] = []
    private var speech: [Float] = []
    private var talking = false
    private var loud = 0, quiet = 0, frames = 0

    public init() {}

    public mutating func feed(_ samples: [Float]) -> [Event] {
        carry += samples
        var events: [Event] = []
        while carry.count >= Self.frame {
            let f = Array(carry.prefix(Self.frame))
            carry.removeFirst(Self.frame)
            if let e = step(f) { events.append(e) }
        }
        return events
    }

    /// Stopping mid-sentence: whatever was being said so far, so the last words are not lost.
    public mutating func finish() -> [Float]? {
        defer { talking = false; speech = []; loud = 0; recent = []; carry = [] }
        return talking && !speech.isEmpty ? speech + carry : nil
    }

    private mutating func step(_ f: [Float]) -> Event? {
        let rms = (f.reduce(0) { $0 + $1 * $1 } / Float(f.count)).squareRoot()
        let isSpeech = rms >= threshold * (raised ? 3 : 1)
        if !talking {
            recent.append(f)
            if recent.count > Self.leadIn + Self.startFrames { recent.removeFirst() }
            loud = isSpeech ? loud + 1 : 0
            guard loud >= Self.startFrames else { return nil }
            talking = true; quiet = 0; frames = recent.count
            speech = recent.flatMap { $0 }; recent = []
            return .started
        }
        speech += f; frames += 1
        quiet = isSpeech ? 0 : quiet + 1
        let finished = endCheck.map { check in quiet == Self.checkFrames && check(speech) } ?? false
        let silent = quiet >= (endCheck == nil ? Self.endFrames : Self.checkedEndFrames)
        guard finished || silent || frames >= Self.maxFrames else { return nil }
        let done = speech
        talking = false; speech = []; loud = 0
        return .ended(done)
    }
}
