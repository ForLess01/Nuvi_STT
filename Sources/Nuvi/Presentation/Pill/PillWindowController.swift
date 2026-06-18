import AppKit
import SwiftUI

/// Hosts the pill in a borderless, non-activating floating panel pinned to the
/// top-left of the active screen. Non-activating means dictating never steals
/// focus from the app you're typing into.
@MainActor
final class PillWindowController {
    private enum Layout {
        static let screenInset: CGFloat = 22
        static let nebulaPadding: CGFloat = 34
        static let nebulaHorizontalBleed: CGFloat = 34
        static let nebulaVerticalBleed: CGFloat = 22
    }

    private enum Motion {
        static let showDuration: CFTimeInterval = 0.26
        static let hideDuration: CFTimeInterval = 0.22
        // Entrance starts narrowed at the left and grows right; exit shrinks back
        // toward the left. Subtle so it reads as a soft reveal, not a pop.
        static let startScale: CGFloat = 0.85
        static let exitScale: CGFloat = 0.93
        static let nebulaVisible: Float = 0.82
        // Smooth deceleration in, gentle in-out on the way out — no abrupt cuts.
        static let entrance = CAMediaTimingFunction(name: .easeOut)
        static let exit = CAMediaTimingFunction(name: .easeInEaseOut)
    }

    private let panel: NSPanel
    private let container = NSView()
    private let nebulaView = NebulaGlowView()
    private let hosting: NSHostingView<PillView>
    private var animationToken = 0

    init(controller: DictationController) {
        hosting = NSHostingView(rootView: PillView(controller: controller))

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 268, height: 132),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        container.wantsLayer = true
        container.layer?.masksToBounds = false
        container.layer?.opacity = 0   // starts hidden; show() fades it in
        container.autoresizingMask = [.width, .height]

        nebulaView.wantsLayer = true
        nebulaView.layer?.masksToBounds = false
        // The glow is a steady part of the pill; the container's opacity fade
        // handles show/hide for the whole stack at once.
        nebulaView.layer?.opacity = Motion.nebulaVisible

        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = false

        container.addSubview(nebulaView)
        container.addSubview(hosting)
        panel.contentView = container
    }

    func show() {
        animationToken += 1

        // Size and position before animating. resizeToContent() does an immediate
        // pass plus a deferred one on the next runloop — the deferred pass is
        // what re-anchors top-left once SwiftUI commits the real content, so the
        // pill never settles shifted to the right.
        resizeToContent()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        guard let layer = container.layer else { return }

        // Continue from whatever is on screen right now (e.g. mid hide-out), so
        // rapid push-to-talk reversals are seamless instead of snapping.
        let fromOpacity = layer.presentation()?.opacity ?? layer.opacity
        let fromTransform = layer.presentation()?.transform ?? leftAnchored(Motion.startScale)

        layer.removeAllAnimations()
        layer.opacity = 1
        layer.transform = CATransform3DIdentity

        animate(layer, key: "show",
                fromOpacity: fromOpacity, toOpacity: 1,
                fromTransform: fromTransform, toTransform: CATransform3DIdentity,
                duration: Motion.showDuration, timing: Motion.entrance,
                completion: nil)
    }

    func hide() {
        guard panel.isVisible, let layer = container.layer else { return }
        animationToken += 1
        let token = animationToken

        let fromOpacity = layer.presentation()?.opacity ?? layer.opacity
        let fromTransform = layer.presentation()?.transform ?? CATransform3DIdentity
        let toTransform = leftAnchored(Motion.exitScale)

        layer.removeAllAnimations()
        layer.opacity = 0
        layer.transform = toTransform

        animate(layer, key: "hide",
                fromOpacity: fromOpacity, toOpacity: 0,
                fromTransform: fromTransform, toTransform: toTransform,
                duration: Motion.hideDuration, timing: Motion.exit) { [weak self] in
            guard let self, self.animationToken == token else { return }
            self.panel.orderOut(nil)
        }
    }

    /// A transform that scales `container` while pinning its left edge, so growth
    /// reads as left-to-right (and shrink as right-to-left). Anchored via a
    /// translation rather than mutating the layer's anchorPoint, which AppKit
    /// resets on layer-backed views.
    private func leftAnchored(_ scale: CGFloat) -> CATransform3D {
        let width = container.bounds.width
        let dx = -(width * (1 - scale)) / 2
        return CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1),
                                   CATransform3DMakeTranslation(dx, 0, 0))
    }

    private func animate(_ layer: CALayer, key: String,
                         fromOpacity: Float, toOpacity: Float,
                         fromTransform: CATransform3D, toTransform: CATransform3D,
                         duration: CFTimeInterval, timing: CAMediaTimingFunction,
                         completion: (() -> Void)?) {
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = fromOpacity
        opacity.toValue = toOpacity

        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: fromTransform)
        transform.toValue = NSValue(caTransform3D: toTransform)

        let group = CAAnimationGroup()
        group.animations = [opacity, transform]
        group.duration = duration
        group.timingFunction = timing
        group.isRemovedOnCompletion = true

        CATransaction.begin()
        if let completion { CATransaction.setCompletionBlock(completion) }
        layer.add(group, forKey: key)
        CATransaction.commit()
    }

    /// Keep the panel hugging the SwiftUI content as the transcript grows or a
    /// notification widens the pill.
    ///
    /// Runs once now and once on the next runloop. SwiftUI commits content
    /// changes asynchronously, so an immediate measure can read a stale (wider)
    /// layout — sizing to that and letting the hosting view center the real
    /// content is what made the pill drift right after a notification. The
    /// deferred pass measures the committed content and re-anchors top-left.
    func resizeToContent() {
        applyContentSize()
        DispatchQueue.main.async { [weak self] in self?.applyContentSize() }
    }

    private func applyContentSize() {
        hosting.layoutSubtreeIfNeeded()
        let contentSize = hosting.fittingSize
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        let padding = Layout.nebulaPadding
        let panelSize = NSSize(width: contentSize.width + padding * 2,
                               height: contentSize.height + padding * 2)
        var frame = panel.frame
        frame.size = panelSize
        panel.setFrame(frame, display: true)

        container.frame = NSRect(origin: .zero, size: panelSize)
        hosting.frame = NSRect(x: padding, y: padding,
                               width: contentSize.width, height: contentSize.height)
        nebulaView.frame = hosting.frame.insetBy(dx: -Layout.nebulaHorizontalBleed,
                                                 dy: -Layout.nebulaVerticalBleed)
        nebulaView.needsDisplay = true

        // Always re-anchor to the top-left. X is constant, so any width change
        // grows rightward and the pill never separates from the left margin.
        positionTopLeft()
    }

    private func positionTopLeft() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let padding = Layout.nebulaPadding
        let contentHeight = max(hosting.frame.height, panel.frame.height - padding * 2)
        let origin = NSPoint(x: visible.minX + Layout.screenInset - padding,
                             y: visible.maxY - contentHeight - Layout.screenInset - padding)
        panel.setFrameOrigin(origin)
    }

}

