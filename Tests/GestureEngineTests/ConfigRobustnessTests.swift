import XCTest
@testable import GestureEngine

/// 配置持久化健壮性：损坏配置不得被静默丢弃，编码失败不得静默吞掉。
/// 这两类缺陷都曾导致「用户配置无声消失 / 保存看起来成功其实没写」。
final class ConfigRobustnessTests: XCTestCase {

    private var tmpDir: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cfgrobs_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        configURL = tmpDir.appendingPathComponent("config.json")
        ConfigStore.overrideConfigURL = configURL
    }

    override func tearDownWithError() throws {
        ConfigStore.overrideConfigURL = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// 回归：损坏 JSON 必须被隔离备份，而不是原地丢弃后直接被默认值覆写。
    func testCorruptConfigIsQuarantinedNotSilentlyDiscarded() throws {
        let garbage = "{ this is not valid json ][".data(using: .utf8)!
        try garbage.write(to: configURL)

        let loaded = ConfigStore.load()
        XCTAssertEqual(loaded.version, 3, "损坏配置应回退为可用的默认配置")
        XCTAssertFalse(loaded.gestures.isEmpty, "默认配置应有手势，避免 app 完全不可用")

        // 原始字节必须仍可取回：被移动到 config.corrupt-*.json
        let files = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        let backups = files.filter { $0.hasPrefix("config.corrupt-") }
        XCTAssertEqual(backups.count, 1, "损坏文件应被备份为 config.corrupt-*.json，实际: \(files)")

        let backupData = try Data(contentsOf: tmpDir.appendingPathComponent(backups[0]))
        XCTAssertEqual(backupData, garbage, "备份必须保留原始字节以便人工恢复")
    }

    /// 首次运行（文件不存在）不应产生任何备份噪音。
    func testMissingConfigDoesNotCreateBackup() throws {
        _ = ConfigStore.load()
        let files = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        XCTAssertTrue(files.filter { $0.hasPrefix("config.corrupt-") }.isEmpty,
                      "文件不存在属正常首次运行，不应生成损坏备份")
    }

    /// 回归：NaN 参数使 JSONEncoder 抛错——save 必须上报失败，而不是静默返回。
    func testSaveWithNaNReportsFailureInsteadOfSilentNoOp() throws {
        var cfg = AppConfig()
        XCTAssertFalse(cfg.gestures.isEmpty)
        // 把 NaN 塞进任一可编码的浮点参数（模拟用户在节点检查器输入 "nan"）
        cfg.gestures[0].timeline.nodes[0].params.threshold = .nan

        let ok = ConfigStore.save(cfg)
        XCTAssertFalse(ok, "含 NaN 的配置无法编码，save 必须返回 false（原实现 try? 静默吞掉）")
    }

    /// 正常配置必须能保存并**幂等**读回。
    /// 注意：首次 load 会按设计补齐 Force/seek 手势，故不能直接与 loadDefault() 比数量；
    /// 有意义的契约是「补齐后的配置再存再读不再变化」（迁移幂等，避免每次启动都改配置）。
    func testValidConfigSaveLoadIsIdempotent() throws {
        let cfg = ConfigStore.loadDefault()
        XCTAssertTrue(ConfigStore.save(cfg), "正常配置应保存成功")

        let first = ConfigStore.load()
        XCTAssertTrue(ConfigStore.save(first), "补齐后配置应能再次保存")
        let second = ConfigStore.load()

        XCTAssertEqual(second.gestures.count, first.gestures.count,
                       "二次 load 不应再次增删手势（迁移必须幂等）")
        XCTAssertEqual(second.regions.count, first.regions.count,
                       "二次 load 不应再次增删区域")
        XCTAssertEqual(second.events.count, first.events.count,
                       "二次 load 不应再次增删事件")
    }
}
