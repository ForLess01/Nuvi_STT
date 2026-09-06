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

    func testShaderDeclaresMultiBandUniforms() {
        for field in ["float bass;", "float mid;", "float treble;"] {
            XCTAssertTrue(FerrofluidShaderSource.contains(field), "Shader missing uniform \(field)")
        }
    }

    func testShaderContainsFluidPhysicsAndPBRFeatures() {
        XCTAssertTrue(FerrofluidShaderSource.contains("stretchedMetaball"), "Shader should use smooth stretched metaballs")
        XCTAssertTrue(FerrofluidShaderSource.contains("organicChamberField"), "Shader should compute organic chamber field")
        XCTAssertTrue(FerrofluidShaderSource.contains("spikesFluidSDF"), "Shader should compute magnetic spikes SDF")
        XCTAssertTrue(FerrofluidShaderSource.contains("float style;"), "Shader should declare style uniform")
        XCTAssertTrue(FerrofluidShaderSource.contains("float coreSens;"), "Shader should declare coreSens uniform")
        XCTAssertTrue(FerrofluidShaderSource.contains("float dropletSens;"), "Shader should declare dropletSens uniform")
        XCTAssertTrue(FerrofluidShaderSource.contains("fresnel"), "Shader should use Fresnel approximation")
    }

    func testSettingsCarrySensitivityAndStyle() {
        XCTAssertEqual(FerrofluidSettings.default.sensitivity, 1.0)
        XCTAssertEqual(FerrofluidSettings.default.coreSensitivity, 1.0)
        XCTAssertEqual(FerrofluidSettings.default.dropletSensitivity, 1.0)
        XCTAssertEqual(FerrofluidSettings.default.style, .organic)
        let custom = FerrofluidSettings(
            coreSize: 0.1, reach: 0.5, spikiness: 2, viscosity: 0.03, speed: 1, spikeCount: 6,
            sensitivity: 1.8, coreSensitivity: 1.5, dropletSensitivity: 2.2, style: .spikes
        )
        XCTAssertEqual(custom.sensitivity, 1.8)
        XCTAssertEqual(custom.coreSensitivity, 1.5)
        XCTAssertEqual(custom.dropletSensitivity, 2.2)
        XCTAssertEqual(custom.style, .spikes)
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