/// Draws a soft, irregular ambient haze behind the pill.
///
/// This intentionally avoids layer shadows and solid fills. The shape comes from
/// overlapping translucent radial gradients, so there is no capsule outline or
/// detectable hard edge.
private final class NebulaGlowView: NSView {
    override var isFlipped: Bool { true }

    private struct Blob {
        let x: CGFloat
        let y: CGFloat
        let rx: CGFloat
        let ry: CGFloat
        let alpha: CGFloat
    }

    private let blobs: [Blob] = [
        Blob(x: 0.48, y: 0.50, rx: 0.58, ry: 0.34, alpha: 0.22),
        Blob(x: 0.23, y: 0.44, rx: 0.34, ry: 0.26, alpha: 0.12),
        Blob(x: 0.74, y: 0.39, rx: 0.36, ry: 0.24, alpha: 0.10),
        Blob(x: 0.58, y: 0.68, rx: 0.46, ry: 0.22, alpha: 0.13),
        Blob(x: 0.39, y: 0.26, rx: 0.40, ry: 0.20, alpha: 0.08),
        Blob(x: 0.84, y: 0.62, rx: 0.22, ry: 0.18, alpha: 0.07)
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.clear(bounds)

        for blob in blobs {
            drawBlob(blob, in: context)
        }
    }

    private func drawBlob(_ blob: Blob, in context: CGContext) {
        let center = CGPoint(x: bounds.width * blob.x, y: bounds.height * blob.y)
        let radiusX = max(bounds.width * blob.rx, 1)
        let radiusY = max(bounds.height * blob.ry, 1)

        let colors = [
            NSColor.black.withAlphaComponent(blob.alpha).cgColor,
            NSColor.black.withAlphaComponent(blob.alpha * 0.42).cgColor,
            NSColor.black.withAlphaComponent(blob.alpha * 0.12).cgColor,
            NSColor.clear.cgColor
        ] as CFArray
        let locations: [CGFloat] = [0.0, 0.36, 0.70, 1.0]

        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors,
                                        locations: locations) else { return }

        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: radiusX, y: radiusY)
        context.drawRadialGradient(gradient,
                                   startCenter: .zero,
                                   startRadius: 0,
                                   endCenter: .zero,
                                   endRadius: 1,
                                   options: [.drawsAfterEndLocation])
        context.restoreGState()
    }
}
