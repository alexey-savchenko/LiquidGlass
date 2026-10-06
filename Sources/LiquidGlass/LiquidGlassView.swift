import UIKit
import MetalKit

public struct LiquidGlassStyle: Equatable {
    public enum Shape: Equatable {
        case capsule
        case roundedRect(cornerRadius: CGFloat)
        case circle

        public func cornerRadius(in size: CGSize) -> CGFloat {
            let limit = min(size.width, size.height) / 2
            switch self {
            case .capsule, .circle:
                return limit
            case .roundedRect(let cornerRadius):
                return min(cornerRadius, limit)
            }
        }
    }

    public var shape: Shape
    public var tint: UIColor
    public var blurRadius: CGFloat
    public var refraction: CGFloat
    public var bezelWidth: CGFloat
    public var chromaticAberration: CGFloat
    public var saturation: CGFloat
    public var highlight: CGFloat
    public var opacity: CGFloat

    public init(
        shape: Shape = .capsule,
        tint: UIColor = UIColor.white.withAlphaComponent(0.10),
        blurRadius: CGFloat = 2,
        refraction: CGFloat = 0.9,
        bezelWidth: CGFloat = 16,
        chromaticAberration: CGFloat = 0.06,
        saturation: CGFloat = 1.4,
        highlight: CGFloat = 0.8,
        opacity: CGFloat = 1
    ) {
        self.shape = shape
        self.tint = tint
        self.blurRadius = blurRadius
        self.refraction = refraction
        self.bezelWidth = bezelWidth
        self.chromaticAberration = chromaticAberration
        self.saturation = saturation
        self.highlight = highlight
        self.opacity = opacity
    }

    public var captureMargin: CGFloat { refraction * bezelWidth }

    public static let regular = LiquidGlassStyle(
        shape: .capsule,
        tint: UIColor.white.withAlphaComponent(0.10),
        blurRadius: 2,
        refraction: 0.9,
        bezelWidth: 16,
        chromaticAberration: 0.06,
        saturation: 1.4,
        highlight: 0.8,
        opacity: 1
    )

    public static let clear = LiquidGlassStyle(
        shape: .capsule,
        tint: UIColor.white.withAlphaComponent(0),
        blurRadius: 0,
        refraction: 1,
        bezelWidth: 20,
        chromaticAberration: 0.08,
        saturation: 1.15,
        highlight: 1,
        opacity: 1
    )
}

struct Spring: Equatable {
    var value: Double
    var velocity: Double = 0
    var target: Double
    var stiffness: Double
    var damping: Double

    var isSettled: Bool {
        abs(target - value) < 0.0005 && abs(velocity) < 0.005
    }

    static func press(value: Double = 0, target: Double = 0) -> Spring {
        Spring(value: value, target: target, stiffness: 380, damping: 20)
    }

    static func touch(at value: Double) -> Spring {
        Spring(value: value, target: value, stiffness: 220, damping: 16)
    }

    mutating func step(_ dt: Double) {
        let steps = max(1, Int((dt * 240).rounded(.up)))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            velocity += (stiffness * (target - value) - damping * velocity) * h
            value += velocity * h
        }
        if isSettled {
            value = target
            velocity = 0
        }
    }
}

public final class LiquidGlassView: UIControl {
    public enum Backdrop {
        case live
        case `static`
    }

    public let contentView = UIView()

    /// The view refracted by the glass. When `nil`, the glass refracts its superview.
    public weak var sourceView: UIView? {
        didSet { setNeedsBackdropUpdate() }
    }

    var backdropSource: UIView? {
        sourceView ?? superview
    }

    public var style = LiquidGlassStyle.regular {
        didSet {
            guard style != oldValue else { return }
            applyFallbackAppearance()
            setNeedsBackdropUpdate()
        }
    }

    public var backdrop = Backdrop.static {
        didSet {
            guard backdrop != oldValue else { return }
            setNeedsBackdropUpdate()
        }
    }

    private(set) var press = Spring.press()
    private var touchX = Spring.touch(at: 0)
    private var touchY = Spring.touch(at: 0)

