import AppKit
import XCTest
@testable import Nuvi

final class PillPositionTests: XCTestCase {
    private let standardScreen = ScreenGeometry(
        visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900)
    )
    private let contentSize = NSSize(width: 200, height: 40)
    private let padding: CGFloat = 34
    private let screenInset: CGFloat = 22

    // MARK: - 1. Preset Count & Uniqueness

    func testAll17PresetsExistAndHaveUniqueCoordinates() {
        XCTAssertEqual(PillPosition.allPresets.count, 17)

        var coordinatePairs = Set<String>()
        for preset in PillPosition.allPresets {
            let key = String(format: "%.2f,%.2f", preset.xRatio, preset.yRatio)
            XCTAssertFalse(
                coordinatePairs.contains(key),
                "Duplicate normalized coordinate pair found for \(preset): \(key)"
            )
            coordinatePairs.insert(key)
        }
        XCTAssertEqual(coordinatePairs.count, 17)
    }

    // MARK: - 2. Origin Calculations for all 17 Presets

    func testAll17PresetOriginCalculations() {
        // Safe content area:
        // minContentX = 22, maxContentX = 1440 - 22 - 200 = 1218 (span = 1196)
        // minContentY = 22, maxContentY = 900 - 22 - 40 = 838 (span = 816)
        // Panel origin = contentOrigin - padding(34)

        let testCases: [(PillPosition, NSPoint)] = [
            // Top row
            (.topLeft, NSPoint(x: 22 - padding, y: 838 - padding)),
            (.topCenterLeft, NSPoint(x: 22 + 1196 * 0.25 - padding, y: 838 - padding)),
            (.topCenter, NSPoint(x: 720 - 100 - padding, y: 838 - padding)),
            (.topCenterRight, NSPoint(x: 22 + 1196 * 0.75 - padding, y: 838 - padding)),
            (.topRight, NSPoint(x: 1218 - padding, y: 838 - padding)),

            // Left edge
            (.leftTop, NSPoint(x: 22 - padding, y: 838 - 816 * 0.25 - padding)),
            (.leftCenter, NSPoint(x: 22 - padding, y: 450 - 20 - padding)),
            (.leftBottom, NSPoint(x: 22 - padding, y: 838 - 816 * 0.75 - padding)),

            // Center
            (.screenCenter, NSPoint(x: 720 - 100 - padding, y: 450 - 20 - padding)),

            // Right edge
            (.rightTop, NSPoint(x: 1218 - padding, y: 838 - 816 * 0.25 - padding)),
            (.rightCenter, NSPoint(x: 1218 - padding, y: 450 - 20 - padding)),
            (.rightBottom, NSPoint(x: 1218 - padding, y: 838 - 816 * 0.75 - padding)),

            // Bottom row
            (.bottomLeft, NSPoint(x: 22 - padding, y: 22 - padding)),
            (.bottomCenterLeft, NSPoint(x: 22 + 1196 * 0.25 - padding, y: 22 - padding)),
            (.bottomCenter, NSPoint(x: 720 - 100 - padding, y: 22 - padding)),
            (.bottomCenterRight, NSPoint(x: 22 + 1196 * 0.75 - padding, y: 22 - padding)),
            (.bottomRight, NSPoint(x: 1218 - padding, y: 22 - padding))
        ]

        for (preset, expectedOrigin) in testCases {
            let actual = PillPosition.origin(
                for: preset,
                contentSize: contentSize,
                screen: standardScreen,
                padding: padding,
                screenInset: screenInset
            )
            XCTAssertEqual(
                actual.x, expectedOrigin.x, accuracy: 0.001,
                "X mismatch for \(preset): expected \(expectedOrigin.x), got \(actual.x)"
            )
            XCTAssertEqual(
                actual.y, expectedOrigin.y, accuracy: 0.001,
                "Y mismatch for \(preset): expected \(expectedOrigin.y), got \(actual.y)"
            )
        }
    }

    // MARK: - 3. Growth Stability

    func testLeftAnchoredPositionsStayFixedOnLeftAndExpandRightwards() {
        let leftPresets: [PillPosition] = [
            .topLeft, .leftTop, .leftCenter, .leftBottom, .bottomLeft
        ]
        let smallSize = NSSize(width: 120, height: 40)
        let largeSize = NSSize(width: 380, height: 40)

        for preset in leftPresets {
            let smallOrigin = PillPosition.origin(
                for: preset, contentSize: smallSize, screen: standardScreen,
                padding: padding, screenInset: screenInset
            )
            let largeOrigin = PillPosition.origin(
                for: preset, contentSize: largeSize, screen: standardScreen,
                padding: padding, screenInset: screenInset
            )

            // Left edge of content = origin.x + padding must be constant
            XCTAssertEqual(
                smallOrigin.x, largeOrigin.x, accuracy: 0.001,
                "Left-anchored preset \(preset) shifted origin.x on width change"
            )
            XCTAssertEqual(smallOrigin.x + padding, screenInset, accuracy: 0.001)
        }
    }

    func testRightAnchoredPositionsStayFixedOnRightAndExpandLeftwards() {
        let rightPresets: [PillPosition] = [
            .topRight, .rightTop, .rightCenter, .rightBottom, .bottomRight
        ]
        let smallSize = NSSize(width: 120, height: 40)
        let largeSize = NSSize(width: 380, height: 40)
        let expectedRightEdge = standardScreen.visibleFrame.maxX - screenInset

        for preset in rightPresets {
            let smallOrigin = PillPosition.origin(
                for: preset, contentSize: smallSize, screen: standardScreen,
                padding: padding, screenInset: screenInset
            )
            let largeOrigin = PillPosition.origin(
                for: preset, contentSize: largeSize, screen: standardScreen,
                padding: padding, screenInset: screenInset
            )

            let smallRight = smallOrigin.x + padding + smallSize.width
            let largeRight = largeOrigin.x + padding + largeSize.width

            XCTAssertEqual(
                smallRight, largeRight, accuracy: 0.001,
                "Right-anchored preset \(preset) drifted right edge on width change"
            )
            XCTAssertEqual(smallRight, expectedRightEdge, accuracy: 0.001)
        }
    }

    func testCenterAnchoredPositionsExpandSymmetricallyFromCenter() {
        let centerPresets: [PillPosition] = [
            .topCenter, .screenCenter, .bottomCenter
        ]
        let smallSize = NSSize(width: 140, height: 40)
        let largeSize = NSSize(width: 320, height: 40)
        let expectedMidX = standardScreen.visibleFrame.midX

        for preset in centerPresets {
            let smallOrigin = PillPosition.origin(
                for: preset, contentSize: smallSize, screen: standardScreen,
                padding: padding, screenInset: screenInset
            )
            let largeOrigin = PillPosition.origin(
                for: preset, contentSize: largeSize, screen: standardScreen,
                padding: padding, screenInset: screenInset
            )

            let smallCenter = smallOrigin.x + padding + smallSize.width / 2.0
            let largeCenter = largeOrigin.x + padding + largeSize.width / 2.0

            XCTAssertEqual(
                smallCenter, largeCenter, accuracy: 0.001,
                "Center-anchored preset \(preset) center drifted on width change"
            )
            XCTAssertEqual(smallCenter, expectedMidX, accuracy: 0.001)
        }
    }

    func testTopAnchoredPositionsKeepTopMarginFixed() {
        let topPresets: [PillPosition] = [
            .topLeft, .topCenterLeft, .topCenter, .topCenterRight, .topRight
        ]
        let smallSize = NSSize(width: 200, height: 32)
        let largeSize = NSSize(width: 200, height: 68)
        let expectedTop = standardScreen.visibleFrame.maxY - screenInset

        for preset in topPresets {
            let smallOrigin = PillPosition.origin(
                for: preset, contentSize: smallSize, screen: standardScreen,
                padding: padding, screenInset: screenInset
            )
            let largeOrigin = PillPosition.origin(
                for: preset, contentSize: largeSize, screen: standardScreen,
                padding: padding, screenInset: screenInset
            )

            let smallTop = smallOrigin.y + padding + smallSize.height
            let largeTop = largeOrigin.y + padding + largeSize.height

            XCTAssertEqual(
                smallTop, largeTop, accuracy: 0.001,
                "Top-anchored preset \(preset) top margin shifted on height change"
            )
            XCTAssertEqual(smallTop, expectedTop, accuracy: 0.001)
        }
    }

    func testBottomAnchoredPositionsKeepBottomMarginFixed() {
        let bottomPresets: [PillPosition] = [
            .bottomLeft, .bottomCenterLeft, .bottomCenter, .bottomCenterRight, .bottomRight
        ]
        let smallSize = NSSize(width: 200, height: 32)
        let largeSize = NSSize(width: 200, height: 68)
        let expectedBottom = standardScreen.visibleFrame.minY + screenInset

        for preset in bottomPresets {
            let smallOrigin = PillPosition.origin(
                for: preset, contentSize: smallSize, screen: standardScreen,
                padding: padding, screenInset: screenInset
            )
            let largeOrigin = PillPosition.origin(
                for: preset, contentSize: largeSize, screen: standardScreen,
                padding: padding, screenInset: screenInset
            )

            let smallBottom = smallOrigin.y + padding
            let largeBottom = largeOrigin.y + padding

            XCTAssertEqual(
                smallBottom, largeBottom, accuracy: 0.001,
                "Bottom-anchored preset \(preset) bottom margin shifted on height change"
            )
            XCTAssertEqual(smallBottom, expectedBottom, accuracy: 0.001)
        }
    }

    // MARK: - 4. Snap Magnetism

    func testSnapMagnetismNearPresetsSnapsToPreset() {
        let topLeftOrigin = PillPosition.origin(
            for: .topLeft, contentSize: contentSize, screen: standardScreen,
            padding: padding, screenInset: screenInset
        )

        // Offset by 20 points (within 36pt threshold)
        let nearTopLeft = NSPoint(x: topLeftOrigin.x + 15, y: topLeftOrigin.y - 12)
        let snapped = PillPosition.snap(
            from: nearTopLeft, contentSize: contentSize, screen: standardScreen,
            threshold: 36.0, padding: padding, screenInset: screenInset
        )
        XCTAssertEqual(snapped, .topLeft)

        // Test bottom right snap
        let bottomRightOrigin = PillPosition.origin(
            for: .bottomRight, contentSize: contentSize, screen: standardScreen,
            padding: padding, screenInset: screenInset
        )
        let nearBottomRight = NSPoint(x: bottomRightOrigin.x - 20, y: bottomRightOrigin.y + 15)
        let snappedBR = PillPosition.snap(
            from: nearBottomRight, contentSize: contentSize, screen: standardScreen,
            threshold: 36.0, padding: padding, screenInset: screenInset
        )
        XCTAssertEqual(snappedBR, .bottomRight)

        // Test center snap
        let centerOrigin = PillPosition.origin(
            for: .screenCenter, contentSize: contentSize, screen: standardScreen,
            padding: padding, screenInset: screenInset
        )
        let nearCenter = NSPoint(x: centerOrigin.x + 10, y: centerOrigin.y + 10)
        let snappedCenter = PillPosition.snap(
            from: nearCenter, contentSize: contentSize, screen: standardScreen,
            threshold: 36.0, padding: padding, screenInset: screenInset
        )
        XCTAssertEqual(snappedCenter, .screenCenter)
    }

    func testSnapMagnetismWithDefault60PtThreshold() {
        let topLeftOrigin = PillPosition.origin(
            for: .topLeft, contentSize: contentSize, screen: standardScreen,
            padding: padding, screenInset: screenInset
        )

        // Point is 48pt away from topLeft: 36pt threshold misses it, but 60pt default catches it
        let point48PtAway = NSPoint(x: topLeftOrigin.x + 30, y: topLeftOrigin.y - 37.4)
        let snappedWithDefault = PillPosition.snap(
            from: point48PtAway, contentSize: contentSize, screen: standardScreen,
            padding: padding, screenInset: screenInset
        )
        XCTAssertEqual(snappedWithDefault, .topLeft)

        let nearestWithDefault = PillPosition.nearestPreset(
            from: point48PtAway, contentSize: contentSize, screen: standardScreen,
            padding: padding, screenInset: screenInset
        )
        XCTAssertEqual(nearestWithDefault, .topLeft)

        // Beyond 60pt (> 60pt away) -> becomes custom
        let point70PtAway = NSPoint(x: topLeftOrigin.x + 50, y: topLeftOrigin.y - 50)
        let snappedBeyond = PillPosition.snap(
            from: point70PtAway, contentSize: contentSize, screen: standardScreen,
            padding: padding, screenInset: screenInset
        )
        XCTAssertTrue(snappedBeyond.isCustom)
    }

    func testSnapMagnetismFarFromPresetsBecomesCustom() {
        // Choose a point roughly 35% across and 40% down, far from any preset
        let testPoint = NSPoint(x: 450, y: 520)
        let snapped = PillPosition.snap(
            from: testPoint, contentSize: contentSize, screen: standardScreen,
            threshold: 36.0, padding: padding, screenInset: screenInset
        )

        XCTAssertTrue(snapped.isCustom)
        if case .custom(let rx, let ry) = snapped {
            XCTAssertGreaterThan(rx, 0.0)
            XCTAssertLessThan(rx, 1.0)
            XCTAssertGreaterThan(ry, 0.0)
            XCTAssertLessThan(ry, 1.0)
        }

        // Roundtrip check: calculating origin from the custom position recovers testPoint
        let recovered = PillPosition.origin(
            for: snapped, contentSize: contentSize, screen: standardScreen,
            padding: padding, screenInset: screenInset
        )
        XCTAssertEqual(recovered.x, testPoint.x, accuracy: 0.5)
        XCTAssertEqual(recovered.y, testPoint.y, accuracy: 0.5)
    }

    // MARK: - 5. Screen Bounds Clamping

    func testClampingWithGiantContentStaysOnScreen() {
        let giantSize = NSSize(width: 2_000, height: 1_200)
        let origin = PillPosition.origin(
            for: .topLeft, contentSize: giantSize, screen: standardScreen,
            padding: padding, screenInset: screenInset
        )

        // Content origin = origin + padding
        let contentX = origin.x + padding
        let contentY = origin.y + padding

        XCTAssertEqual(contentX, screenInset)
        XCTAssertEqual(contentY, screenInset)
    }

    func testClampingWithOutOfBoundsCustomCoordinates() {
        let negativeCustom = PillPosition.custom(xRatio: -0.5, yRatio: -0.3)
        let negOrigin = PillPosition.origin(
            for: negativeCustom, contentSize: contentSize, screen: standardScreen,
            padding: padding, screenInset: screenInset
        )
        let topLeftOrigin = PillPosition.origin(
            for: .topLeft, contentSize: contentSize, screen: standardScreen,
            padding: padding, screenInset: screenInset
        )
        XCTAssertEqual(negOrigin, topLeftOrigin)

        let excessiveCustom = PillPosition.custom(xRatio: 1.5, yRatio: 2.0)
        let excOrigin = PillPosition.origin(
            for: excessiveCustom, contentSize: contentSize, screen: standardScreen,
            padding: padding, screenInset: screenInset
        )
        let bottomRightOrigin = PillPosition.origin(
            for: .bottomRight, contentSize: contentSize, screen: standardScreen,
            padding: padding, screenInset: screenInset
        )
        XCTAssertEqual(excOrigin, bottomRightOrigin)
    }

    func testSecondaryScreenGeometryWithNonZeroOrigin() {
        let secondaryScreen = ScreenGeometry(
            visibleFrame: NSRect(x: 1_440, y: 100, width: 1_920, height: 1_080)
        )
        let origin = PillPosition.origin(
            for: .topLeft, contentSize: contentSize, screen: secondaryScreen,
            padding: padding, screenInset: screenInset
        )

        let expectedContentX: CGFloat = 1_440 + screenInset
        let expectedContentY: CGFloat = 100 + 1_080 - screenInset - contentSize.height

        XCTAssertEqual(origin.x + padding, expectedContentX)
        XCTAssertEqual(origin.y + padding, expectedContentY)
    }

    // MARK: - 6. Serialization & Codable Persistence

    func testSerializationRoundtripForAllPresets() {
        for preset in PillPosition.allPresets {
            let serialized = preset.serializedString
            let decoded = PillPosition(serializedString: serialized)
            XCTAssertEqual(decoded, preset, "Failed roundtrip for preset: \(preset)")
        }
    }

    func testSerializationRoundtripForCustom() {
        let custom = PillPosition.custom(xRatio: 0.3456, yRatio: 0.7891)
        let serialized = custom.serializedString
        guard let decoded = PillPosition(serializedString: serialized) else {
            XCTFail("Failed to decode custom position from \(serialized)")
            return
        }

        XCTAssertEqual(decoded.xRatio, 0.3456, accuracy: 0.0001)
        XCTAssertEqual(decoded.yRatio, 0.7891, accuracy: 0.0001)
    }

    func testCodableRoundtrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        var positionsToTest = PillPosition.allPresets
        positionsToTest.append(.custom(xRatio: 0.42, yRatio: 0.88))

        let data = try encoder.encode(positionsToTest)
        let decoded = try decoder.decode([PillPosition].self, from: data)

        XCTAssertEqual(decoded.count, positionsToTest.count)
        for (original, decodedItem) in zip(positionsToTest, decoded) {
            XCTAssertEqual(original.xRatio, decodedItem.xRatio, accuracy: 0.0001)
            XCTAssertEqual(original.yRatio, decodedItem.yRatio, accuracy: 0.0001)
        }
    }

    // MARK: - 7. Display Names & Localization

    func testDisplayNamesExistForAllPresetsAndCustom() {
        for preset in PillPosition.allPresets {
            XCTAssertFalse(preset.displayNameEn.isEmpty)
            XCTAssertFalse(preset.displayNameEs.isEmpty)
            XCTAssertFalse(preset.displayName.isEmpty)
        }

        let custom = PillPosition.custom(xRatio: 0.5, yRatio: 0.5)
        XCTAssertEqual(custom.displayNameEn, "Custom (dragged)")
        XCTAssertEqual(custom.displayNameEs, "Personalizada (arrastrada)")
        XCTAssertEqual(PillPosition.topCenter.displayNameEn, "Top Center")
        XCTAssertEqual(PillPosition.topLeft.displayNameEs, "Superior izquierda")
    }
}
