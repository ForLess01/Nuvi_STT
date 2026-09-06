import AppKit
import Foundation

/// Defines the bounds of a display without coupling to process-global NSScreen.
public struct ScreenGeometry: Equatable, Sendable {
    public let visibleFrame: NSRect
    public let frame: NSRect

    public init(visibleFrame: NSRect, frame: NSRect? = nil) {
        self.visibleFrame = visibleFrame
        self.frame = frame ?? visibleFrame
    }
}

/// Placement anchor for Nuvi's floating dictation pill.
///
/// Supports 17 predefined edge and corner anchors around the active screen's
/// safe visible area, as well as arbitrary custom normalized coordinates
/// resulting from direct window dragging.
public enum PillPosition: Equatable, Hashable, Sendable {
    // Top row (5)
    case topLeft
    case topCenterLeft
    case topCenter
    case topCenterRight
    case topRight

    // Bottom row (5)
    case bottomLeft
    case bottomCenterLeft
    case bottomCenter
    case bottomCenterRight
    case bottomRight

    // Left edge (3)
    case leftTop
    case leftCenter
    case leftBottom

    // Right edge (3)
    case rightTop
    case rightCenter
    case rightBottom

    // Center (1)
    case screenCenter

    // Custom dragged position with normalized coordinates in [0, 1] relative to safe bounds
    case custom(xRatio: Double, yRatio: Double)

    /// Convenient alias for screenCenter.
    public static let center = PillPosition.screenCenter

    /// All 17 preset anchors in reading order.
    public static let allPresets: [PillPosition] = [
        .topLeft,
        .topCenterLeft,
        .topCenter,
        .topCenterRight,
        .topRight,
        .leftTop,
        .leftCenter,
        .leftBottom,
        .screenCenter,
        .rightTop,
        .rightCenter,
        .rightBottom,
        .bottomLeft,
        .bottomCenterLeft,
        .bottomCenter,
        .bottomCenterRight,
        .bottomRight
    ]

    /// Normalized coordinates (xRatio: 0...1, yRatio: 0...1) where (0, 0) is top-left
    /// and (1, 1) is bottom-right within the display's safe visible frame.
    public var normalizedCoordinates: (xRatio: Double, yRatio: Double) {
        switch self {
        // Top row (yRatio: 0.0)
        case .topLeft: return (0.0, 0.0)
        case .topCenterLeft: return (0.25, 0.0)
        case .topCenter: return (0.50, 0.0)
        case .topCenterRight: return (0.75, 0.0)
        case .topRight: return (1.0, 0.0)

        // Bottom row (yRatio: 1.0)
        case .bottomLeft: return (0.0, 1.0)
        case .bottomCenterLeft: return (0.25, 1.0)
        case .bottomCenter: return (0.50, 1.0)
        case .bottomCenterRight: return (0.75, 1.0)
        case .bottomRight: return (1.0, 1.0)

        // Left edge (xRatio: 0.0)
        case .leftTop: return (0.0, 0.25)
        case .leftCenter: return (0.0, 0.50)
        case .leftBottom: return (0.0, 0.75)

        // Right edge (xRatio: 1.0)
        case .rightTop: return (1.0, 0.25)
        case .rightCenter: return (1.0, 0.50)
        case .rightBottom: return (1.0, 0.75)

        // Center
        case .screenCenter: return (0.50, 0.50)

        // Custom
        case .custom(let x, let y):
            let clampedX = min(max(x, 0.0), 1.0)
            let clampedY = min(max(y, 0.0), 1.0)
            return (clampedX, clampedY)
        }
    }

    public var xRatio: Double { normalizedCoordinates.xRatio }
    public var yRatio: Double { normalizedCoordinates.yRatio }

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    // MARK: - Origin Calculation

