import MetalKit
import MetalPerformanceShaders
import CoreVideo
import os

struct GlassUniforms: Equatable {
    var tint = SIMD4<Float>.zero
    var capture = SIMD4<Float>.zero
    var mapping = SIMD4<Float>.zero
    var touch = SIMD4<Float>.zero
    var shape = SIMD4<Float>.zero
    var optics = SIMD4<Float>.zero
    var finish = SIMD4<Float>.zero
}

struct GlassGPU {
    static let shared = GlassGPU()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let textureCache: CVMetalTextureCache

    private init?() {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue(),
            let library = Self.makeLibrary(device: device),
            let vertex = library.makeFunction(name: "glassVertex"),
            let fragment = library.makeFunction(name: "glassFragment")
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        var cache: CVMetalTextureCache?
        guard
            let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
            let cache
        else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.textureCache = cache
    }

    static func makeLibrary(device: MTLDevice) -> MTLLibrary? {
        try? device.makeDefaultLibrary(bundle: .module)
    }
}

private final class BackdropSlot {
    let pixelBuffer: CVPixelBuffer
    let context: CGContext
    let texture: MTLTexture
    let width: Int
    let height: Int
    var blurred: MTLTexture?
    var needsBlur = false
    let inFlight = OSAllocatedUnfairLock(initialState: 0)
    private let cvTexture: CVMetalTexture

    init?(width: Int, height: Int, gpu: GlassGPU) {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()
        ]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard
            let base = CVPixelBufferGetBaseAddress(buffer),
            let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { return nil }
        var cvTexture: CVMetalTexture?
        guard
            CVMetalTextureCacheCreateTextureFromImage(nil, gpu.textureCache, buffer, nil, .bgra8Unorm, width, height, 0, &cvTexture) == kCVReturnSuccess,
            let cvTexture,
            let texture = CVMetalTextureGetTexture(cvTexture)
        else { return nil }
        self.pixelBuffer = buffer
        self.context = context
        self.cvTexture = cvTexture
        self.texture = texture
        self.width = width
        self.height = height
    }

    func blurredTexture(device: MTLDevice) -> MTLTexture? {
        if let blurred { return blurred }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        blurred = device.makeTexture(descriptor: descriptor)
        return blurred
    }
}

final class LiquidGlassRenderer {
    private static let slotCount = 3
    private static let signposter = OSSignposter(
        subsystem: "LiquidGlass",
        category: "LiquidGlass"
    )

    let device: MTLDevice
    private let gpu: GlassGPU
    private var slots = [BackdropSlot?](repeating: nil, count: LiquidGlassRenderer.slotCount)
    private var latest: Int?
    private var blur: (sigma: Float, kernel: MPSImageGaussianBlur)?
    private(set) var capturedRect = CGRect.null
    private var blurSigma: Float = 0

    var hasCapture: Bool { latest != nil }

    init?() {
        guard let gpu = GlassGPU.shared else { return nil }
        self.gpu = gpu
        self.device = gpu.device
    }

    /// `rect` is in `source.bounds` coordinates and must already be snapped to the pixel grid.
    @discardableResult
    func capture(_ source: UIView, rect: CGRect, scale: CGFloat, blurRadius: CGFloat, hiding views: [UIView]) -> Bool {
        let width = Int((rect.width * scale).rounded())
        let height = Int((rect.height * scale).rounded())
        guard width > 0, height > 0 else { return false }
        guard let index = freeSlotIndex() else { return false }
        if slots[index]?.width != width || slots[index]?.height != height {
            slots[index] = BackdropSlot(width: width, height: height, gpu: gpu)
        }
        guard let slot = slots[index] else { return false }

        CVPixelBufferLockBaseAddress(slot.pixelBuffer, [])
        let context = slot.context
        context.saveGState()
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        let wasHidden = views.map(\.isHidden)
        views.forEach { $0.isHidden = true }
        source.layer.render(in: context)
        zip(views, wasHidden).forEach { $0.isHidden = $1 }
        context.restoreGState()
        CVPixelBufferUnlockBaseAddress(slot.pixelBuffer, [])

        slot.needsBlur = blurRadius > 0
        blurSigma = Float(blurRadius * scale)
        latest = index
        capturedRect = rect
        return true
    }

    func draw(in view: MTKView, uniforms: GlassUniforms) {
        guard
            let index = latest,
            let slot = slots[index],
            let drawable = view.currentDrawable,
            let descriptor = view.currentRenderPassDescriptor,
            let commandBuffer = gpu.queue.makeCommandBuffer()
        else { return }

        var source = slot.texture
        if blurSigma > 0, let blurred = slot.blurredTexture(device: device) {
            if slot.needsBlur {
                blurKernel(sigma: blurSigma).encode(commandBuffer: commandBuffer, sourceTexture: slot.texture, destinationTexture: blurred)
                slot.needsBlur = false
            }
            source = blurred
        }

        var uniforms = uniforms
        uniforms.capture = SIMD4(
            Float(capturedRect.minX), Float(capturedRect.minY),
            Float(capturedRect.width), Float(capturedRect.height)
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(gpu.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GlassUniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        slot.inFlight.withLock { $0 += 1 }
        commandBuffer.addCompletedHandler { _ in
            slot.inFlight.withLock { $0 -= 1 }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    static func beginFrameInterval() -> OSSignpostIntervalState {
        signposter.beginInterval("CaptureEncode")
    }

    static func endFrameInterval(_ state: OSSignpostIntervalState) {
        signposter.endInterval("CaptureEncode", state)
    }

    private func freeSlotIndex() -> Int? {
        slots.indices.first { $0 != latest && (slots[$0]?.inFlight.withLock { $0 } ?? 0) == 0 }
    }

    private func blurKernel(sigma: Float) -> MPSImageGaussianBlur {
        if let blur, blur.sigma == sigma { return blur.kernel }
        let kernel = MPSImageGaussianBlur(device: device, sigma: sigma)
        kernel.edgeMode = .clamp
        blur = (sigma, kernel)
        return kernel
    }
}
