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
        static let showDuration: TimeInterval = 0.20
        static let hideDuration: TimeInterval = 0.17
        static let showStartScale: CGFloat = 0.972
        static let hideEndScale: CGFloat = 0.988
        static let visibleNebulaOpacity: Float = 0.82
        static let hiddenNebulaOpacity: Float = 0
        static let entranceTiming = CAMediaTimingFunction(controlPoints: 0.18, 0.92, 0.22, 1.0)
        static let exitTiming = CAMediaTimingFunction(controlPoints: 0.38, 0.0, 0.24, 1.0)
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
        container.autoresizingMask = [.width, .height]

        nebulaView.wantsLayer = true
        nebulaView.layer?.masksToBounds = false
        nebulaView.layer?.opacity = Motion.hiddenNebulaOpacity

        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = false

        container.addSubview(nebulaView)
        container.addSubview(hosting)
        panel.contentView = container
    }

    func show() {
        animationToken += 1
        let token = animationToken

        resizeToContent()
        positionTopLeft()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()

        prepareLayerAnimation(fromScale: Motion.showStartScale,
                              nebulaOpacity: Motion.hiddenNebulaOpacity)
        panel.alphaValue = 0

        animatePanelAlpha(to: 1, duration: Motion.showDuration, timing: Motion.entranceTiming)
        animateLayers(duration: Motion.showDuration, timing: Motion.entranceTiming) {
            self.container.layer?.transform = CATransform3DIdentity
            self.nebulaView.layer?.opacity = Motion.visibleNebulaOpacity
        } completion: {
            guard self.animationToken == token else { return }
            self.panel.alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        animationToken += 1
        let token = animationToken

        prepareLayerAnimation(fromScale: 1,
                              nebulaOpacity: Motion.visibleNebulaOpacity)
        animatePanelAlpha(to: 0, duration: Motion.hideDuration, timing: Motion.exitTiming)
        animateLayers(duration: Motion.hideDuration, timing: Motion.exitTiming) {
            self.container.layer?.transform = CATransform3DMakeScale(Motion.hideEndScale, Motion.hideEndScale, 1)
            self.nebulaView.layer?.opacity = Motion.hiddenNebulaOpacity
        } completion: {
            guard self.animationToken == token else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.container.layer?.transform = CATransform3DIdentity
            self.nebulaView.layer?.opacity = Motion.hiddenNebulaOpacity
        }
    }

    /// Keep the panel hugging the SwiftUI content as the transcript grows.
    func resizeToContent() {
        let contentSize = hosting.fittingSize
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        let padding = Layout.nebulaPadding
        let panelSize = NSSize(width: contentSize.width + padding * 2,
                               height: contentSize.height + padding * 2)
        let wasVisible = panel.isVisible
        var frame = panel.frame
        frame.size = panelSize
        panel.setFrame(frame, display: true)

        container.frame = NSRect(origin: .zero, size: panelSize)
        hosting.frame = NSRect(x: padding, y: padding,
                               width: contentSize.width, height: contentSize.height)
        nebulaView.frame = hosting.frame.insetBy(dx: -Layout.nebulaHorizontalBleed,
                                                 dy: -Layout.nebulaVerticalBleed)
        nebulaView.needsDisplay = true

        if wasVisible { positionTopLeft() }
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

    private func prepareLayerAnimation(fromScale scale: CGFloat, nebulaOpacity: Float) {
        container.layer?.removeAllAnimations()
        nebulaView.layer?.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.layer?.transform = CATransform3DMakeScale(scale, scale, 1)
        nebulaView.layer?.opacity = nebulaOpacity
        CATransaction.commit()
    }

    private func animatePanelAlpha(to alpha: CGFloat,
                                   duration: TimeInterval,
                                   timing: CAMediaTimingFunction) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timing
            panel.animator().alphaValue = alpha
        }
    }

    private func animateLayers(duration: TimeInterval,
                               timing: CAMediaTimingFunction,
                               changes: @escaping () -> Void,
                               completion: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(timing)
        CATransaction.setCompletionBlock(completion)
        changes()
        CATransaction.commit()
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
