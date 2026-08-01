import XCTest
@testable import GestureEngine

final class ConfigMigrationTests: XCTestCase {
    /// 构造一个 v1 格式 JSON（扁平结构，无 version/regions/gestures/events 键）
    private func makeV1JSON() throws -> Data {
        let json = """
        {"frameRateLimit":0,"touchSizeMax":1.0,"touchSizeMin":0.1,
         "edgeRightThreshold":0.85,"edgeLeftThreshold":0.15,
         "tapMaxDuration":0.2,"tapMaxDrift":0.05,"tapMaxGap":0.3,
         "holdMinDuration":0.2,"hapticEnter":2,
         "volumeStepNorm":0.025,"volumeStep":0.02,
         "brightnessStepNorm":0.018,"brightnessStep":0.015,
         "hapticTick":4,"boundaryThreshold":0.002,
         "hapticBoundary":2,"boundaryHapticInterval":60000,
         "disassociateMouse":true}
        """
        return json.data(using: .utf8)!
    }

    func testV1Migration_producesV3Structure() throws {
        let v1Data = try makeV1JSON()
        let v1 = try JSONDecoder().decode(ConfigStore.V1Config.self, from: v1Data)
        let v3 = ConfigStore.migrate(v1: v1)

        XCTAssertEqual(v3.version, 3)
        XCTAssertEqual(v3.regions.count, 2)
        XCTAssertEqual(v3.gestures.count, 2)
        XCTAssertEqual(v3.events.count, 2)
        // 每个手势都迁移出了 4 条 Timeline（识别 + 执行）
        for gesture in v3.gestures {
            XCTAssertEqual(gesture.timelines.map(\.trigger),
                           [.onFirstTap, .onEnterHolding, .onTick, .onExitHolding])
        }
    }

    func testV1Migration_edgeThresholdsBecameRegions() throws {
        let v1Data = try makeV1JSON()
        let v1 = try JSONDecoder().decode(ConfigStore.V1Config.self, from: v1Data)
        let v2 = ConfigStore.migrate(v1: v1)

        let left = v2.regions[0]
        XCTAssertEqual(left.xMin, 0)
        XCTAssertEqual(left.xMax, 0.15)

        let right = v2.regions[1]
        XCTAssertEqual(right.xMin, 0.85)
        XCTAssertEqual(right.xMax, 1)
    }

    func testV1Migration_stepsBecameEvents() throws {
        let v1Data = try makeV1JSON()
        let v1 = try JSONDecoder().decode(ConfigStore.V1Config.self, from: v1Data)
        let v2 = ConfigStore.migrate(v1: v1)

        let volume = v2.events.first { $0.actionType == .volume }!
        XCTAssertEqual(volume.step, 0.02)

        let brightness = v2.events.first { $0.actionType == .brightness }!
        XCTAssertEqual(brightness.step, 0.015)
    }

    func testV1Migration_stepNormLandsInTickQuantizeNode() throws {
        let v1Data = try makeV1JSON()
        let v1 = try JSONDecoder().decode(ConfigStore.V1Config.self, from: v1Data)
        let v3 = ConfigStore.migrate(v1: v1)

        // stepNorm 迁移到 onTick 图的 quantize 节点
        let rightGesture = v3.gestures.first { $0.name == "右侧" }!
        let rightQuantize = rightGesture.timeline(for: .onTick)?.firstNode(of: .quantize)
        XCTAssertEqual(rightQuantize?.params.stepNorm, 0.025)

        let leftGesture = v3.gestures.first { $0.name == "左侧" }!
        let leftQuantize = leftGesture.timeline(for: .onTick)?.firstNode(of: .quantize)
        XCTAssertEqual(leftQuantize?.params.stepNorm, 0.018)
    }

    func testV1Migration_tapParamsLandsInRecognizeNode() throws {
        let v1Data = try makeV1JSON()
        let v1 = try JSONDecoder().decode(ConfigStore.V1Config.self, from: v1Data)
        let v3 = ConfigStore.migrate(v1: v1)

        let rightGesture = v3.gestures.first { $0.name == "右侧" }!
        let recognize = rightGesture.timeline(for: .onFirstTap)?.firstNode(of: .recognize)
        XCTAssertEqual(recognize?.params.tapMaxDuration, 0.2)
        XCTAssertEqual(recognize?.params.tapMaxGap, 0.3)
        XCTAssertEqual(recognize?.params.holdMinDuration, 0.2)
        // 手势识别参数属性从图读取
        XCTAssertEqual(rightGesture.tapMaxDuration, 0.2)
    }

    func testV1Migration_bindingsCorrect() throws {
        let v1Data = try makeV1JSON()
        let v1 = try JSONDecoder().decode(ConfigStore.V1Config.self, from: v1Data)
        let v2 = ConfigStore.migrate(v1: v1)

        let leftGesture = v2.gestures.first { $0.name == "左侧" }!
        let brightness = v2.events.first { $0.actionType == .brightness }!
        XCTAssertEqual(leftGesture.eventID, brightness.id)

        let rightGesture = v2.gestures.first { $0.name == "右侧" }!
        let volume = v2.events.first { $0.actionType == .volume }!
        XCTAssertEqual(rightGesture.eventID, volume.id)
    }

    func testV2CodableRoundTrip() throws {
        let original = AppConfig()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}
