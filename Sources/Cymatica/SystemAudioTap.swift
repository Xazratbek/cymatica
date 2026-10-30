import AudioToolbox
import CoreAudio
import Foundation

/// Captures the mix of everything the Mac plays (Spotify, a browser, Apple Music...)
/// through a Core Audio process tap. No microphone and no virtual audio driver.
///
/// The first start makes macOS ask for "System Audio Recording" permission. Until the
/// user allows it, the tap delivers silence.
final class SystemAudioTap {
    enum TapError: Error, CustomStringConvertible {
        case coreAudio(String, OSStatus)
        case unsupportedFormat(AudioStreamBasicDescription)

        var description: String {
            switch self {
            case let .coreAudio(call, status): return "\(call) failed with OSStatus \(status)"
            case let .unsupportedFormat(format): return "unsupported tap format \(format)"
            }
        }
    }

    private let ring: AudioRing
    private(set) var sampleRate: Double = 48_000
    /// Called on the main queue after the tap is rebuilt (for example, new output device).
    var onRestart: ((Double) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "cymatica.audio-io", qos: .userInteractive)
    private var outputListener: AudioObjectPropertyListenerBlock?

    init(ring: AudioRing) {
        self.ring = ring
    }

    deinit {
        stop()
    }

    func start() throws {
        try build()
        listenForOutputChanges()
        armWatchdog()
    }

    func stop() {
        if let outputListener {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, outputListener)
            self.outputListener = nil
        }
        teardown()
    }

    // MARK: - Building the tap

    private func build() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Cymatica"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap

        var format = AudioStreamBasicDescription()
        try Self.read(tap, kAudioTapPropertyFormat, into: &format)
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else { throw TapError.unsupportedFormat(format) }
        sampleRate = format.mSampleRate

        let configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Cymatica Tap",
            kAudioAggregateDeviceUIDKey: "uz.cymatica.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        // Tap only, no real sub-device: adding the output device would also open its
        // microphone, and AirPods would drop to call quality.
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregate), "AudioHardwareCreateAggregateDevice")
        aggregateID = aggregate

        let ring = ring
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregate, ioQueue) { _, input, _, _, _ in
            // Real-time context: no allocation, no locks. The tap's stream is the last
            // input stream of the aggregate.
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let count = buffers.count
            guard count > 0 else { return }
            if nonInterleaved, count >= 2 {
                let left = buffers[count - 2], right = buffers[count - 1]
                guard let leftData = left.mData?.assumingMemoryBound(to: Float.self),
                      let rightData = right.mData?.assumingMemoryBound(to: Float.self)
                else { return }
                ring.write(left: leftData, right: rightData, frames: Int(left.mDataByteSize) / 4, stride: 1)
            } else {
                let buffer = buffers[count - 1]
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
                let channels = max(Int(buffer.mNumberChannels), 1)
                ring.write(left: data, right: channels > 1 ? data + 1 : nil,
                           frames: Int(buffer.mDataByteSize) / 4 / channels, stride: channels)
            }
        }, "AudioDeviceCreateIOProcIDWithBlock")
        try check(AudioDeviceStart(aggregate, ioProcID), "AudioDeviceStart")
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func rebuild() {
        teardown()
        do {
            try build()
            onRestart?(sampleRate)
        } catch {
            NSLog("Cymatica: tap rebuild failed: \(error)")
        }
    }

    /// Rebuilds the tap while it delivers no callbacks at all (silence still calls back),
    /// for example until the user answers the permission prompt. Backs off to 30 s.
    private func armWatchdog(after delay: TimeInterval = 2.5) {
        let writtenAtStart = ring.totalWritten
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.ring.totalWritten == writtenAtStart else { return }
            NSLog("Cymatica: no audio callbacks yet, rebuilding the tap")
            self.rebuild()
            self.armWatchdog(after: min(delay * 2, 30))
        }
    }

    private func listenForOutputChanges() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuild()
        }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    // MARK: - Core Audio helpers

    private func check(_ status: OSStatus, _ call: String) throws {
        guard status == noErr else { throw TapError.coreAudio(call, status) }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) throws {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { throw TapError.coreAudio("AudioObjectGetPropertyData(\(selector))", status) }
    }
}
