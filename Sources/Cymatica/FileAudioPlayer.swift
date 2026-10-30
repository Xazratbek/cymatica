import AVFoundation

/// Plays an audio file on a loop and feeds what it plays into the ring.
/// Lets the visual be tested without the system-audio permission.
final class FileAudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    let sampleRate: Double

    init(url: URL, ring: AudioRing) throws {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length))
        else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: buffer)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        let mixFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        sampleRate = mixFormat.sampleRate
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: mixFormat) { tapped, _ in
            guard let channels = tapped.floatChannelData else { return }
            let stereo = tapped.format.channelCount > 1
            ring.write(left: channels[0], right: stereo ? channels[1] : nil,
                       frames: Int(tapped.frameLength), stride: 1)
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
    }

    func start() throws {
        try engine.start()
        player.play()
    }
}
