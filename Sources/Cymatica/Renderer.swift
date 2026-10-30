import Metal
import QuartzCore
import simd

// Swift mirrors of the structs in Shaders.swift. Field order and types must match.

struct SimUniforms {
    var mode0: SIMD4<Float>
    var mode1: SIMD4<Float>
    var mode2: SIMD4<Float>
    var mode3: SIMD4<Float>
    var dt: Float
    var time: Float
    var drive: Float
    var gain: Float
    var threshold: Float
    var hopUp: Float
    var hopSide: Float
    var gravity: Float
    var shape: UInt32
    var frame: UInt32
    var grainCount: UInt32
    var clockCount: UInt32
    var clock: SIMD4<Float>
    var sprinkle: SIMD4<Float>
    var scatterFrom: UInt32
    var padding: SIMD3<UInt32> = .zero
}

struct DrawUniforms {
    var viewProjection: simd_float4x4
    var sandColor: SIMD4<Float>
    var sparkColor: SIMD4<Float>
    var halfVector: SIMD4<Float>
    var pointSize: Float
    var intensity: Float
    var sparkle: Float
    var time: Float
}

struct CompositeUniforms {
    var bloomStrength: Float
    var exposure: Float
    var headroom: Float
    var blackFloor: Float
}

/// Everything the renderer needs for one frame.
struct FrameInput {
    var dt: Float
    var time: Float
    var drive: Float
    var modes: [SIMD4<Float>]
    var shape: PlateField.Shape
    var minorness: Float
    /// EDR headroom of the screen (1 = SDR white is the brightest value).
    var headroom: Float
    /// 0 = Chladni modes only, 1 = the clock strokes only.
    var clockMix: Float = 0
    /// Extra shaking of the clock strokes, from the music.
    var clockShimmer: Float = 0
    /// Orbit clock; it stops while the clock is shown so the time stays readable.
    var orbitTime: Float = 0
    /// Clip-space offset (xy) and scale (z) that place the plate on the screen.
    var placement: SIMD3<Float> = SIMD3(0, 0, 1)
    /// Multiplies how high grains are thrown; the rhythm option raises it on beats.
    var hopBoost: Float = 1
    /// Multiplies sand brightness and bloom; the rhythm option flares it on beats.
    var glow: Float = 1
}

/// Slow orbit around the plate. With `reading` at 1 it turns to face the viewer
/// squarely, so clock digits read left to right.
struct OrbitCamera {
    var secondsPerTurn: Float = 420
    /// False when the user prefers reduced motion: the view holds still.
    var orbits = true
    var elevation: Float = 0.88
    var readingElevation: Float = 1.02
    var distance: Float = 6.0
    var fieldOfView: Float = 0.5

    func matrices(orbitTime: Float, time: Float, reading: Float, aspect: Float)
        -> (viewProjection: simd_float4x4, eye: SIMD3<Float>) {
        let orbit = (orbits ? orbitTime / secondsPerTurn * 2 * .pi : 0) + 0.55
        let front = (orbit / (2 * .pi)).rounded() * 2 * .pi + (orbits ? 0.05 * sin(time * 0.11) : 0)
        let azimuth = orbit + (front - orbit) * reading
        let sway = orbits ? 0.05 * sin(time * 0.045) : 0
        let tilt = elevation + sway + (readingElevation - elevation) * reading
        let eye = SIMD3<Float>(distance * cos(tilt) * sin(azimuth),
                               distance * sin(tilt),
                               distance * cos(tilt) * cos(azimuth))
        let view = Self.lookAt(eye: eye, target: SIMD3(0, -0.04, 0), up: SIMD3(0, 1, 0))
        let projection = Self.perspective(fovY: fieldOfView, aspect: aspect, near: 0.1, far: 50)
        return (projection * view, eye)
    }

    private static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = normalize(target - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        return simd_float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)))
    }

    /// Right-handed perspective with Metal's 0...1 clip depth.
    private static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, z * near, 0)))
    }
}

