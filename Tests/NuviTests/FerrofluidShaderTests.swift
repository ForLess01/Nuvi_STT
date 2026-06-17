import XCTest
@testable import Nuvi

final class FerrofluidShaderTests: XCTestCase {
    func testMetalUniformsMatchSwiftRendererLayout() {
        XCTAssertTrue(FerrofluidShaderSource.contains("float2 resolution;"))
        XCTAssertFalse(FerrofluidShaderSource.contains("float resolution;"))
    }
}
