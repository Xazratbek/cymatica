import MetalKit
import QuartzCore

/// Per-frame glue: music in, plate mode and grains out.
final class Visualizer: NSObject, MTKViewDelegate {
    let renderer: Renderer
    let plate: PlateField
    private let analyzer: MusicAnalyzer
    private var demo: DemoDriver?
    /// Called with a short caption ("A · 440 Hz · (7, 3)−") whenever the plate changes mode.
    var onModeChange: ((String) -> Void)?

    // Set from Settings by the app delegate.
    var mode: DisplayMode = .mixed
    var clockFace = ClockFace() {
        didSet { clockSecond = -1 }
    }
    /// Clip-space offset and scale of the plate (see `Placement`).
    var placement = SIMD3<Float>(0, 0, 1)
    /// React to every beat and to the music's intensity, not only to harmony.
    var followRhythm = false

    private var beatsSinceFlip = 0
    private var flipped = false
    private var sinceBeatFlip: Float = 10
    private var captionedPitch = -1
    private var lastTimestamp: CFTimeInterval = 0
    private var clock: Float = 0
    private var orbitTime: Float = 0
    private var clockMix: Float = 0
    private var silentFor: Float = 0
    private var clockKey = ""
    private var clockSecond = -1
    private var analysisElapsed: Float = 0
    private var lastMusic = MusicFrame()
    private var framesDrawn = 0
    var dumpPath: String?

    init(renderer: Renderer, plate: PlateField, analyzer: MusicAnalyzer, demo: Bool) {
        self.renderer = renderer
        self.plate = plate
        self.analyzer = analyzer
        self.demo = demo ? DemoDriver() : nil
    }

    /// Call when the view resumes, so the pause does not turn into one huge time step.
    func resetClock() {
        lastTimestamp = 0
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let commandBuffer = renderer.queue.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        let nominal = 1 / Double(max(view.preferredFramesPerSecond, 1))
        let dt = Float(lastTimestamp == 0 ? nominal : min(now - lastTimestamp, 0.05))
        lastTimestamp = now
        clock += dt

        let music = nextMusicFrame(dt: dt)

        // Clock or Chladni: mixed mode turns to the clock a few seconds into silence.
        silentFor = music.silent ? silentFor + dt : 0
        let wantsClock = mode == .clock || (mode == .mixed && silentFor > 2.5)
        clockMix = min(max(clockMix + (wantsClock ? dt : -dt) / 1.2, 0), 1)
        if clockMix > 0 { updateClockStrokes() }

        // Following the rhythm, the plate flips between the chord's figure and its neighbour
        // in the next tier once per bar (four beats), and never faster than the sand can
        // settle, so a figure is always readable between flips.
        var tier = music.tier
        if followRhythm {
            sinceBeatFlip += dt
            if music.beat { beatsSinceFlip += 1 }
            if beatsSinceFlip >= 4, sinceBeatFlip > 1.6 {
                flipped.toggle()
                beatsSinceFlip = 0
                sinceBeatFlip = 0
            }
            if flipped { tier = tier == 2 ? 1 : tier + 1 }
        }
        if plate.select(tier: tier, pitchClass: music.pitchClass), let figure = plate.current,
           !wantsClock, clockMix == 0, music.pitchClass != captionedPitch {
            captionedPitch = music.pitchClass
            onModeChange?("\(Headless.noteNames[music.pitchClass]) · \(Int(music.noteHz.rounded())) Hz · \(figure.label)")
        }
        plate.step(dt: dt)
        // Louder music turns the camera faster when following the rhythm.
        orbitTime += dt * (1 - clockMix) * (followRhythm ? 1 + 1.5 * music.level : 1)

        let headroom = Float(view.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        var input = FrameInput(dt: dt, time: clock, drive: music.drive, modes: plate.gpuModes, shape: plate.shape,
                               minorness: music.minorness, headroom: min(max(headroom, 1), 4))
        input.clockMix = clockMix
        // The clock keeps its plate humming even in silence; music makes its strokes shimmer.
        // On a beat the loose sand between the lines leaps higher and the figure flares,
        // but the drive barely rises, so the sand on the nodal lines stays put.
        let punch = followRhythm ? music.onset : 0
        input.drive = max(music.drive + 0.1 * punch, 0.85 * clockMix)
        input.hopBoost = 1 + 0.8 * punch
        input.glow = 1 + 0.6 * punch
        input.clockShimmer = music.silent ? 0 : 0.004 + (followRhythm ? 0.012 : 0.01) * music.onset
        input.orbitTime = orbitTime
        input.placement = placement
        renderer.encode(input, to: drawable.texture, in: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()

        framesDrawn += 1
        if let dumpPath, framesDrawn == 240 {
            dumpFrame(input, size: drawable.texture, to: dumpPath)
        }
    }

    /// Runs the analyzer at most 60 times a second, even when drawing at 120 FPS; in
    /// between, the last result is reused (with its one-frame beat flag cleared).
    private func nextMusicFrame(dt: Float) -> MusicFrame {
        if demo != nil { return demo!.next(dt: dt) }
        analysisElapsed += dt
        if analysisElapsed >= 1 / 62 {
            lastMusic = analyzer.update(dt: analysisElapsed)
            analysisElapsed = 0
        } else {
            lastMusic.beat = false
        }
        return lastMusic
    }

    /// Rebuilds the clock strokes when the displayed time (or the clock style) changes.
    private func updateClockStrokes() {
        // Cheap check every frame; the calendar math only runs when the second changes.
        let stamp = Int(Date().timeIntervalSince1970)
        guard stamp != clockSecond else { return }
        clockSecond = stamp
        let now = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        let hour = now.hour ?? 0, minute = now.minute ?? 0
        let second = clockFace.showSeconds ? now.second ?? 0 : 0
        let key = "\(clockFace.style.rawValue) \(clockFace.showSeconds) \(hour):\(minute):\(second)"
        guard key != clockKey else { return }
        clockKey = key
        renderer.setClockStrokes(clockFace.strokes(hour: hour, minute: minute, second: second))
    }

    /// Debug aid (`--dump-frame`): renders one live frame offscreen and saves it as PNG.
    private func dumpFrame(_ input: FrameInput, size reference: MTLTexture, to path: String) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: reference.width,
                                                                  height: reference.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = renderer.device.makeTexture(descriptor: descriptor),
              let commandBuffer = renderer.queue.makeCommandBuffer() else { return }
        var sdr = input
        sdr.headroom = 1
        renderer.encode(sdr, to: target, in: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try? Headless.writePNG(target, to: URL(fileURLWithPath: path))
        NSLog("Cymatica: dumped \(reference.width)x\(reference.height) \(reference.pixelFormat.rawValue) frame, headroom \(input.headroom), drive \(input.drive), modes \(input.modes)")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
