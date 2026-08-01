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
        // positiveIncrease + positiveDecrease = 2
        XCTAssertEqual(DirectionRule.allCases.count, 2)
    }

    func testDirectionRule_mapSignalDirection() {
        // 信号增（normY 增大 = 下滑）/ 信号减（normY 减小 = 上滑）
        let signalIncrease: Float = +0.02
        let signalDecrease: Float = -0.02

        // positiveDecrease：信号增=值减，信号减=值增
        // —— 对应旧 upIncrease：上滑(normY减小=信号减小)=值增
        let dec = DirectionRule.positiveDecrease
        XCTAssertEqual(dec.mapSignalDirection(signalIncrease), -1, "positiveDec + 信号增 = 值减")
        XCTAssertEqual(dec.mapSignalDirection(signalDecrease), +1, "positiveDec + 信号减 = 值增")

        // positiveIncrease：信号增=值增，信号减=值减
        let inc = DirectionRule.positiveIncrease
        XCTAssertEqual(inc.mapSignalDirection(signalIncrease), +1, "positiveInc + 信号增 = 值增")
        XCTAssertEqual(inc.mapSignalDirection(signalDecrease), -1, "positiveInc + 信号减 = 值减")
    }

    func testDirectionRule_legacyDecode_mapsCorrectly() throws {
        // 旧 upIncrease JSON 字符串 → 解码为 positiveDecrease
        let json1 = "\"upIncrease\"".data(using: .utf8)!
        let r1 = try JSONDecoder().decode(DirectionRule.self, from: json1)
        XCTAssertEqual(r1, .positiveDecrease)

        // 旧 upDecrease → 解码为 positiveIncrease
        let json2 = "\"upDecrease\"".data(using: .utf8)!
        let r2 = try JSONDecoder().decode(DirectionRule.self, from: json2)
        XCTAssertEqual(r2, .positiveIncrease)
    }

    // MARK: - Default Events

    func testDefaultEvents() {
        // volume
        XCTAssertEqual(EventConfig.defaultVolume.actionType, .volume)
        XCTAssertEqual(EventConfig.defaultVolume.step, 0.0125)
        XCTAssertEqual(EventConfig.defaultVolume.boundaryThreshold, 0.001)
        // 默认对齐旧 upIncrease → positiveDecrease
        XCTAssertEqual(EventConfig.defaultVolume.directionRule, .positiveDecrease)
        XCTAssertEqual(EventConfig.defaultVolume.executionMethod, .mediaKey)

        // brightness
        XCTAssertEqual(EventConfig.defaultBrightness.actionType, .brightness)
        XCTAssertEqual(EventConfig.defaultBrightness.step, 0.0125)
        XCTAssertEqual(EventConfig.defaultBrightness.boundaryThreshold, 0.001)
        XCTAssertEqual(EventConfig.defaultBrightness.directionRule, .positiveDecrease)
        XCTAssertEqual(EventConfig.defaultBrightness.executionMethod, .mediaKey)
    }

    // MARK: - Codable Round-trip

    func testCodableRoundTrip_fullFields() throws {
        let original = EventConfig(
            name: "自定义",
            actionType: .volume,
            step: 0.05,
            boundaryThreshold: 0.01,
            directionRule: .positiveIncrease,
            executionMethod: .direct
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EventConfig.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.directionRule, .positiveIncrease)
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
        // 缺字段 → 默认值：positiveDecrease（对齐旧 upIncrease）+ mediaKey
        XCTAssertEqual(decoded.directionRule, .positiveDecrease)
        XCTAssertEqual(decoded.executionMethod, .mediaKey)
        XCTAssertEqual(decoded.name, "旧配置音量")
        XCTAssertEqual(decoded.step, 0.0125)
    }

    func testCodable_legacyUpIncreaseString_decodesAsPositiveDecrease() throws {
        // 旧 JSON 里 directionRule = "upIncrease"
        let json = """
        {
          "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
          "name": "v1.1 配置",
          "actionType": "volume",
          "step": 0.0125,
          "boundaryThreshold": 0.001,
          "directionRule": "upIncrease",
          "executionMethod": "mediaKey"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EventConfig.self, from: json)
        XCTAssertEqual(decoded.directionRule, .positiveDecrease)
    }

    // MARK: - Boundary Detection

    func testIsAtBoundary_volumeMock() {
        // 注意：currentValue 会读真实系统音量，这里无法直接 mock；
        // 只验证 direction 语义（>0 / <0）通过 boundaryThreshold 辅助对比
        var event = EventConfig.defaultVolume
        // 逻辑上 isAtBoundary(direction:) 需要 currentValue，在单元测试无法 mock 系统 API 时
        // 保证至少不崩溃
        _ = event.isAtBoundary(direction: 1)
        _ = event.isAtBoundary(direction: -1)
        _ = event.isAtAnyBoundary()
    }
}
