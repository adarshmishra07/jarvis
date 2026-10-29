import Foundation

/// Without headphones the mic also hears the call from the speakers. A mic line said while the Mac's sound was
/// talking for most of that time is the call, already written down as "Them", so it is dropped.
/// ponytail: a loudness overlap, not real echo cancellation; you talking over the call can be dropped too.
public struct EchoFilter {
    private static let frame = 480            // 30 ms at 16 kHz
    private static let loudness: Float = 0.01 // RMS that counts as the call talking
    private static let keep: TimeInterval = 60
    public static let echoShare = 0.5

    /// When each loud 30 ms frame of the Mac's sound ended.
    private var loud: [Date] = []

    public init() {}

    /// The Mac's sound (16 kHz mono), the last sample heard at `end`.
    public mutating func system(_ samples: [Float], endingAt end: Date) {
        let frames = samples.count / Self.frame
        for f in 0..<frames {
            let slice = samples[(f * Self.frame)..<((f + 1) * Self.frame)]
            let rms = (slice.reduce(0) { $0 + $1 * $1 } / Float(Self.frame)).squareRoot()
            guard rms >= Self.loudness else { continue }
            loud.append(end.addingTimeInterval(-Double(frames - f - 1) * 0.03))
        }
        loud.removeAll { end.timeIntervalSince($0) > Self.keep }
    }

    /// The share (0 to 1) of the time from `start` to `end` that the Mac's sound was talking.
    public func overlap(from start: Date, to end: Date) -> Double {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 0 }
        return min(1, Double(loud.filter { $0 > start && $0 <= end }.count) * 0.03 / span)
    }

    public func isEcho(from start: Date, to end: Date) -> Bool { overlap(from: start, to: end) >= Self.echoShare }
}