/// GPU sand: a compute pass moves the grains, a point pass draws them into a float
/// target, a dual-filter bloom adds glow, and the composite writes EDR values.
/// Grain state never leaves the GPU.
final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    /// Radial profiles for circle modes, one per mode slot, written by PlateField.
    let profiles: MTLBuffer
    var camera = OrbitCamera()

    // Physics constants, in plate units (the plate spans -1...1) and seconds.
    var plateGain: Float = 13
    var launchThreshold: Float = 1
    var hopUp: Float = 0.24
    var hopSide: Float = 0.5
    var gravity: Float = 9

    // Look.
    var grainSize: Float = 2.4
    var grainIntensity: Float = 0.45
    var sparkle: Float = 1.6
    var glint: Float = 2.2
    var bloomStrength: Float = 0.55
    var exposure: Float = 1
    var blackFloor: Float = 0.002

    // Clock mode.
    var clockGuide: Float = 1.6
    var clockFalloff: Float = 0.08
    var sprinkleRate: Float = 0.12
    var sprinkleSide: Float = 0.9
    var sprinkleRise: Float = 0.35

    private(set) var grainCount: Int
    private var grains: MTLBuffer
    private var needsScatter = true
    /// First grain to re-sprinkle; above 0 when the grain count grew and the old
    /// grains were copied over, so the current figure survives.
    private var scatterFrom = 0
    private var pendingCopy: (buffer: MTLBuffer, count: Int)?
    private var scatteredShape: PlateField.Shape?
    private var clockStrokes: MTLBuffer
    private var clockStrokeCount = 0
    /// Distance-to-stroke field for the clock, rebuilt only when the strokes change.
    private let clockField: MTLTexture
    private var needsBake = false
    private var frameIndex: UInt32 = 0

    private let library: MTLLibrary
    private let scatterPipeline: MTLComputePipelineState
    private let simulatePipeline: MTLComputePipelineState
    private let bakePipeline: MTLComputePipelineState
    private let grainPipeline: MTLRenderPipelineState
    private let rimPipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLRenderPipelineState
    private let upsamplePipeline: MTLRenderPipelineState
    private var compositePipelines: [UInt: MTLRenderPipelineState] = [:]

    private var scene: MTLTexture?
    private var bloomLevels: [MTLTexture] = []
    private let squareRim: [SIMD4<Float>]
    private let circleRim: [SIMD4<Float>]

    private static let hdrFormat = MTLPixelFormat.rgba16Float

    init(device: MTLDevice, grainCount: Int) throws {
        self.device = device
        guard let queue = device.makeCommandQueue(),
              let profiles = device.makeBuffer(length: PlateField.profileLength * PlateField.slotCount * 4,
                                               options: .storageModeShared),
              let grains = device.makeBuffer(length: grainCount * 32, options: .storageModePrivate),
              let clockStrokes = device.makeBuffer(length: MemoryLayout<ClockStroke>.stride, options: .storageModeShared),
              let clockField = Self.makeFieldTexture(device)
        else { throw RendererError.allocation }
        self.queue = queue
        self.profiles = profiles
        self.grains = grains
        self.clockStrokes = clockStrokes
        self.clockField = clockField
        self.grainCount = grainCount

        library = try device.makeLibrary(source: ShaderSource.metal, options: nil)
        scatterPipeline = try device.makeComputePipelineState(function: try Self.function("scatterGrains", in: library))
        simulatePipeline = try device.makeComputePipelineState(function: try Self.function("simulateGrains", in: library))
        bakePipeline = try device.makeComputePipelineState(function: try Self.function("bakeClockField", in: library))
        grainPipeline = try Self.pipeline(device, library, vertex: "grainVertex", fragment: "grainFragment", additive: true)
        rimPipeline = try Self.pipeline(device, library, vertex: "rimVertex", fragment: "rimFragment", additive: true)
        downsamplePipeline = try Self.pipeline(device, library, vertex: "fullscreenVertex", fragment: "bloomDownsample", additive: false)
        upsamplePipeline = try Self.pipeline(device, library, vertex: "fullscreenVertex", fragment: "bloomUpsample", additive: true)

        squareRim = [SIMD4(-1, 0, -1, 1), SIMD4(1, 0, -1, 1), SIMD4(1, 0, 1, 1), SIMD4(-1, 0, 1, 1), SIMD4(-1, 0, -1, 1)]
        circleRim = (0...128).map { index in
            let angle = Float(index) / 128 * 2 * .pi
            return SIMD4(cos(angle), 0, sin(angle), 1)
        }
    }

    enum RendererError: Error { case allocation, missingFunction(String) }

    /// Changes the amount of sand. Existing grains keep their places; only the added
    /// ones are sprinkled.
    func setGrainCount(_ count: Int) {
        guard count != grainCount, let buffer = device.makeBuffer(length: count * 32, options: .storageModePrivate) else { return }
        if !(needsScatter && scatterFrom == 0) {
            pendingCopy = (grains, min(grainCount, count))
            scatterFrom = min(grainCount, count)
        }
        grains = buffer
        grainCount = count
        needsScatter = true
    }

    /// Spreads the sand evenly again, as if the plate had just been sprinkled.
    func scatter() {
        needsScatter = true
        scatterFrom = 0
        pendingCopy = nil
    }

    /// Replaces the strokes the clock draws. A new buffer each time, so frames still
    /// in flight keep reading the strokes they were encoded with.
    func setClockStrokes(_ strokes: [ClockStroke]) {
        guard !strokes.isEmpty,
              let buffer = device.makeBuffer(bytes: strokes, length: strokes.count * MemoryLayout<ClockStroke>.stride,
                                             options: .storageModeShared)
        else { return }
        clockStrokes = buffer
        clockStrokeCount = strokes.count
        needsBake = true
    }

    func encode(_ input: FrameInput, to target: MTLTexture, in commandBuffer: MTLCommandBuffer) {
        prepareTextures(width: target.width, height: target.height)
        guard let scene, let bloomBase = bloomLevels.first else { return }
        frameIndex &+= 1
        simulate(input, commandBuffer)
        drawSand(input, into: scene, commandBuffer)
        bloom(from: scene, commandBuffer)
        composite(input, scene: scene, bloom: bloomBase, target: target, commandBuffer)
    }

    // MARK: - Passes

    private func simulate(_ input: FrameInput, _ commandBuffer: MTLCommandBuffer) {
        if let copy = pendingCopy, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: copy.buffer, sourceOffset: 0, to: grains, destinationOffset: 0, size: copy.count * 32)
            blit.endEncoding()
            pendingCopy = nil
        }
        if needsBake, clockStrokeCount > 0, let bake = commandBuffer.makeComputeCommandEncoder() {
            var count = UInt32(clockStrokeCount)
            bake.setComputePipelineState(bakePipeline)
            bake.setTexture(clockField, index: 0)
            bake.setBuffer(clockStrokes, offset: 0, index: 0)
            bake.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 1)
            bake.dispatchThreads(MTLSize(width: clockField.width, height: clockField.height, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            bake.endEncoding()
            needsBake = false
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        let shapeChanged = scatteredShape != input.shape
        let modes = input.modes + Array(repeating: SIMD4<Float>.zero, count: max(0, 4 - input.modes.count))
        var uniforms = SimUniforms(mode0: modes[0], mode1: modes[1], mode2: modes[2], mode3: modes[3],
                                   dt: input.dt, time: input.time, drive: input.drive, gain: plateGain,
                                   threshold: launchThreshold, hopUp: hopUp * input.hopBoost, hopSide: hopSide, gravity: gravity,
                                   shape: UInt32(input.shape.rawValue), frame: frameIndex,
                                   grainCount: UInt32(grainCount),
                                   clockCount: UInt32(input.clockMix > 0 ? clockStrokeCount : 0),
                                   clock: SIMD4(input.clockMix, input.clockShimmer, clockGuide, clockFalloff),
                                   sprinkle: SIMD4(sprinkleRate, sprinkleSide, sprinkleRise, 0),
                                   scatterFrom: UInt32(shapeChanged ? 0 : scatterFrom))
        let threads = MTLSize(width: grainCount, height: 1, depth: 1)
        let group = MTLSize(width: 256, height: 1, depth: 1)
        encoder.setBuffer(grains, offset: 0, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<SimUniforms>.stride, index: 1)
        encoder.setBuffer(profiles, offset: 0, index: 2)
        encoder.setTexture(clockField, index: 0)
        if needsScatter || shapeChanged {
            encoder.setComputePipelineState(scatterPipeline)
            encoder.dispatchThreads(threads, threadsPerThreadgroup: group)
            needsScatter = false
            scatterFrom = 0
            scatteredShape = input.shape
        }
        encoder.setComputePipelineState(simulatePipeline)
        encoder.dispatchThreads(threads, threadsPerThreadgroup: group)
        encoder.endEncoding()
    }

    private func drawSand(_ input: FrameInput, into scene: MTLTexture, _ commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = scene
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let aspect = Float(scene.width) / Float(scene.height)
        let (cameraMatrix, eye) = camera.matrices(orbitTime: input.orbitTime, time: input.time,
                                                  reading: input.clockMix, aspect: aspect)
        // Move and scale the finished image in clip space to the chosen screen spot.
        let place = input.placement
        let placement = simd_float4x4(columns: (SIMD4(place.z, 0, 0, 0), SIMD4(0, place.z, 0, 0),
                                                SIMD4(0, 0, 1, 0), SIMD4(place.x, place.y, 0, 1)))
        let viewProjection = placement * cameraMatrix
        let light = normalize(SIMD3<Float>(-0.45, 1.0, -0.35))
        let halfVector = normalize(light + normalize(eye))

        // Warm gold in major keys, paler champagne gold in minor keys (linear Display P3).
        let warm = SIMD3<Float>(1.0, 0.62, 0.24), pale = SIMD3<Float>(0.92, 0.76, 0.52)
        let sand = warm + (pale - warm) * input.minorness
        var uniforms = DrawUniforms(
            viewProjection: viewProjection,
            sandColor: SIMD4(sand, 1),
            sparkColor: SIMD4(1.0, 0.86, 0.62, 1),
            halfVector: SIMD4(halfVector, glint),
            pointSize: max(grainSize * Float(scene.height) / 1964 * max(sqrt(place.z), 0.7), 1.1),
            intensity: grainIntensity * input.glow,
            sparkle: sparkle,
            time: input.time)

        var rim = input.shape == .square ? squareRim : circleRim
        var rimColor = SIMD4<Float>(sand * 0.035, 0)
        encoder.setRenderPipelineState(rimPipeline)
        encoder.setVertexBytes(&rim, length: rim.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DrawUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&rimColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: rim.count)

        encoder.setRenderPipelineState(grainPipeline)
        encoder.setVertexBuffer(grains, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DrawUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: grainCount)
        encoder.endEncoding()
    }

    private func bloom(from scene: MTLTexture, _ commandBuffer: MTLCommandBuffer) {
        var source = scene
        for level in bloomLevels {
            fullscreenPass(downsamplePipeline, source: source, target: level, load: .dontCare, commandBuffer)
            source = level
        }
        for index in stride(from: bloomLevels.count - 2, through: 0, by: -1) {
            fullscreenPass(upsamplePipeline, source: bloomLevels[index + 1], target: bloomLevels[index], load: .load, commandBuffer)
        }
    }

    private func composite(_ input: FrameInput, scene: MTLTexture, bloom: MTLTexture, target: MTLTexture, _ commandBuffer: MTLCommandBuffer) {
        guard let pipeline = compositePipeline(for: target.pixelFormat) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = CompositeUniforms(bloomStrength: bloomStrength * input.glow, exposure: exposure,
                                         headroom: max(input.headroom, 1), blackFloor: blackFloor)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(scene, index: 0)
        encoder.setFragmentTexture(bloom, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func fullscreenPass(_ pipeline: MTLRenderPipelineState, source: MTLTexture, target: MTLTexture,
                                load: MTLLoadAction, _ commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: - Resources

    private func prepareTextures(width: Int, height: Int) {
        if let scene, scene.width == width, scene.height == height { return }
        scene = makeTexture(width: width, height: height)
        // Four levels from half to 1/16 resolution: wide glow, little fill-rate.
        bloomLevels = (1...4).compactMap { level in
            makeTexture(width: max(width >> level, 1), height: max(height >> level, 1))
        }
    }

    /// 1024² over the plate: about 0.002 plate units per texel, finer than the thinnest
    /// stroke, so sampling it draws the same clock the per-stroke loop did.
    private static func makeFieldTexture(_ device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1024,
                                                                  height: 1024, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private func makeTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.hdrFormat, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private func compositePipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let existing = compositePipelines[format.rawValue] { return existing }
        let pipeline = try? Self.pipeline(device, library, vertex: "fullscreenVertex", fragment: "compositeFragment",
                                          additive: false, format: format)
        compositePipelines[format.rawValue] = pipeline
        return pipeline
    }

    private static func function(_ name: String, in library: MTLLibrary) throws -> MTLFunction {
        guard let function = library.makeFunction(name: name) else { throw RendererError.missingFunction(name) }
        return function
    }

    private static func pipeline(_ device: MTLDevice, _ library: MTLLibrary, vertex: String, fragment: String,
                                 additive: Bool, format: MTLPixelFormat = hdrFormat) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try function(vertex, in: library)
        descriptor.fragmentFunction = try function(fragment, in: library)
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = format
        if additive {
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
        }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}
