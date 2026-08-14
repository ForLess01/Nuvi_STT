import XCTest
@testable import Nuvi

final class FerrofluidShaderTests: XCTestCase {
    func testMetalUniformsMatchSwiftRendererLayout() {
        XCTAssertTrue(FerrofluidShaderSource.contains("float2 resolution;"))
        XCTAssertFalse(FerrofluidShaderSource.contains("float resolution;"))
    }

    func testShaderDeclaresColorUniforms() {
        // Colors are passed as individual floats to keep Swift/Metal layout aligned.
        for field in ["float fluidR;", "float fluidG;", "float fluidB;",
                      "float bgR;", "float bgG;", "float bgB;"] {
            XCTAssertTrue(FerrofluidShaderSource.contains(field), "Shader missing uniform \(field)")
        }
    }

    func testSettingsCarryColorsAndPresets() {
        XCTAssertEqual(FerrofluidSettings.default.backgroundColor, .nuviSoftWhite)
        XCTAssertEqual(FerrofluidSettings.default.fluidColor, .nuviCharcoal)
        XCTAssertFalse(FerrofluidSettings.presets.isEmpty, "Should ship curated presets")
        XCTAssertTrue(FerrofluidSettings.presets.contains { $0.name == "Classic" })

        let approved: Set<[Float]> = [
            [RGBColor.nuviCharcoal.r, RGBColor.nuviCharcoal.g, RGBColor.nuviCharcoal.b],
            [RGBColor.nuviSoftWhite.r, RGBColor.nuviSoftWhite.g, RGBColor.nuviSoftWhite.b],
            [RGBColor.nuviLavender.r, RGBColor.nuviLavender.g, RGBColor.nuviLavender.b]
        ]
        for preset in FerrofluidSettings.presets {
            XCTAssertTrue(approved.contains([
                preset.settings.fluidColor.r,
                preset.settings.fluidColor.g,
                preset.settings.fluidColor.b
            ]))
            XCTAssertTrue(approved.contains([
                preset.settings.backgroundColor.r,
                preset.settings.backgroundColor.g,
                preset.settings.backgroundColor.b
            ]))
        }
    }
}
