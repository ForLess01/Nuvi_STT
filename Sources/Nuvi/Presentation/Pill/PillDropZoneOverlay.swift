import AppKit
import QuartzCore

/// Renders ghost capsule drop zones representing the 17 magnetic snap anchors
/// across the active display while the floating pill is dragged.
@MainActor
public final class PillDropZoneOverlay: NSPanel {
    public enum Appearance {
        public static let defaultWidth: CGFloat = 140
        public static let defaultHeight: CGFloat = 42

        public static let defaultBackground = NSColor(white: 0.1, alpha: 0.45)
        public static let defaultBorder = NSColor(white: 1.0, alpha: 0.2)
        public static let defaultBorderWidth: CGFloat = 1.0

        public static let highlightedBackground = NSColor(white: 0.15, alpha: 0.75)
        public static let highlightedBorder = NSColor(red: 0.65, green: 0.6, blue: 0.95, alpha: 0.9)
        public static let highlightedBorderWidth: CGFloat = 2.0
        public static let highlightedGlow = NSColor(red: 0.65, green: 0.6, blue: 0.95, alpha: 0.6)
        public static let highlightedScale: CGFloat = 1.05

        public static let showDuration: TimeInterval = 0.15
        public static let hideDuration: TimeInterval = 0.18
        public static let highlightDuration: TimeInterval = 0.12
    }

    public private(set) var activePreset: PillPosition?
    public private(set) var currentScreen: ScreenGeometry?
    public private(set) var currentContentSize: NSSize?
    public private(set) var isHiding: Bool = false

    private let containerView = DropZoneOverlayView()
    private var dropZoneLayers: [PillPosition: DropZoneCapsuleLayer] = [:]
    private var animationToken = 0

    public init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        alphaValue = 0.0

        setupLayers()
    }


    private func setupLayers() {
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = false
        contentView = containerView

        guard let rootLayer = containerView.layer else { return }

        for preset in PillPosition.allPresets {
            let layer = DropZoneCapsuleLayer(preset: preset)
            rootLayer.addSublayer(layer)
            dropZoneLayers[preset] = layer
        }
    }

    // MARK: - API

    /// Shows the drop zones overlay on the given screen geometry with an optional initial highlighted preset.
    public func show(
        on screen: ScreenGeometry,
        contentSize: NSSize,
        activePreset: PillPosition? = nil,
        animated: Bool = true
    ) {
        isHiding = false
        currentScreen = screen
        currentContentSize = contentSize
        layoutDropZones(screen: screen, contentSize: contentSize)
        updateHighlight(activePreset: activePreset, animated: false)

        guard !isVisible || alphaValue < 1.0 else { return }

        animationToken += 1
        let token = animationToken

        orderFrontRegardless()
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Appearance.showDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1.0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.animationToken == token else { return }
                    self.alphaValue = 1.0
                }
            }
        } else {
            alphaValue = 1.0
        }
    }

    /// Dynamically lights up the closest preset capsule while dragging, returning other zones to default.
    public func updateHighlight(activePreset: PillPosition?, animated: Bool = true) {
        self.activePreset = activePreset
        for (preset, layer) in dropZoneLayers {
            let highlighted = (preset == activePreset)
            layer.setHighlighted(highlighted, animated: animated)
        }
    }

    /// Smoothly fades out and hides the overlay window.
    public func hide(animated: Bool = true) {
        isHiding = true
        guard isVisible, alphaValue > 0 else {
            orderOut(nil)
            alphaValue = 0.0
            isHiding = false
            return
        }

        animationToken += 1
        let token = animationToken

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Appearance.hideDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().alphaValue = 0.0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.animationToken == token else { return }
                    self.orderOut(nil)
                    self.alphaValue = 0.0
                    self.isHiding = false
                }
            }
        } else {
            alphaValue = 0.0
            orderOut(nil)
            isHiding = false
        }
    }

    // MARK: - Layout & Geometry

    private func layoutDropZones(screen: ScreenGeometry, contentSize: NSSize) {
        let targetFrame = (screen.frame.width > 0 && screen.frame.height > 0)
            ? screen.frame
            : screen.visibleFrame

        setFrame(targetFrame, display: true)
        containerView.frame = NSRect(origin: .zero, size: targetFrame.size)

        let safeSize = Self.effectiveDropZoneSize(from: contentSize)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for preset in PillPosition.allPresets {
            guard let layer = dropZoneLayers[preset] else { continue }
            let screenRect = Self.dropZoneRect(for: preset, contentSize: safeSize, screen: screen)
            let windowRect = NSRect(
                x: screenRect.minX - targetFrame.minX,
                y: screenRect.minY - targetFrame.minY,
                width: screenRect.width,
                height: screenRect.height
            )

            layer.bounds = CGRect(x: 0, y: 0, width: windowRect.width, height: windowRect.height)
            layer.position = CGPoint(x: windowRect.midX, y: windowRect.midY)
            layer.cornerRadius = windowRect.height / 2.0
        }
        CATransaction.commit()
    }

    public static func effectiveDropZoneSize(from contentSize: NSSize) -> NSSize {
        let width = contentSize.width > 0 ? contentSize.width : Appearance.defaultWidth
        let height = contentSize.height > 0 ? contentSize.height : Appearance.defaultHeight
        return NSSize(width: width, height: height)
    }

    /// Calculates the on-screen drop zone rect for a preset given screen geometry and content size.
    public static func dropZoneRect(
        for preset: PillPosition,
        contentSize: NSSize,
        screen: ScreenGeometry,
        padding: CGFloat = 34.0,
        screenInset: CGFloat = 22.0
    ) -> NSRect {
        let safeSize = effectiveDropZoneSize(from: contentSize)
        let origin = PillPosition.origin(
            for: preset,
            contentSize: safeSize,
            screen: screen,
            padding: padding,
            screenInset: screenInset
        )
        return NSRect(
            x: origin.x + padding,
            y: origin.y + padding,
            width: safeSize.width,
            height: safeSize.height
        )
    }

    // MARK: - Test Inspection Helpers

    public func isPresetHighlighted(_ preset: PillPosition) -> Bool {
        dropZoneLayers[preset]?.isHighlighted ?? false
    }

    public func dropZoneRectOnScreen(for preset: PillPosition) -> NSRect? {
        guard let screen = currentScreen, let size = currentContentSize else { return nil }
        return Self.dropZoneRect(for: preset, contentSize: size, screen: screen)
    }

    public func dropZoneWindowRect(for preset: PillPosition) -> NSRect? {
        guard let layer = dropZoneLayers[preset] else { return nil }
        let bounds = layer.bounds
        let position = layer.position
        return NSRect(
            x: position.x - bounds.width / 2.0,
            y: position.y - bounds.height / 2.0,
            width: bounds.width,
            height: bounds.height
        )
    }
}

