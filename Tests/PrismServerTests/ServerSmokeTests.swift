import XCTest
@testable import PrismServer

final class ServerSmokeTests: XCTestCase {
    func testProtocolVersion() {
        XCTAssertGreaterThanOrEqual(PrismServerInfo.protocolVersion, 1)
    }
}
