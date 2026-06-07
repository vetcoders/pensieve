import XCTest

@testable import Pensieve

final class QubeFfiBridgeSmokeTests: XCTestCase {
  func testVistaEngineBridgeCompilesAndExposesExpectedSurface() {
    let engineType: VistaEngineProtocol.Type = VistaEngine.self

    XCTAssertEqual(String(describing: engineType), "VistaEngine")
  }
}