// MARK: - Supporting Views & Layers

private final class DropZoneOverlayView: NSView {
    override var isFlipped: Bool { false }
}

final class DropZoneCapsuleLayer: CALayer {
    let preset: PillPosition
    private(set) var isHighlighted: Bool = false

    init(preset: PillPosition) {
        self.preset = preset
        super.init()
        masksToBounds = false
        backgroundColor = PillDropZoneOverlay.Appearance.defaultBackground.cgColor
        borderColor = PillDropZoneOverlay.Appearance.defaultBorder.cgColor
        borderWidth = PillDropZoneOverlay.Appearance.defaultBorderWidth
        shadowColor = NSColor.clear.cgColor
        shadowOpacity = 0.0
        shadowOffset = .zero
        shadowRadius = 8.0
        zPosition = 0.0
    }

    override init(layer: Any) {
        guard let other = layer as? DropZoneCapsuleLayer else {
            fatalError("init(layer:) called with unknown layer")
        }
        self.preset = other.preset
        self.isHighlighted = other.isHighlighted
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setHighlighted(_ highlighted: Bool, animated: Bool = true) {
        guard isHighlighted != highlighted else { return }
        isHighlighted = highlighted

        let targetBg = highlighted
            ? PillDropZoneOverlay.Appearance.highlightedBackground.cgColor
            : PillDropZoneOverlay.Appearance.defaultBackground.cgColor
        let targetBorder = highlighted
            ? PillDropZoneOverlay.Appearance.highlightedBorder.cgColor
            : PillDropZoneOverlay.Appearance.defaultBorder.cgColor
        let targetBorderWidth = highlighted
            ? PillDropZoneOverlay.Appearance.highlightedBorderWidth
            : PillDropZoneOverlay.Appearance.defaultBorderWidth
        let targetTransform = highlighted
            ? CATransform3DMakeScale(
                PillDropZoneOverlay.Appearance.highlightedScale,
                PillDropZoneOverlay.Appearance.highlightedScale,
                1.0
            )
            : CATransform3DIdentity
        let targetShadowColor = highlighted
            ? PillDropZoneOverlay.Appearance.highlightedGlow.cgColor
            : NSColor.clear.cgColor
        let targetShadowOpacity: Float = highlighted ? 1.0 : 0.0
        let targetZPosition: CGFloat = highlighted ? 10.0 : 0.0

        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(PillDropZoneOverlay.Appearance.highlightDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            backgroundColor = targetBg
            borderColor = targetBorder
            borderWidth = targetBorderWidth
            transform = targetTransform
            shadowColor = targetShadowColor
            shadowOpacity = targetShadowOpacity
            zPosition = targetZPosition
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backgroundColor = targetBg
            borderColor = targetBorder
            borderWidth = targetBorderWidth
            transform = targetTransform
            shadowColor = targetShadowColor
            shadowOpacity = targetShadowOpacity
            zPosition = targetZPosition
            CATransaction.commit()
        }
    }
}
