import AppKit
import SwiftUI

/// Hosts the pill in a borderless, non-activating floating panel pinned to the
/// top-left of the active screen. Non-activating means dictating never steals
/// focus from the app you're typing into.
@MainActor
final class PillWindowController {
    /// The geometry seam keeps placement tests independent from AppKit's
    /// process-global screen list and from a physical multi-monitor setup.
    internal typealias ScreenGeometry = Nuvi.ScreenGeometry

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

    internal let dropZoneOverlay: PillDropZoneOverlay
    internal let pillPanel: PillPanel
    private var panel: NSPanel { pillPanel }
    private let container = NSView()
    private let nebulaView = NebulaGlowView()
    private let hosting: NSHostingView<PillView>
    private let screenProvider: () -> ScreenGeometry?
    private var animationToken = 0
    private var isProgrammaticMove = false

    init(
        controller: DictationController,
        translation: TranslationCoordinator,
        screenProvider: (() -> ScreenGeometry?)? = nil,
        dropZoneOverlay: PillDropZoneOverlay? = nil
    ) {
        self.dropZoneOverlay = dropZoneOverlay ?? PillDropZoneOverlay()
        self.screenProvider = screenProvider ?? { PillWindowController.currentScreenGeometry() }
        hosting = NSHostingView(rootView: PillView(controller: controller, translation: translation))

        let panel = PillPanel(
            contentRect: NSRect(x: 0, y: 0, width: 268, height: 132),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        pillPanel = panel
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        panel.onDragBegan = { [weak self] in
            guard let self else { return }
            guard let screen = self.screenProvider() ?? Self.fallbackScreenGeometry() else { return }
            let safeContentSize = self.currentSafeContentSize()
            let nearest = PillPosition.nearestPreset(
                from: self.panel.frame.origin,
                contentSize: safeContentSize,
                screen: screen,
                threshold: 60.0,
                padding: Layout.nebulaPadding,
                screenInset: Layout.screenInset
            )
            self.dropZoneOverlay.show(on: screen, contentSize: safeContentSize, activePreset: nearest)
        }

        panel.onDragMoved = { [weak self] rawOrigin in
            guard let self else { return rawOrigin }
            guard let screen = self.screenProvider() ?? Self.fallbackScreenGeometry() else { return rawOrigin }
            let safeContentSize = self.currentSafeContentSize()
            let nearest = PillPosition.nearestPreset(
                from: rawOrigin,
                contentSize: safeContentSize,
                screen: screen,
                threshold: 60.0,
                padding: Layout.nebulaPadding,
                screenInset: Layout.screenInset
            )
            if let nearest {
                self.dropZoneOverlay.updateHighlight(activePreset: nearest)
                let targetOrigin = PillPosition.origin(
                    for: nearest,
                    contentSize: safeContentSize,
                    screen: screen,
                    padding: Layout.nebulaPadding,
                    screenInset: Layout.screenInset
                )
                let padding = Layout.nebulaPadding
                let rawCenter = NSPoint(
                    x: rawOrigin.x + padding + safeContentSize.width / 2.0,
                    y: rawOrigin.y + padding + safeContentSize.height / 2.0
                )
                let targetCenter = NSPoint(
                    x: targetOrigin.x + padding + safeContentSize.width / 2.0,
                    y: targetOrigin.y + padding + safeContentSize.height / 2.0
                )
                let dist = hypot(rawCenter.x - targetCenter.x, rawCenter.y - targetCenter.y)
                let threshold: CGFloat = 60.0

                if dist <= 12.0 {
                    return targetOrigin
                } else {
                    let t = (dist - 12.0) / (threshold - 12.0)
                    let pull = 1.0 - (t * t * (3.0 - 2.0 * t))
                    let smoothX = rawOrigin.x + (targetOrigin.x - rawOrigin.x) * pull
                    let smoothY = rawOrigin.y + (targetOrigin.y - rawOrigin.y) * pull
                    return NSPoint(x: smoothX, y: smoothY)
                }
            } else {
                self.dropZoneOverlay.updateHighlight(activePreset: nil)
                return rawOrigin
            }
        }

        panel.onDragEnded = { [weak self] finalOrigin in
            guard let self else { return }
            guard let screen = self.screenProvider() ?? Self.fallbackScreenGeometry() else {
                self.dropZoneOverlay.hide()
                return
            }
            let safeContentSize = self.currentSafeContentSize()
            let nearest = PillPosition.nearestPreset(
                from: finalOrigin,
                contentSize: safeContentSize,
                screen: screen,
                threshold: 60.0,
                padding: Layout.nebulaPadding,
                screenInset: Layout.screenInset
            )

            self.isProgrammaticMove = true
            if let nearest {
                SettingsStore.shared.pillPosition = nearest
                let presetOrigin = PillPosition.origin(
                    for: nearest,
                    contentSize: safeContentSize,
                    screen: screen,
                    padding: Layout.nebulaPadding,
                    screenInset: Layout.screenInset
                )
                self.panel.setFrameOrigin(presetOrigin)
            } else {
                let visible = screen.visibleFrame
                let minContentX = visible.minX + Layout.screenInset
                let maxContentX = max(minContentX, visible.maxX - Layout.screenInset - safeContentSize.width)
                let minContentY = visible.minY + Layout.screenInset
                let maxContentY = max(minContentY, visible.maxY - Layout.screenInset - safeContentSize.height)

                let contentX = finalOrigin.x + Layout.nebulaPadding
                let contentY = finalOrigin.y + Layout.nebulaPadding

                let xRatio: Double = maxContentX > minContentX
                    ? Double((contentX - minContentX) / (maxContentX - minContentX))
                    : 0.0
                let yRatio: Double = maxContentY > minContentY
                    ? Double((maxContentY - contentY) / (maxContentY - minContentY))
                    : 0.0

                let clampedX = min(max(xRatio, 0.0), 1.0)
                let clampedY = min(max(yRatio, 0.0), 1.0)
                let customPosition = PillPosition.custom(xRatio: clampedX, yRatio: clampedY)
                SettingsStore.shared.pillPosition = customPosition

                let customOrigin = PillPosition.origin(
                    for: customPosition,
                    contentSize: safeContentSize,
                    screen: screen,
                    padding: Layout.nebulaPadding,
                    screenInset: Layout.screenInset
                )
                self.panel.setFrameOrigin(customOrigin)
            }
            self.isProgrammaticMove = false
            self.dropZoneOverlay.hide()
        }

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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pillPositionPreferenceDidChange(_:)),
            name: .nuviPillPositionDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        let fromTransform = layer.presentation()?.transform ?? positionAnchoredTransform(Motion.startScale)

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
        dropZoneOverlay.hide()
        guard panel.isVisible, let layer = container.layer else { return }
        animationToken += 1
        let token = animationToken

        let fromOpacity = layer.presentation()?.opacity ?? layer.opacity
        let fromTransform = layer.presentation()?.transform ?? CATransform3DIdentity
        let toTransform = positionAnchoredTransform(Motion.exitScale)

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

    /// A transform that scales `container` while pinning its anchor edge, so growth
    /// reads as expanding from the anchor. Anchored via a translation rather
    /// than mutating the layer's anchorPoint, which AppKit resets on layer-backed views.
    private func positionAnchoredTransform(_ scale: CGFloat) -> CATransform3D {
        let width = container.bounds.width
        let position = SettingsStore.shared.pillPosition
        let dx: CGFloat
        switch position {
        case .topLeft, .leftTop, .leftCenter, .leftBottom, .bottomLeft:
            dx = -(width * (1 - scale)) / 2
        case .topRight, .rightTop, .rightCenter, .rightBottom, .bottomRight:
            dx = +(width * (1 - scale)) / 2
        case .topCenter, .screenCenter, .bottomCenter:
            dx = 0
        case .topCenterLeft, .bottomCenterLeft:
            dx = -(width * (1 - scale)) / 4
        case .topCenterRight, .bottomCenterRight:
            dx = +(width * (1 - scale)) / 4
        case .custom(let xRatio, _):
            let factor = CGFloat(xRatio) - 0.5
            dx = factor * (width * (1 - scale))
        }
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

        guard let screen = screenProvider() ?? Self.fallbackScreenGeometry() else { return }
        let position = SettingsStore.shared.pillPosition
        let origin = PillPosition.origin(
            for: position,
            contentSize: contentSize,
            screen: screen,
            padding: padding,
            screenInset: Layout.screenInset
        )

        isProgrammaticMove = true
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        isProgrammaticMove = false

        container.frame = NSRect(origin: .zero, size: panelSize)
        hosting.frame = NSRect(x: padding, y: padding,
                               width: contentSize.width, height: contentSize.height)
        nebulaView.frame = hosting.frame.insetBy(dx: -Layout.nebulaHorizontalBleed,
                                                 dy: -Layout.nebulaVerticalBleed)
        nebulaView.needsDisplay = true
    }

    private func currentSafeContentSize() -> NSSize {
        let contentSize = hosting.fittingSize
        return NSSize(
            width: contentSize.width > 0 ? contentSize.width : max(1, panel.frame.width - Layout.nebulaPadding * 2),
            height: contentSize.height > 0 ? contentSize.height : max(1, panel.frame.height - Layout.nebulaPadding * 2)
        )
    }

    func updatePosition(animated: Bool = false) {
        guard let screen = screenProvider() ?? Self.fallbackScreenGeometry() else { return }
        let padding = Layout.nebulaPadding
        let safeContentSize = currentSafeContentSize()

        let position = SettingsStore.shared.pillPosition
        let origin = PillPosition.origin(
            for: position,
            contentSize: safeContentSize,
            screen: screen,
            padding: padding,
            screenInset: Layout.screenInset
        )

        isProgrammaticMove = true
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrameOrigin(origin)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    self?.isProgrammaticMove = false
                }
            }
        } else {
            panel.setFrameOrigin(origin)
            isProgrammaticMove = false
        }
    }

    @objc private func pillPositionPreferenceDidChange(_ notification: Notification) {
        guard !isProgrammaticMove else { return }
        guard panel.isVisible else { return }
        dropZoneOverlay.hide()
        updatePosition(animated: true)
    }

    internal static func calculateOrigin(
        for position: PillPosition,
        contentSize: NSSize,
        screen: ScreenGeometry,
        padding: CGFloat = Layout.nebulaPadding,
        screenInset: CGFloat = Layout.screenInset
    ) -> NSPoint {
        PillPosition.origin(
            for: position,
            contentSize: contentSize,
            screen: screen,
            padding: padding,
            screenInset: screenInset
        )
    }

    /// Chooses the display associated with the frontmost window first, then
    /// the display containing the pointer (the reliable active-display signal
    /// for a menu-bar app), and finally safe primary/available-screen fallbacks.
    internal static func selectPlacementScreen(
        frontmostScreen: ScreenGeometry?,
        pointerScreen: ScreenGeometry?,
        mainScreen: ScreenGeometry?,
        availableScreens: [ScreenGeometry]
    ) -> ScreenGeometry? {
        frontmostScreen ?? pointerScreen ?? mainScreen ?? availableScreens.first
    }

    private static func currentScreenGeometry() -> ScreenGeometry? {
        let screens = NSScreen.screens
        let available = screens.map { ScreenGeometry(visibleFrame: $0.visibleFrame, frame: $0.frame) }
        let pointer = NSEvent.mouseLocation
        let pointerScreen = screens.first(where: { $0.frame.contains(pointer) })
            .map { ScreenGeometry(visibleFrame: $0.visibleFrame, frame: $0.frame) }
        let frontmostScreen = (NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen)
            .map { ScreenGeometry(visibleFrame: $0.visibleFrame, frame: $0.frame) }
        let mainScreen = NSScreen.main.map { ScreenGeometry(visibleFrame: $0.visibleFrame, frame: $0.frame) }

        return selectPlacementScreen(
            frontmostScreen: frontmostScreen,
            pointerScreen: pointerScreen,
            mainScreen: mainScreen,
            availableScreens: available
        )
    }

    private static func fallbackScreenGeometry() -> ScreenGeometry? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        return ScreenGeometry(visibleFrame: screen.visibleFrame, frame: screen.frame)
    }

}

