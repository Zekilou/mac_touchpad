import XCTest
@testable import GestureEngine

final class EventConfigTests: XCTestCase {

    // MARK: - ActionType

    func testActionType_allCasesCount() {
        XCTAssertEqual(ActionType.allCases.count, 2)
    }

    func testActionType_displayNames_nonEmpty() {
        for type in ActionType.allCases {
            // displayName 含完整按键说明，shortName 是紧凑名，都不能空
            XCTAssertFalse(type.displayName.isEmpty, "\(type) displayName 为空")
            XCTAssertFalse(type.shortName.isEmpty, "\(type) shortName 为空")
            // displayName 里至少要包含目标（音量/Volume / 亮度/Brightness）关键字
            switch type {
            case .volume:
                XCTAssertTrue(
                    type.displayName.contains("Volume") || type.displayName.contains("音量"),
                    "volume.displayName 未含音量关键字: \(type.displayName)"
                )
            case .brightness:
                XCTAssertTrue(
                    type.displayName.contains("Brightness") || type.displayName.contains("亮度"),
                    "brightness.displayName 未含亮度关键字: \(type.displayName)"
                )
            }
        }
    }

    // MARK: - ExecutionMethod

    func testExecutionMethod_allCasesCount() {
        // mediaKey + direct = 2
        XCTAssertEqual(ExecutionMethod.allCases.count, 2)
    }

    func testExecutionMethod_names_nonEmpty() {
        for m in ExecutionMethod.allCases {
            XCTAssertFalse(m.displayName.isEmpty, "\(m) displayName 空")
            XCTAssertFalse(m.shortName.isEmpty, "\(m) shortName 空")
        }
    }

    // MARK: - DirectionRule

    func testDirectionRule_allCasesCount() {
        // upIncrease + upDecrease = 2
        XCTAssertEqual(DirectionRule.allCases.count, 2)
    }

    func testDirectionRule_mapSlidingDirection() {
        // 上滑（dy 负）/ 下滑（dy 正）两种物理方向
        let upDy: Float = -0.02
        let downDy: Float = 0.02

        let volumeUpInc = EventConfig.defaultVolume  // directionRule = .upIncrease
        XCTAssertEqual(volumeUpInc.directionRule, .upIncrease)
        // 上滑 = 增 → +1
        XCTAssertEqual(volumeUpInc.mapSlidingDirection(dy: upDy), 1, "upIncrease + 上滑 应等于增")
        // 下滑 = 减 → -1
        XCTAssertEqual(volumeUpInc.mapSlidingDirection(dy: downDy), -1, "upIncrease + 下滑 应等于减")

        var volumeUpDec = volumeUpInc
        volumeUpDec.directionRule = .upDecrease
        // 上滑 = 减 → -1
        XCTAssertEqual(volumeUpDec.mapSlidingDirection(dy: upDy), -1, "upDecrease + 上滑 应等于减")
        // 下滑 = 增 → +1
        XCTAssertEqual(volumeUpDec.mapSlidingDirection(dy: downDy), 1, "upDecrease + 下滑 应等于增")
    }

    // MARK: - Default Events

    func testDefaultEvents() {
        // volume
        XCTAssertEqual(EventConfig.defaultVolume.actionType, .volume)
        XCTAssertEqual(EventConfig.defaultVolume.step, 0.0125)
        XCTAssertEqual(EventConfig.defaultVolume.boundaryThreshold, 0.001)
        XCTAssertEqual(EventConfig.defaultVolume.directionRule, .upIncrease)
        XCTAssertEqual(EventConfig.defaultVolume.executionMethod, .mediaKey)

        // brightness
        XCTAssertEqual(EventConfig.defaultBrightness.actionType, .brightness)
        XCTAssertEqual(EventConfig.defaultBrightness.step, 0.0125)
        XCTAssertEqual(EventConfig.defaultBrightness.boundaryThreshold, 0.001)
        XCTAssertEqual(EventConfig.defaultBrightness.directionRule, .upIncrease)
        XCTAssertEqual(EventConfig.defaultBrightness.executionMethod, .mediaKey)
    }

    // MARK: - Codable Round-trip

    func testCodableRoundTrip_fullFields() throws {
        let original = EventConfig(
            name: "自定义",
            actionType: .volume,
            step: 0.05,
            boundaryThreshold: 0.01,
            directionRule: .upDecrease,
            executionMethod: .direct
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EventConfig.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.directionRule, .upDecrease)
        XCTAssertEqual(decoded.executionMethod, .direct)
    }

    func testCodable_missingNewFields_usesDefaults() throws {
        // 模拟旧 JSON 不含 directionRule / executionMethod
        let json = """
        {
          "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
          "name": "旧配置音量",
          "actionType": "volume",
          "step": 0.0125,
          "boundaryThreshold": 0.001
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EventConfig.self, from: json)
        // 缺字段 → 默认值
        XCTAssertEqual(decoded.directionRule, .upIncrease)
        XCTAssertEqual(decoded.executionMethod, .mediaKey)
        XCTAssertEqual(decoded.name, "旧配置音量")
        XCTAssertEqual(decoded.step, 0.0125)
    }

    // MARK: - Boundary Detection

    func testIsAtBoundary_volumeMock() {
        // 注意：currentValue 会读真实系统音量，这里无法直接 mock；
        // 只验证 direction 语义（>0 / <0）通过 boundaryThreshold 辅助对比
        let event = EventConfig.defaultVolume
        // 逻辑上 isAtBoundary(direction:) 需要 currentValue，在单元测试无法 mock 系统 API 时
        // 保证至少不崩溃
        _ = event.isAtBoundary(direction: 1)
        _ = event.isAtBoundary(direction: -1)
        _ = event.isAtAnyBoundary()
    }
}
