import AppKit
import AVFoundation
import UniformTypeIdentifiers
import PikachuCore

/// Gets a picked or dropped file ready to send: pictures the model cannot take (HEIC, TIFF, very large) become JPEG,
/// and audio or video is transcribed here on the Mac (the recording itself never leaves it). Everything else goes as is.
enum FilePrep {
    private static let modelImages: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    private static let maxImageBytes = 4_500_000
    private static let maxSide: CGFloat = 2000
    private static let chunkSeconds = 30.0

    static func prepare(_ url: URL, transcriber: Transcriber) async -> Attached? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .audiovisualContent) == true {
            guard let text = try? await transcript(url, transcriber: transcriber), !text.isEmpty else { return nil }
            return Attached(name: url.lastPathComponent, data: Data(text.utf8), transcript: true)
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if type?.conforms(to: .image) == true, !modelImages.contains(url.pathExtension.lowercased()) || data.count > maxImageBytes {
            return jpeg(data).map { Attached(name: url.deletingPathExtension().lastPathComponent + ".jpg", data: $0) }
        }
        return Attached(name: url.lastPathComponent, data: data)
    }

    /// The picture as a JPEG no wider or taller than `maxSide`.
    private static func jpeg(_ data: Data) -> Data? {
        guard let image = NSImage(data: data), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .jpeg, properties: [.compressionFactor: 0.82]) }
    }

    /// Audio (or a video's sound) as 16 kHz mono, transcribed in 30-second pieces.
    private static func transcript(_ url: URL, transcriber: Transcriber) async throws -> String {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return "" }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: PushToTalk.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CompanionError.dropped }
        // Read and transcribe 30 seconds at a time: an hour of audio never sits in memory at once.
        let piece = Int(chunkSeconds * PushToTalk.sampleRate)
        var samples: [Float] = []
        var parts: [String] = []
        func transcribe(_ chunk: [Float]) async throws {
            let text = try await transcriber.transcribe(chunk, sampleRate: PushToTalk.sampleRate)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(text) }
        }
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            guard length >= 4 else { continue }
            var chunk = [Float](repeating: 0, count: length / 4)
            // Copies even when the audio is stored in several pieces (a plain pointer would read past the first).
            let bytes = chunk.count * 4
            guard chunk.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }) == kCMBlockBufferNoErr else { continue }
            samples += chunk
            while samples.count >= piece { try await transcribe(Array(samples.prefix(piece))); samples.removeFirst(piece) }
        }
        if !samples.isEmpty { try await transcribe(samples) }
        return parts.joined(separator: " ")
    }
}