    var needsFrames: Bool {
        window != nil && ((backdrop == .live && !usesSolidFill) || !isMotionSettled)
    }

    private let renderer = LiquidGlassRenderer()
    private let mtkView = MTKView()
    private let frameDriver = FrameDriver()
    private var isBackdropDirty = true
    private var lastCaptureRect: CGRect?
    private var lastFrameTime: CFTimeInterval?
    private var hasPendingDraw = false

    private var isMotionSettled: Bool {
        press.isSettled && touchX.isSettled && touchY.isSettled
    }

    private var usesSolidFill: Bool {
        renderer == nil || UIAccessibility.isReduceTransparencyEnabled
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUp() {
        mtkView.device = renderer?.device
        frameDriver.glass = self
        mtkView.delegate = frameDriver
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.isOpaque = false
        mtkView.layer.isOpaque = false
        mtkView.backgroundColor = .clear
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = true
        mtkView.isUserInteractionEnabled = false
        contentView.isUserInteractionEnabled = false
        addSubview(mtkView)
        addSubview(contentView)
        for subview in [mtkView, contentView] {
            subview.frame = bounds
            subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        applyFallbackAppearance()

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: LiquidGlassView, _) in
            self.applyFallbackAppearance()
            self.setNeedsBackdropUpdate()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reduceTransparencyDidChange),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            object: nil
        )
    }

    public func setNeedsBackdropUpdate() {
        isBackdropDirty = true
        updateFrameLoop()
        scheduleStaticDraw()
    }

    public override func didMoveToSuperview() {
        super.didMoveToSuperview()
        setNeedsBackdropUpdate()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            lastCaptureRect = nil
        }
        invalidateBackdropIfRectChanged()
        updateFrameLoop()
        scheduleStaticDraw()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = style.shape.cornerRadius(in: bounds.size)
        invalidateBackdropIfRectChanged()
    }

    public override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let point = touch.location(in: self)
        touchX = .touch(at: point.x)
        touchY = .touch(at: point.y)
        press.target = 1
        updateFrameLoop()
        return true
    }

    public override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let point = touch.location(in: self)
        touchX.target = point.x
        touchY.target = point.y
        updateFrameLoop()
        return true
    }

    public override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        press.target = 0
        if let touch, bounds.contains(touch.location(in: self)) {
            sendActions(for: .primaryActionTriggered)
        }
        updateFrameLoop()
    }

    public override func cancelTracking(with event: UIEvent?) {
        press.target = 0
        updateFrameLoop()
    }

    func captureRect() -> CGRect? {
        guard let source = backdropSource, !bounds.isEmpty else { return nil }
        let rect = Self.captureRect(
            glassFrame: convert(bounds, to: source),
            margin: style.captureMargin,
            sourceBounds: source.bounds,
            scale: pixelScale
        )
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    /// Everything stacked above the glass inside `source` would otherwise be captured and refracted under itself.
    func viewsHiddenDuringCapture(of source: UIView) -> [UIView] {
        guard isDescendant(of: source) else { return [self] }
        var hidden: [UIView] = [self]
        var node: UIView = self
        while node !== source, let parent = node.superview {
            if let index = parent.subviews.firstIndex(where: { $0 === node }) {
                hidden += parent.subviews[(index + 1)...].filter { !$0.isHidden }
            }
            node = parent
        }
        return hidden
    }

    static func captureRect(glassFrame: CGRect, margin: CGFloat, sourceBounds: CGRect, scale: CGFloat) -> CGRect {
        let clipped = glassFrame.insetBy(dx: -margin, dy: -margin).intersection(sourceBounds)
        guard !clipped.isNull else { return .null }
        let minX = (clipped.minX * scale).rounded(.down) / scale
        let minY = (clipped.minY * scale).rounded(.down) / scale
        let maxX = (clipped.maxX * scale).rounded(.up) / scale
        let maxY = (clipped.maxY * scale).rounded(.up) / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(sourceBounds)
    }

    private var pixelScale: CGFloat {
        let scale = traitCollection.displayScale
        return scale > 0 ? scale : 1
    }

    private func invalidateBackdropIfRectChanged() {
        guard window != nil, backdrop == .static else { return }
        let rect = captureRect()
        guard rect != lastCaptureRect else { return }
        lastCaptureRect = rect
        isBackdropDirty = true
        scheduleStaticDraw()
    }

    private func updateFrameLoop() {
        let frames = needsFrames
        guard mtkView.isPaused == frames else { return }
        mtkView.isPaused = !frames
        if !frames { lastFrameTime = nil }
    }

    private func scheduleStaticDraw() {
        guard window != nil, !needsFrames, !hasPendingDraw, !usesSolidFill else { return }
        hasPendingDraw = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            hasPendingDraw = false
            guard window != nil, mtkView.isPaused else { return }
            mtkView.draw()
        }
    }

    private func applyFallbackAppearance() {
        layer.cornerRadius = style.shape.cornerRadius(in: bounds.size)
        let solid = usesSolidFill
        mtkView.isHidden = solid
        if solid {
            let fill: UIColor = style.tint.cgColor.alpha >= 0.5 ? style.tint.withAlphaComponent(1) : .secondarySystemBackground
            backgroundColor = fill
        } else {
            backgroundColor = nil
        }
    }

    @objc private func reduceTransparencyDidChange() {
        applyFallbackAppearance()
        setNeedsBackdropUpdate()
    }

    private func stepMotion() {
        let now = CACurrentMediaTime()
        let dt = min(lastFrameTime.map { now - $0 } ?? 1.0 / 60, 1.0 / 30)
        lastFrameTime = now
        press.step(dt)
        touchX.step(dt)
        touchY.step(dt)
        let scale = UIAccessibility.isReduceMotionEnabled ? 1 : 1 + 0.06 * press.value
        let next = CGAffineTransform(scaleX: scale, y: scale)
        if transform != next { transform = next }
    }

    private func makeUniforms(source: UIView) -> GlassUniforms {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        style.tint.resolvedColor(with: traitCollection).getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let center = source.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: self)
        let edge = source.convert(CGPoint(x: bounds.maxX, y: bounds.midY), from: self)
        let scale = bounds.width > 0 ? (edge.x - center.x) / (bounds.width / 2) : 1
        let origin = CGPoint(x: center.x - bounds.width / 2 * scale, y: center.y - bounds.height / 2 * scale)
        let touchRadius = max(min(bounds.width, bounds.height) * 0.9, 44)

        var uniforms = GlassUniforms()
        uniforms.tint = SIMD4(Float(red), Float(green), Float(blue), Float(alpha))
        uniforms.mapping = SIMD4(Float(origin.x), Float(origin.y), Float(scale), Float(press.value))
        uniforms.touch = SIMD4(Float(touchX.value), Float(touchY.value), Float(touchRadius), 0.35)
        uniforms.shape = SIMD4(
            Float(bounds.width), Float(bounds.height),
            Float(style.shape.cornerRadius(in: bounds.size)), Float(style.bezelWidth)
        )
        uniforms.optics = SIMD4(
            Float(style.refraction), Float(style.chromaticAberration),
            Float(style.saturation), Float(style.highlight)
        )
        uniforms.finish = SIMD4(Float(style.opacity), 0, 0, 0)
        return uniforms
    }
}

private final class FrameDriver: NSObject, MTKViewDelegate {
    weak var glass: LiquidGlassView?

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        glass?.renderFrame(in: view)
    }
}

extension LiquidGlassView {
    fileprivate func renderFrame(in view: MTKView) {
        stepMotion()
        defer { updateFrameLoop() }
        guard !usesSolidFill, let renderer, let source = backdropSource, let rect = captureRect() else { return }

        let interval = LiquidGlassRenderer.beginFrameInterval()
        defer { LiquidGlassRenderer.endFrameInterval(interval) }
        if backdrop == .live || isBackdropDirty || !renderer.hasCapture {
            if renderer.capture(source, rect: rect, scale: pixelScale, blurRadius: style.blurRadius, hiding: viewsHiddenDuringCapture(of: source)) {
                isBackdropDirty = false
            }
        }
        renderer.draw(in: view, uniforms: makeUniforms(source: source))
    }
}
