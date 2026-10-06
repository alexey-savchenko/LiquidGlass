import XCTest
import Metal
@testable import LiquidGlass

@MainActor
final class LiquidGlassTests: XCTestCase {
    func testPressSpringSettlesExactlyAtTarget() {
        var spring = Spring.press()
        spring.target = 1
        for _ in 0..<120 {
            spring.step(1.0 / 60)
        }
        XCTAssertTrue(spring.isSettled)
        XCTAssertEqual(spring.value, 1.0)
        XCTAssertEqual(spring.velocity, 0.0)
    }

    func testReleaseDipsBelowRestOnceBeforeSettling() {
        var spring = Spring.press(value: 1, target: 0)
        var lowest = spring.value
        var dips = 0
        var wasBelow = false
        for _ in 0..<240 {
            spring.step(1.0 / 60)
            lowest = min(lowest, spring.value)
            let isBelow = spring.value < -0.01
            if isBelow && !wasBelow { dips += 1 }
            wasBelow = isBelow
        }
        XCTAssertEqual(lowest, -0.15, accuracy: 0.02)
        XCTAssertEqual(dips, 1)
        XCTAssertEqual(spring.value, 0.0)
    }

    func testCaptureRectGetsMarginFromStyle() {
        let source = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let glass = LiquidGlassView(frame: CGRect(x: 100, y: 100, width: 200, height: 50))
        glass.style.refraction = 0.5
        glass.style.bezelWidth = 20
        source.addSubview(glass)
        glass.sourceView = source

        XCTAssertEqual(glass.captureRect(), CGRect(x: 90, y: 90, width: 220, height: 70))
    }

    func testCaptureRectIsClippedToSourceBounds() {
        let source = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let glass = LiquidGlassView(frame: CGRect(x: 10, y: 10, width: 100, height: 40))
        glass.style.refraction = 1
        glass.style.bezelWidth = 20
        source.addSubview(glass)
        glass.sourceView = source

        XCTAssertEqual(glass.captureRect(), CGRect(x: 0, y: 0, width: 130, height: 70))
    }

    func testCaptureRectFollowsPressTransform() {
        let source = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let glass = LiquidGlassView(frame: CGRect(x: 100, y: 100, width: 200, height: 50))
        glass.style.refraction = 0.5
        glass.style.bezelWidth = 20
        source.addSubview(glass)
        glass.sourceView = source
        glass.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)

        XCTAssertEqual(glass.captureRect(), CGRect(x: 70, y: 85, width: 260, height: 80))
    }

    func testCaptureRectOfScrolledSourceIsInContentCoordinates() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let source = UIScrollView(frame: container.bounds)
        source.contentSize = CGSize(width: 390, height: 5000)
        source.contentOffset = CGPoint(x: 0, y: 1000)
        let glass = LiquidGlassView(frame: CGRect(x: 100, y: 100, width: 200, height: 50))
        glass.style.refraction = 0.5
        glass.style.bezelWidth = 20
        container.addSubview(source)
        container.addSubview(glass)
        glass.sourceView = source

        XCTAssertEqual(glass.captureRect(), CGRect(x: 90, y: 1090, width: 220, height: 70))
    }

    func testSuperviewIsTheBackdropWhenNoSourceIsSet() {
        let superview = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let glass = LiquidGlassView(frame: CGRect(x: 100, y: 100, width: 200, height: 50))
        glass.style.refraction = 0.5
        glass.style.bezelWidth = 20
        superview.addSubview(glass)

        XCTAssertTrue(glass.backdropSource === superview)
        XCTAssertEqual(glass.captureRect(), CGRect(x: 90, y: 90, width: 220, height: 70))
    }

    func testCaptureHidesGlassAndVisibleViewsAboveItInsideTheSource() {
        let superview = UIView()
        let below = UIView()
        let glass = LiquidGlassView()
        let above = UIView()
        let hiddenAbove = UIView()
        hiddenAbove.isHidden = true
        let topmost = UIView()
        [below, glass, above, hiddenAbove, topmost].forEach(superview.addSubview)

        let hidden = glass.viewsHiddenDuringCapture(of: superview)

        XCTAssertEqual(hidden.map(ObjectIdentifier.init), [glass, above, topmost].map(ObjectIdentifier.init))
    }

    func testCaptureHidesViewsAboveEveryAncestorUpToTheSource() {
        let source = UIView()
        let host = UIView()
        let glass = LiquidGlassView()
        let overlayInHost = UIView()
        let overlayInSource = UIView()
        host.addSubview(glass)
        host.addSubview(overlayInHost)
        source.addSubview(host)
        source.addSubview(overlayInSource)
        glass.sourceView = source

        let hidden = glass.viewsHiddenDuringCapture(of: source)

        XCTAssertEqual(hidden.map(ObjectIdentifier.init), [glass, overlayInHost, overlayInSource].map(ObjectIdentifier.init))
    }

    func testSiblingSourceHidesOnlyTheGlass() {
        let container = UIView()
        let source = UIView()
        let glass = LiquidGlassView()
        let overlay = UIView()
        [source, glass, overlay].forEach(container.addSubview)
        glass.sourceView = source

        XCTAssertEqual(glass.viewsHiddenDuringCapture(of: source).map(ObjectIdentifier.init), [ObjectIdentifier(glass)])
    }

    func testFramesRunOnlyForAttachedLiveOrAnimatingGlass() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let glass = LiquidGlassView(frame: CGRect(x: 100, y: 100, width: 200, height: 50))
        XCTAssertEqual(glass.backdrop, .live)
        XCTAssertFalse(glass.needsFrames)

        window.addSubview(glass)
        XCTAssertTrue(glass.needsFrames)

        glass.backdrop = .static
        XCTAssertFalse(glass.needsFrames)
    }

    func testUniformsMatchTheMetalStructLayout() throws {
        // MSL GlassUniforms: seven float4 (7 * 16) = 112 bytes, 16-byte aligned.
        XCTAssertEqual(MemoryLayout<GlassUniforms>.stride, 112)
        XCTAssertEqual(MemoryLayout<GlassUniforms>.offset(of: \.finish), 96)

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try XCTUnwrap(GlassGPU.makeLibrary(device: device))
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "glassVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "glassFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        var reflection: MTLRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(descriptor: descriptor, options: [.bindingInfo], reflection: &reflection)

        let uniforms = reflection?.fragmentBindings.compactMap { $0 as? MTLBufferBinding }.first
        XCTAssertEqual(uniforms?.bufferDataSize, 112)
    }
}
