import XCTest
@testable import GestureEngine

final class EventConfigTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SystemControl.mockVolume = nil
        SystemControl.mockBrightness = nil
    }

    override func tearDown() {
        SystemControl.mockVolume = nil
        SystemControl.mockBrightness = nil
        super.tearDown()
    }

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
        // 默认 positiveIncrease（本机 norm_y 上滑=增大；用户反馈默认方向反了 → 翻转）
        XCTAssertEqual(EventConfig.defaultVolume.directionRule, .positiveIncrease)
        XCTAssertEqual(EventConfig.defaultVolume.executionMethod, .mediaKey)

        // brightness
        XCTAssertEqual(EventConfig.defaultBrightness.actionType, .brightness)
        XCTAssertEqual(EventConfig.defaultBrightness.step, 0.0125)
        XCTAssertEqual(EventConfig.defaultBrightness.boundaryThreshold, 0.001)
        XCTAssertEqual(EventConfig.defaultBrightness.directionRule, .positiveIncrease)
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
        // 缺字段 → 默认值：positiveIncrease（本机 norm_y 上滑=增大）+ mediaKey
        XCTAssertEqual(decoded.directionRule, .positiveIncrease)
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

    // MARK: - 读取失败保护（getBrightness 部分机型返回 0 → 误判下边界 → 冻结 + 无 HUD）

    /// trackedValue=0（读取失败或真下边界）时不判定"在边界"——防误冻结
    func testIsAtAnyBoundary_readFailureZero_returnsFalse() {
        var event = EventConfig.defaultBrightness
        event.setTrackedValueForTesting(0)
        XCTAssertFalse(event.isAtAnyBoundary(), "读取失败返回 0 不应判定为下边界（否则图上冻结链误触发）")
        // 正常中间值 → 不在边界
        event.setTrackedValueForTesting(0.5)
        XCTAssertFalse(event.isAtAnyBoundary())
        // 接近上边界 → 在边界（读值可信时边界判断仍生效）
        event.setTrackedValueForTesting(0.999)
        XCTAssertTrue(event.isAtAnyBoundary())
    }

    /// mediaKey 冻结已屏蔽：consume 不读系统值（零 IOKit），恒执行 + .normal
    func testConsume_mediaKey_alwaysNormal_noSystemRead() {
        // 值 0（读取失败场景）也正常发键
        SystemControl.mockBrightness = 0
        var event = EventConfig.defaultBrightness
        event.setTrackedValueForTesting(0)
        XCTAssertEqual(event.consume(output: .tick(direction: -1, count: 1)), .normal,
                       "mediaKey 不读系统值，读取失败也不冻结")
        // 真实在边界也正常发键（系统自然 clamp），不冻结
        SystemControl.mockBrightness = 0.0005
        event.setTrackedValueForTesting(0.0005)
        XCTAssertEqual(event.consume(output: .tick(direction: -1, count: 1)), .normal,
                       "mediaKey 在边界也恒 .normal（冻结已屏蔽）")
        // trackedValue 推进（系统步长 1/16）供 boundarySide 判定；下边界 clamp 0
        XCTAssertEqual(event.trackedCurrentValue(), 0, accuracy: 1e-6,
                       "mediaKey consume 推进 trackedValue（下边界 clamp 0）")
    }

    // MARK: - mediaKey 不读系统值（冻结屏蔽后读值纯开销——IOKit 每 tick 阻塞帧回调 = 不跟手）

    /// mediaKey 连续滑动恒 .normal；trackedValue 按系统步长 1/16 推进（不读系统值）
    func testConsume_mediaKey_noDrift_noSystemRead() {
        SystemControl.mockVolume = 0.5
        var event = EventConfig.defaultVolume
        event.setTrackedValueForTesting(0.5)
        for dir in [1, 1, 1, -1, -1, 1] {   // 连续滑多个 tick
            XCTAssertEqual(event.consume(output: .tick(direction: dir, count: 1)), .normal)
        }
        // trackedValue = 0.5 + 0.0625×3 - 0.0625×2 + 0.0625 = 0.625（纯数学推进，无 IOKit）
        XCTAssertEqual(event.trackedCurrentValue(), 0.625, accuracy: 1e-6)
        XCTAssertFalse(event.isAtAnyBoundary())
    }

    /// trackedValue 数学推进（clamp [0,1]）；系统步长 1/16 无 v10.4 的 5 倍漂移（那是误用配置 step）
    func testConsume_mediaKey_trackedValueAdvances() {
        SystemControl.mockVolume = 0.5
        var event = EventConfig.defaultVolume
        event.setTrackedValueForTesting(0.99)   // 接近上边界
        XCTAssertEqual(event.consume(output: .tick(direction: 1, count: 1)), .normal)
        XCTAssertEqual(event.trackedCurrentValue(), 1.0, accuracy: 1e-6,
                       "mediaKey 推进 trackedValue 并 clamp 到上边界")
    }

    // MARK: - direct 精确调节（读系统值不可避免，保留边界判定）

    /// direct：中间值精确加减 + clamp；到达边界 → .hitBoundary
    func testConsume_direct_hitBoundary() {
        SystemControl.mockVolume = 0.99
        var event = EventConfig(name: "音量", actionType: .volume, step: 0.05,
                                boundaryThreshold: 0.001, directionRule: .positiveDecrease,
                                executionMethod: .direct)
        event.setTrackedValueForTesting(0.9)
        // 朝上边界调（+0.05 → 0.95）未到边界 → .normal
        XCTAssertEqual(event.consume(output: .tick(direction: 1, count: 1)), .normal)
        // mock 后检读 0.99 → trackedValue 同步为 0.99
        XCTAssertEqual(event.trackedCurrentValue(), 0.99, accuracy: 1e-6)
        // 再调朝外：mock 系统真实值到上边界（0.999）→ 后检 .hitBoundary
        SystemControl.mockVolume = 0.999
        let result = event.consume(output: .tick(direction: 1, count: 1))
        XCTAssertEqual(result, .hitBoundary, "direct 到上边界 → hitBoundary")
    }
}