    /// Calculates the origin of the hosting window panel for the given pill position.
    ///
    /// Growth behavior:
    /// - Left-anchored positions stay fixed on the left and expand rightwards.
    /// - Right-anchored positions stay fixed on the right and expand leftwards.
    /// - Center-anchored positions expand symmetrically from the horizontal center.
    /// - Top-anchored positions keep top margin fixed.
    /// - Bottom-anchored positions keep bottom margin fixed.
    /// - Clamps to safe visible bounds so the pill never clips off-screen.
    public static func origin(
        for position: PillPosition,
        contentSize: NSSize,
        screen: ScreenGeometry,
        padding: CGFloat = 34.0,
        screenInset: CGFloat = 22.0
    ) -> NSPoint {
        let visible = screen.visibleFrame

        // Safe bounds for the content within the visible frame
        let minContentX = visible.minX + screenInset
        let maxContentX = max(minContentX, visible.maxX - screenInset - contentSize.width)

        let minContentY = visible.minY + screenInset
        let maxContentY = max(minContentY, visible.maxY - screenInset - contentSize.height)

        let contentX: CGFloat
        let contentY: CGFloat

        // Horizontal placement
        switch position {
        case .topLeft, .leftTop, .leftCenter, .leftBottom, .bottomLeft:
            // Left-anchored: fixed left margin, grows rightward
            contentX = minContentX

        case .topRight, .rightTop, .rightCenter, .rightBottom, .bottomRight:
            // Right-anchored: fixed right margin, grows leftward
            contentX = maxContentX

        case .topCenter, .screenCenter, .bottomCenter:
            // Center-anchored: expands symmetrically from center
            contentX = visible.midX - contentSize.width / 2.0

        case .topCenterLeft, .bottomCenterLeft:
            contentX = minContentX + (maxContentX - minContentX) * 0.25

        case .topCenterRight, .bottomCenterRight:
            contentX = minContentX + (maxContentX - minContentX) * 0.75

        case .custom(let rx, _):
            let clampedRatio = CGFloat(min(max(rx, 0.0), 1.0))
            contentX = minContentX + (maxContentX - minContentX) * clampedRatio
        }

        // Vertical placement
        switch position {
        case .topLeft, .topCenterLeft, .topCenter, .topCenterRight, .topRight:
            // Top-anchored: fixed top margin
            contentY = maxContentY

        case .bottomLeft, .bottomCenterLeft, .bottomCenter, .bottomCenterRight, .bottomRight:
            // Bottom-anchored: fixed bottom margin
            contentY = minContentY

        case .leftCenter, .screenCenter, .rightCenter:
            // Center-anchored: expands symmetrically vertically
            contentY = visible.midY - contentSize.height / 2.0

        case .leftTop, .rightTop:
            // 25% down from top
            contentY = maxContentY - (maxContentY - minContentY) * 0.25

        case .leftBottom, .rightBottom:
            // 75% down from top (25% up from bottom)
            contentY = maxContentY - (maxContentY - minContentY) * 0.75

        case .custom(_, let ry):
            let clampedRatio = CGFloat(min(max(ry, 0.0), 1.0))
            contentY = maxContentY - (maxContentY - minContentY) * clampedRatio
        }

        // Always clamp content origin to safe bounds
        let clampedContentX = min(max(contentX, minContentX), maxContentX)
        let clampedContentY = min(max(contentY, minContentY), maxContentY)

        // The panel origin is offset by padding because content is inset by padding
        return NSPoint(x: clampedContentX - padding, y: clampedContentY - padding)
    }

    public func origin(
        contentSize: NSSize,
        screen: ScreenGeometry,
        padding: CGFloat = 34.0,
        screenInset: CGFloat = 22.0
    ) -> NSPoint {
        Self.origin(
            for: self,
            contentSize: contentSize,
            screen: screen,
            padding: padding,
            screenInset: screenInset
        )
    }

    // MARK: - Snap Calculation

    /// Returns the closest preset anchor if within the given threshold; otherwise returns nil.
    public static func nearestPreset(
        from origin: NSPoint,
        contentSize: NSSize,
        screen: ScreenGeometry,
        threshold: CGFloat = 60.0,
        padding: CGFloat = 34.0,
        screenInset: CGFloat = 22.0
    ) -> PillPosition? {
        var closestPreset: PillPosition?
        var minDistance: CGFloat = .greatestFiniteMagnitude

        let candidateCenter = NSPoint(
            x: origin.x + padding + contentSize.width / 2.0,
            y: origin.y + padding + contentSize.height / 2.0
        )

        for preset in allPresets {
            let presetOrigin = self.origin(
                for: preset,
                contentSize: contentSize,
                screen: screen,
                padding: padding,
                screenInset: screenInset
            )
            let presetCenter = NSPoint(
                x: presetOrigin.x + padding + contentSize.width / 2.0,
                y: presetOrigin.y + padding + contentSize.height / 2.0
            )
            let distance = hypot(candidateCenter.x - presetCenter.x, candidateCenter.y - presetCenter.y)
            if distance < minDistance {
                minDistance = distance
                closestPreset = preset
            }
        }

        if minDistance <= threshold {
            return closestPreset
        }
        return nil
    }

    /// Snaps a candidate panel origin to the closest preset anchor if within threshold;
    /// otherwise returns a `.custom(xRatio: ..., yRatio: ...)` position.
    public static func snap(
        from origin: NSPoint,
        contentSize: NSSize,
        screen: ScreenGeometry,
        threshold: CGFloat = 60.0,
        padding: CGFloat = 34.0,
        screenInset: CGFloat = 22.0
    ) -> PillPosition {
        if let nearest = nearestPreset(
            from: origin,
            contentSize: contentSize,
            screen: screen,
            threshold: threshold,
            padding: padding,
            screenInset: screenInset
        ) {
            return nearest
        }

        // Outside magnetic threshold — compute normalized custom coordinates
        let visible = screen.visibleFrame
        let minContentX = visible.minX + screenInset
        let maxContentX = max(minContentX, visible.maxX - screenInset - contentSize.width)
        let minContentY = visible.minY + screenInset
        let maxContentY = max(minContentY, visible.maxY - screenInset - contentSize.height)

        let contentX = origin.x + padding
        let contentY = origin.y + padding

        let xRatio: Double
        if maxContentX > minContentX {
            xRatio = Double((contentX - minContentX) / (maxContentX - minContentX))
        } else {
            xRatio = 0.0
        }

        let yRatio: Double
        if maxContentY > minContentY {
            // yRatio = 0.0 is top (maxContentY), yRatio = 1.0 is bottom (minContentY)
            yRatio = Double((maxContentY - contentY) / (maxContentY - minContentY))
        } else {
            yRatio = 0.0
        }

        let clampedX = min(max(xRatio, 0.0), 1.0)
        let clampedY = min(max(yRatio, 0.0), 1.0)
        return .custom(xRatio: clampedX, yRatio: clampedY)
    }

