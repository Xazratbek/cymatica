import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

struct LaunchOptions {
    var demo = false
    var showNow = false
    var stay = false
    var openSettings = false
    var file: String?
    var snapshot: String?
    var analyze: String?
    var tapTest: TimeInterval?
    var shape: PlateField.Shape?
    var tier = 1
    var pitchClass = 9
    var then: (tier: Int, pitchClass: Int)?
    var frames = 360
    var after = 0
    var drive: Float = 0.9
    var width = 1512
    var height = 982
    var grains: Int?
    var dumpFrame: String?
    var clock: ClockStyle?
    var time = [10, 8, 30]
    var seconds = true
    var placement = Placement.center
    var plateSize: Float = 1

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        func pair(_ text: String?) -> (Int, Int)? {
            let parts = (text ?? "").split(separator: ",").compactMap { Int($0) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        while let argument = iterator.next() {
            switch argument {
            case "--demo": demo = true
            case "--show": showNow = true
            case "--stay": stay = true
            case "--settings": openSettings = true
            case "--file": file = iterator.next()
            case "--snapshot": snapshot = iterator.next()
            case "--analyze": analyze = iterator.next()
            case "--tap-test": tapTest = TimeInterval(iterator.next() ?? "") ?? 8
            case "--circle": shape = .circle
            case "--square": shape = .square
            case "--mode": if let (t, p) = pair(iterator.next()) { tier = t; pitchClass = p }
            case "--then": if let (t, p) = pair(iterator.next()) { then = (t, p) }
            case "--frames": frames = Int(iterator.next() ?? "") ?? frames
            case "--after": after = Int(iterator.next() ?? "") ?? after
            case "--drive": drive = Float(iterator.next() ?? "") ?? drive
            case "--size": if let (w, h) = pair(iterator.next()?.replacingOccurrences(of: "x", with: ",")) { width = w; height = h }
            case "--grains": grains = Int(iterator.next() ?? "")
            case "--clock": clock = ["digital": ClockStyle.digital, "analog": .analog, "rings": .rings][iterator.next() ?? ""]
            case "--time": time = (iterator.next() ?? "").split(separator: ":").compactMap { Int($0) }
            case "--no-seconds": seconds = false
            case "--place": placement = Placement(rawValue: Int(iterator.next() ?? "") ?? 0) ?? .center
            case "--plate-size": plateSize = Float(iterator.next() ?? "") ?? 1
            case "--dump-frame": dumpFrame = iterator.next()
            default: break // Finder and `open` add their own arguments
            }
        }
    }

    var isHeadless: Bool { snapshot != nil || analyze != nil || tapTest != nil }
}

/// Command-line jobs used to check the visuals and the audio pipeline without the UI.
enum Headless {
    static let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    static func run(_ options: LaunchOptions) -> Int32 {
        do {
            if let path = options.snapshot { try snapshot(to: path, options) }
            if let path = options.analyze { try analyze(path, options) }
            if let seconds = options.tapTest { try tapTest(seconds: seconds) }
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    /// Renders the plate offscreen for `frames` (+ `after` frames once `--then` switches
    /// the note) and writes an SDR PNG.
    private static func snapshot(to path: String, _ options: LaunchOptions) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw CocoaError(.featureUnsupported) }
        let renderer = try Renderer(device: device, grainCount: options.grains ?? 100_000)
        let shape = options.shape ?? .square
        let plate = PlateField(shape: shape, profiles: renderer.profiles)
        plate.select(tier: options.tier, pitchClass: options.pitchClass)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: options.width,
                                                                  height: options.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor) else { throw CocoaError(.featureUnsupported) }

        let dt: Float = 1 / 60
        var time: Float = 0
        // With --clock, the time shown advances by one second after `frames`, to see
        // only the changed digit's sand move.
        let face = ClockFace(style: options.clock ?? .digital, showSeconds: options.seconds)
        let clockTime = options.time + Array(repeating: 0, count: max(0, 3 - options.time.count))
        if options.clock != nil {
            renderer.setClockStrokes(face.strokes(hour: clockTime[0], minute: clockTime[1], second: clockTime[2]))
        }

