import XCTest
@testable import GestureEngine

final class EventConfigTests: XCTestCase {
    func testActionTypeDisplayNames() {
        XCTAssertEqual(ActionType.volume.displayName, "音量")
        XCTAssertEqual(ActionType.brightness.displayName, "亮度")
        XCTAssertEqual(ActionType.allCases.count, 2)
    }

    func testDefaultEvents() {
        XCTAssertEqual(EventConfig.defaultVolume.actionType, .volume)
        XCTAssertEqual(EventConfig.defaultBrightness.actionType, .brightness)
        XCTAssertEqual(EventConfig.defaultVolume.step, 0.0125)
    }

    func testCodableRoundTrip() throws {
        let original = EventConfig(name: "自定义", actionType: .volume, step: 0.05, boundaryThreshold: 0.01)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EventConfig.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}