/// An NSPanel subclass that implements an event-tracking drag loop for the pill,
/// giving smooth real-time magnetic attraction to preset drop zones without flickering.
@MainActor
internal final class PillPanel: NSPanel {
    var onDragBegan: (@MainActor () -> Void)?
    var onDragMoved: (@MainActor (_ rawOrigin: NSPoint) -> NSPoint)?
    var onDragEnded: (@MainActor (_ finalOrigin: NSPoint) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            trackDrag(startingWith: event)
            return
        }
        super.sendEvent(event)
    }

    private func trackDrag(startingWith initialEvent: NSEvent) {
        let initialMouse = NSEvent.mouseLocation
        let initialOrigin = frame.origin
        var lastOrigin = initialOrigin

        onDragBegan?()

        while true {
            guard let event = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { break }

            if event.type == .leftMouseUp {
                break
            }

            if event.type == .leftMouseDragged {
                let currentMouse = NSEvent.mouseLocation
                let rawOrigin = NSPoint(
                    x: initialOrigin.x + (currentMouse.x - initialMouse.x),
                    y: initialOrigin.y + (currentMouse.y - initialMouse.y)
                )
                let finalOrigin = onDragMoved?(rawOrigin) ?? rawOrigin
                lastOrigin = finalOrigin
                setFrameOrigin(finalOrigin)
            }
        }

        onDragEnded?(lastOrigin)
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
            NuviPalette.nsCharcoal.withAlphaComponent(blob.alpha).cgColor,
            NuviPalette.nsCharcoal.withAlphaComponent(blob.alpha * 0.42).cgColor,
            NuviPalette.nsCharcoal.withAlphaComponent(blob.alpha * 0.12).cgColor,
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