        let total = options.frames + options.after
        let start = Date()
        for index in 0..<total {
            if index == options.frames, let next = options.then {
                plate.select(tier: next.tier, pitchClass: next.pitchClass)
            }
            if index == options.frames, options.clock != nil {
                renderer.setClockStrokes(face.strokes(hour: clockTime[0], minute: clockTime[1], second: clockTime[2] + 1))
            }
            plate.step(dt: dt)
            time += dt
            var input = FrameInput(dt: dt, time: time, drive: options.drive, modes: plate.gpuModes, shape: shape,
                                   minorness: 0, headroom: 1)
            input.clockMix = options.clock != nil ? 1 : 0
            input.placement = options.placement.transform(size: options.plateSize)
            guard let commandBuffer = renderer.queue.makeCommandBuffer() else { continue }
            renderer.encode(input, to: target, in: commandBuffer)
            commandBuffer.commit()
            if index % 30 == 0 || index == total - 1 { commandBuffer.waitUntilCompleted() }
        }
        let perFrame = Date().timeIntervalSince(start) / Double(max(total, 1)) * 1000
        try writePNG(target, to: URL(fileURLWithPath: path))
        print(String(format: "snapshot %@ mode %@ — %d frames, %.2f ms/frame", path,
                     plate.current?.label ?? "-", total, perFrame))
    }

    /// Feeds a file through the analyzer in simulated real time and prints its decisions.
    private static func analyze(_ path: String, _ options: LaunchOptions) throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        let step = AVAudioFrameCount(format.sampleRate / 60)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: step),
              let device = MTLCreateSystemDefaultDevice(),
              let profiles = device.makeBuffer(length: PlateField.profileLength * PlateField.slotCount * 4)
        else { throw CocoaError(.featureUnsupported) }
        let ring = AudioRing()
        let analyzer = MusicAnalyzer(ring: ring, sampleRate: Float(format.sampleRate))
        let plate = PlateField(shape: options.shape ?? .square, profiles: profiles)
        var time = 0.0
        var nextReport = 0.0
        var beats = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: step)
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            ring.write(left: channels[0], right: format.channelCount > 1 ? channels[1] : nil,
                       frames: Int(buffer.frameLength), stride: 1)
            let frame = analyzer.update(dt: 1 / 60)
            if frame.beat { beats += 1 }
            let changed = plate.select(tier: frame.tier, pitchClass: frame.pitchClass)
            if changed || time >= nextReport {
                print(String(format: "%6.2fs  %6.1f dBFS  drive %.2f  onset %.2f  %@ %4.0f Hz  tier %d  minor %.2f  beats %d  mode %@%@",
                             time, frame.dbfs, frame.drive, frame.onset, noteNames[frame.pitchClass], frame.noteHz,
                             frame.tier, frame.minorness, beats, plate.current?.label ?? "-", changed ? "  <- switch" : ""))
                if time >= nextReport { nextReport += 1; beats = 0 }
            }
            time += 1 / 60
        }
    }

    /// Starts the system tap and prints the captured level, to check permission and routing.
    private static func tapTest(seconds: TimeInterval) throws {
        let ring = AudioRing()
        let tap = SystemAudioTap(ring: ring)
        try tap.start()
        print("tap started at \(tap.sampleRate) Hz")
        let window = UnsafeMutablePointer<Float>.allocate(capacity: 4800)
        defer { window.deallocate() }
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            ring.readLatest(into: window, count: 4800)
            var peak: Float = 0
            for index in 0..<4800 { peak = max(peak, abs(window[index])) }
            print(String(format: "samples %9d  peak %.4f", ring.totalWritten, peak))
            fflush(stdout)
        }
        tap.stop()
    }

    static func writePNG(_ texture: MTLTexture, to url: URL) throws {
        let width = texture.width, height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
