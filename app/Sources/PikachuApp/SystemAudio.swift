import AVFoundation
import CoreAudio
import PikachuCore

/// The Mac's own sound (a Meet or Zoom call, any app) as 16 kHz mono, for note taking, so the other side of a call is
/// written down even with headphones on. Jarvis's own voice is left out. Uses a Core Audio tap (macOS 14.2+); the first
/// time, macOS asks to allow system audio recording. Nothing is written to disk.
@available(macOS 14.2, *)
final class SystemAudio {
    enum Failure: Error { case notAllowed(OSStatus), noFormat }

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "dev.agentpikachu.system-audio")

    func start(onChunk: @escaping ([Float]) -> Void) throws {
        // Everything the Mac plays except this app (Jarvis speaking).
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcess().map { [$0] } ?? [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw Failure.notAllowed(status) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr,
              let input = AVAudioFormat(streamDescription: &format), let resampler = Resampler(from: input) else { stop(); throw Failure.noFormat }

        // A private device that carries the tap, so it can be read like a mic.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Jarvis note taking",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else { stop(); throw Failure.notAllowed(status) }

        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, data, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: input, bufferListNoCopy: data, deallocator: nil) else { return }
            let chunk = resampler.push(buffer)
            if !chunk.isEmpty { onChunk(chunk) }
        }
        guard status == noErr else { stop(); throw Failure.notAllowed(status) }
        status = AudioDeviceStart(device, proc)
        guard status == noErr else { stop(); throw Failure.notAllowed(status) }
        voiceLog.notice("system audio on")
    }

    func stop() {
        if let proc { AudioDeviceStop(device, proc); AudioDeviceDestroyIOProcID(device, proc) }
        proc = nil
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device); device = AudioObjectID(kAudioObjectUnknown) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = AudioObjectID(kAudioObjectUnknown) }
        voiceLog.notice("system audio off")
    }

    /// This app's Core Audio process object, so the tap can leave Jarvis's own voice out.
    private static func ownProcess() -> AudioObjectID? {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}
