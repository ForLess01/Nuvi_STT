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
        XCTAssertEqual(FerrofluidSettings.default.backgroundColor, RGBColor(0.965, 0.965, 0.965))
        XCTAssertFalse(FerrofluidSettings.presets.isEmpty, "Should ship curated presets")
        XCTAssertTrue(FerrofluidSettings.presets.contains { $0.name == "Classic" })
    }
}