    // MARK: - String Serialization

    public var serializedString: String {
        switch self {
        case .topLeft: return "topLeft"
        case .topCenterLeft: return "topCenterLeft"
        case .topCenter: return "topCenter"
        case .topCenterRight: return "topCenterRight"
        case .topRight: return "topRight"
        case .bottomLeft: return "bottomLeft"
        case .bottomCenterLeft: return "bottomCenterLeft"
        case .bottomCenter: return "bottomCenter"
        case .bottomCenterRight: return "bottomCenterRight"
        case .bottomRight: return "bottomRight"
        case .leftTop: return "leftTop"
        case .leftCenter: return "leftCenter"
        case .leftBottom: return "leftBottom"
        case .rightTop: return "rightTop"
        case .rightCenter: return "rightCenter"
        case .rightBottom: return "rightBottom"
        case .screenCenter: return "screenCenter"
        case .custom(let xRatio, let yRatio):
            return String(format: "custom:%.4f,%.4f", locale: Locale(identifier: "en_US_POSIX"), xRatio, yRatio)
        }
    }

    public init?(serializedString: String) {
        if serializedString.hasPrefix("custom:") {
            let components = serializedString.dropFirst("custom:".count).split(separator: ",")
            guard components.count == 2,
                  let x = Double(components[0].trimmingCharacters(in: .whitespaces)),
                  let y = Double(components[1].trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            self = .custom(xRatio: x, yRatio: y)
            return
        }

        switch serializedString {
        case "topLeft": self = .topLeft
        case "topCenterLeft": self = .topCenterLeft
        case "topCenter": self = .topCenter
        case "topCenterRight": self = .topCenterRight
        case "topRight": self = .topRight
        case "bottomLeft": self = .bottomLeft
        case "bottomCenterLeft": self = .bottomCenterLeft
        case "bottomCenter": self = .bottomCenter
        case "bottomCenterRight": self = .bottomCenterRight
        case "bottomRight": self = .bottomRight
        case "leftTop": self = .leftTop
        case "leftCenter": self = .leftCenter
        case "leftBottom": self = .leftBottom
        case "rightTop": self = .rightTop
        case "rightCenter": self = .rightCenter
        case "rightBottom": self = .rightBottom
        case "screenCenter", "center": self = .screenCenter
        default: return nil
        }
    }

    // MARK: - Display Names

    public var displayNameEn: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topCenterLeft: return "Top Center-Left"
        case .topCenter: return "Top Center"
        case .topCenterRight: return "Top Center-Right"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomCenterLeft: return "Bottom Center-Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomCenterRight: return "Bottom Center-Right"
        case .bottomRight: return "Bottom Right"
        case .leftTop: return "Left Top"
        case .leftCenter: return "Left Center"
        case .leftBottom: return "Left Bottom"
        case .rightTop: return "Right Top"
        case .rightCenter: return "Right Center"
        case .rightBottom: return "Right Bottom"
        case .screenCenter: return "Screen Center"
        case .custom: return "Custom (dragged)"
        }
    }

    public var displayNameEs: String {
        switch self {
        case .topLeft: return "Superior izquierda"
        case .topCenterLeft: return "Superior centro-izquierda"
        case .topCenter: return "Superior centro"
        case .topCenterRight: return "Superior centro-derecha"
        case .topRight: return "Superior derecha"
        case .bottomLeft: return "Inferior izquierda"
        case .bottomCenterLeft: return "Inferior centro-izquierda"
        case .bottomCenter: return "Inferior centro"
        case .bottomCenterRight: return "Inferior centro-derecha"
        case .bottomRight: return "Inferior derecha"
        case .leftTop: return "Izquierda superior"
        case .leftCenter: return "Izquierda centro"
        case .leftBottom: return "Izquierda inferior"
        case .rightTop: return "Derecha superior"
        case .rightCenter: return "Derecha centro"
        case .rightBottom: return "Derecha inferior"
        case .screenCenter: return "Centro de la pantalla"
        case .custom: return "Personalizada (arrastrada)"
        }
    }

    public var displayName: String {
        tr(displayNameEn, displayNameEs)
    }
}

// MARK: - Codable & String Conversions

extension PillPosition: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let position = PillPosition(serializedString: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown pill position: \(raw)"
            )
        }
        self = position
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(serializedString)
    }
}

extension PillPosition: LosslessStringConvertible, CustomStringConvertible {
    public var description: String { serializedString }
    public init?(_ description: String) { self.init(serializedString: description) }
}
