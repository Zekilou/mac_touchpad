import Foundation

// MARK: - 音调类型

/// 音调波形类型（对应私有 API 字典 Tones[].Type）
/// @ai: rawValue 直接作为字典值传给 MTActuationCreateFromDictionary，勿改
public enum ToneType: String, Codable, CaseIterable, Hashable {
    case sine   = "Sine"
    case square = "Square"

    public var displayName: String {
        switch self {
        case .sine:   return L10n.tr("正弦", "Sine")
        case .square: return L10n.tr("方波", "Square")
        }
    }
}

// MARK: - 波形参数（可编程触觉波形的完整描述）

/// 触觉波形的物理参数。
///
/// 字段与 Apple 私有 actuation 字典一一对应（见 docs/research/自定义波形可行性.md）：
/// - 包络：BaseWaveform（Gaussian 钟形，决定"敲击感"的力度与时长）
/// - 音调：Tones[0]（叠加在包络上的正弦/方波，决定"嗡鸣/咔哒"的音色）
/// - 分级：Light/Medium/Firm 三档乘法器（按用户按压力度缩放幅度）
public struct WaveformSpec: Codable, Equatable, Hashable {

    // MARK: 包络（BaseWaveform）

    /// 包络类型。Apple 原生表全部为 Gaussian；保持字符串以兼容未来类型
    public var envelopeType: String
    /// 包络峰值幅度（原生表取值 0 / 19 / 22 / 35）
    public var envelopeAmplitude: Double
    /// 包络时长（ms）
    public var envelopeDurationMs: Double

    // MARK: 音调（Tones[0]）

    public var toneType: ToneType
    /// 音调频率（kHz，原生表取值 0.1 / 1.18 / 1.263 / 3.6）
    public var toneFrequencyKHz: Double
    /// 音调幅度（原生表取值 0.01 ~ 0.29）
    public var toneAmplitude: Double
    /// 音调时长（ms，原生表取值 2 / 3 / 6）
    public var toneDurationMs: Double
    /// 音调起始延迟（ms）
    public var toneDelayMs: Double

    // MARK: 按压力度分级乘法器

    public var envelopeLight: Double
    public var envelopeMedium: Double
    public var envelopeFirm: Double
    public var toneLight: Double
    public var toneMedium: Double
    public var toneFirm: Double

    public init(envelopeType: String = "Gaussian",
                envelopeAmplitude: Double = 19,
                envelopeDurationMs: Double = 6,
                toneType: ToneType = .sine,
                toneFrequencyKHz: Double = 1.18,
                toneAmplitude: Double = 0.02,
                toneDurationMs: Double = 3,
                toneDelayMs: Double = 1,
                envelopeLight: Double = 0.8,
                envelopeMedium: Double = 1.0,
                envelopeFirm: Double = 1.2,
                toneLight: Double = 0,
                toneMedium: Double = 0,
                toneFirm: Double = 0.2) {
        self.envelopeType = envelopeType
        self.envelopeAmplitude = envelopeAmplitude
        self.envelopeDurationMs = envelopeDurationMs
        self.toneType = toneType
        self.toneFrequencyKHz = toneFrequencyKHz
        self.toneAmplitude = toneAmplitude
        self.toneDurationMs = toneDurationMs
        self.toneDelayMs = toneDelayMs
        self.envelopeLight = envelopeLight
        self.envelopeMedium = envelopeMedium
        self.envelopeFirm = envelopeFirm
        self.toneLight = toneLight
        self.toneMedium = toneMedium
        self.toneFirm = toneFirm
    }

    /// 转为私有 API 的参数字典（MTActuationCreateFromDictionary 的入参）
    /// 键名/结构严格对齐 Apple 产线定义表，勿随意增删
    public func dictionary() -> [String: Any] {
        [
            "BaseWaveform": [
                "Type": envelopeType,
                "DurationMS": envelopeDurationMs,
                "Amplitude": envelopeAmplitude,
            ],
            "Tones": [[
                "Type": toneType.rawValue,
                "FrequencykHz": toneFrequencyKHz,
                "Amplitude": toneAmplitude,
                "DurationMS": toneDurationMs,
                "DelayMS": toneDelayMs,
            ]],
            "BaseMultipliers": [
                "Light": envelopeLight,
                "Medium": envelopeMedium,
                "Firm": envelopeFirm,
            ],
            "ToneMultipliers": [
                "Light": toneLight,
                "Medium": toneMedium,
                "Firm": toneFirm,
            ],
        ]
    }

    /// 总时长（ms）：包络与音调取较晚结束者
    public var totalDurationMs: Double {
        max(envelopeDurationMs, toneDelayMs + toneDurationMs)
    }
}

// MARK: - 自定义波形（用户可命名、可保存的波形）

/// 用户自定义触觉波形：一个名字 + 一组参数。
/// 存放在 AppConfig.waveforms，haptic 节点通过 customWaveformID 引用。
public struct CustomWaveform: Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var spec: WaveformSpec

    public init(id: UUID = UUID(), name: String, spec: WaveformSpec = WaveformSpec()) {
        self.id = id
        self.name = name
        self.spec = spec
    }

    /// @ai: 默认波形不用于实际播放，仅作为新建条目起点
    public static func makeDefault(name: String) -> CustomWaveform {
        CustomWaveform(name: name, spec: WaveformSpec())
    }
}

// MARK: - 预设波形参数表（源自 Apple 产线 actuation 定义）

/// 内置预设波形参数（ID 1~16）。
///
/// 数据来源：在 M5 / macOS 27.2 上调用 `MTActuatorGetProductionPlist` 导出的
/// `Default` 表（见 docs/research/mt_actuations_production.plist）。
///
/// @ai 注意：Apple 的 Default 表中 ID 1/3/5 与 2/4 存在参数重复
/// （幅度同为 19 / 22），实际手感差异来自固件对 ID 的解释与机型覆盖表。
/// 因此本表用于「预览曲线」，不代表精确的物理音色；不同机型可能略有出入。
public enum WaveformPresetCatalog {

    /// (ID, spec)
    /// 参数按 WaveformSpec 声明顺序书写，避免实参顺序错误
    public static let all: [(id: Int32, spec: WaveformSpec)] = [
        // 1：弱 click
        (1, WaveformSpec(envelopeAmplitude: 19, toneAmplitude: 0.02, toneFirm: 0.2)),
        // 2：强 click（Force Touch）
        (2, WaveformSpec(envelopeAmplitude: 22, toneAmplitude: 0.05,
                         envelopeLight: 0.9, envelopeFirm: 1.3, toneFirm: 0.95)),
        // 3：buzz（Apple Default 表与 ID 1 参数相同；机型覆盖表另有差异）
        (3, WaveformSpec(envelopeAmplitude: 19, toneAmplitude: 0.02, toneFirm: 0.2)),
        // 4：轻/中 tap（与 ID 2 参数相同）
        (4, WaveformSpec(envelopeAmplitude: 22, toneAmplitude: 0.05,
                         envelopeLight: 0.9, envelopeFirm: 1.3, toneFirm: 0.95)),
        // 5：中 tap
        (5, WaveformSpec(envelopeAmplitude: 19, toneAmplitude: 0.02, toneFirm: 0.2)),
        // 6：强 tap（幅度最大 + 略高音调）
        (6, WaveformSpec(envelopeAmplitude: 35, toneFrequencyKHz: 1.263, toneAmplitude: 0.06,
                         envelopeLight: 0.9, envelopeFirm: 1.3, toneFirm: 0.95)),
        // 15/16：无包络 + 纯低频长音 → 听感为"嗡"
        (15, WaveformSpec(envelopeAmplitude: 0, toneFrequencyKHz: 0.1,
                          toneAmplitude: 0.29, toneDurationMs: 6, toneDelayMs: 0,
                          envelopeLight: 1, envelopeMedium: 1, envelopeFirm: 1,
                          toneLight: 1, toneMedium: 1, toneFirm: 1)),
        (16, WaveformSpec(envelopeAmplitude: 0, toneFrequencyKHz: 0.1,
                          toneAmplitude: 0.29, toneDurationMs: 6, toneDelayMs: 0,
                          envelopeLight: 1, envelopeMedium: 1, envelopeFirm: 1,
                          toneLight: 1, toneMedium: 1, toneFirm: 1)),
    ]

    /// 按 ID 取预设参数；未收录的 ID 回退为默认参数
    public static func spec(for id: Int32) -> WaveformSpec {
        all.first { $0.id == id }?.spec ?? WaveformSpec()
    }

    /// 预设手感描述（与旧 waveformCatalog 对齐）
    public static func displayName(_ id: Int32) -> String {
        switch id {
        case 1:  return L10n.tr("弱 click", "Weak click")
        case 2:  return L10n.tr("强 click (Force Touch)", "Strong click (Force Touch)")
        case 3:  return L10n.tr("buzz 震颤", "Buzz")
        case 4:  return L10n.tr("轻 tap", "Light tap")
        case 5:  return L10n.tr("中 tap", "Medium tap")
        case 6:  return L10n.tr("强 tap", "Strong tap")
        case 15: return L10n.tr("软重击", "Soft hit")
        case 16: return L10n.tr("强重击", "Strong hit")
        default: return L10n.tr("未知波形", "Unknown")
        }
    }
}

// MARK: - 预览采样（纯计算，无副作用，可测试）

/// 波形预览数据：包络曲线 + 合成曲线（均已归一化到 -1...1）
public struct WaveformPreviewData: Equatable {
    /// 包络采样（0...1）
    public var envelope: [Float]
    /// 合成信号采样（-1...1）：包络 × 音调
    public var combined: [Float]
    /// 总时长（ms）
    public var totalMs: Double

    public init(envelope: [Float], combined: [Float], totalMs: Double) {
        self.envelope = envelope
        self.combined = combined
        self.totalMs = totalMs
    }
}

public enum WaveformPreview {

    /// 生成预览曲线。
    /// - Parameters:
    ///   - spec: 波形参数
    ///   - samples: 采样点数（缩略图 48、大图 240 足够平滑）
    ///   - intensity: 按压力度档位（0=Light / 1=Medium / 2=Firm），影响乘法器
    /// - Returns: 归一化后的包络与合成曲线
    public static func data(for spec: WaveformSpec,
                            samples: Int = 160,
                            intensity: Int = 1) -> WaveformPreviewData {
        let n = max(8, samples)
        let totalMs = max(spec.totalDurationMs, 0.001)
        let (envMul, toneMul) = multipliers(spec, intensity: intensity)

        // 按压力度缩放：直接作用于曲线幅度，使预览随档位变化（不做峰值归一，
        // 以便"轻/中/重"三档在同一坐标系下可直接比较强弱）
        let envGain = envMul
        let toneGain = toneMul

        var envelope = [Float](repeating: 0, count: n)
        var combined = [Float](repeating: 0, count: n)

        for i in 0..<n {
            let t = Double(i) / Double(n - 1) * totalMs

            // 包络：Gaussian 钟形（Apple 唯一使用的类型）
            var env = 0.0
            if spec.envelopeAmplitude > 0 && spec.envelopeDurationMs > 0 && t <= spec.envelopeDurationMs {
                let x = (t / spec.envelopeDurationMs) * 2 - 1          // -1...1
                env = exp(-4.5 * x * x)                                 // 钟形，边缘衰减到 ~0.011
            }
            // 包络相对强度：以原生幅度上界 35 为参考，归一化到 0...1
            let envNorm = min(1, env * (spec.envelopeAmplitude / 35.0) * envGain / 1.3)

            // 音调：延迟后开始，持续 toneDurationMs
            var tone = 0.0
            let toneStart = spec.toneDelayMs
            let toneEnd = spec.toneDelayMs + spec.toneDurationMs
            if spec.toneAmplitude > 0 && t >= toneStart && t <= toneEnd && spec.toneFrequencyKHz > 0 {
                let localT = (t - toneStart) / 1000.0                   // 秒
                let phase = 2 * Double.pi * spec.toneFrequencyKHz * 1000 * localT
                let raw = spec.toneType == .sine ? sin(phase) : (sin(phase) >= 0 ? 1.0 : -1.0)
                // 音调也做淡入淡出，避免起止爆音（与固件行为近似）
                let localSpan = max(toneEnd - toneStart, 0.001)
                let edge = min((t - toneStart) / localSpan, (toneEnd - t) / localSpan)
                // 音调幅度参考上界 0.29
                tone = raw * min(1, max(0, edge * 4))
                    * min(1, spec.toneAmplitude / 0.29 * toneGain)
            }

            envelope[i] = Float(max(0, min(1, envNorm)))
            // 合成：包络为主、音调为辅（音调权重略低，避免削顶失真）
            let mix = envNorm * 0.75 + tone * 0.55
            combined[i] = Float(max(-1, min(1, mix)))
        }

        return WaveformPreviewData(envelope: envelope, combined: combined, totalMs: totalMs)
    }

    /// 取按压力度对应的 (包络倍数, 音调倍数)
    public static func multipliers(_ spec: WaveformSpec, intensity: Int) -> (Double, Double) {
        switch intensity {
        case 0:  return (spec.envelopeLight,  spec.toneLight)
        case 2:  return (spec.envelopeFirm,   spec.toneFirm)
        default: return (spec.envelopeMedium, spec.toneMedium)
        }
    }

    /// 一句话概括波形特征（用于列表/提示）
    public static func summary(for spec: WaveformSpec) -> String {
        if spec.envelopeAmplitude <= 0 && spec.toneFrequencyKHz > 0 && spec.toneFrequencyKHz < 0.3 {
            return L10n.tr("低频嗡鸣", "Low buzz")
        }
        if spec.envelopeAmplitude >= 30 {
            return L10n.tr("强重击", "Strong hit")
        }
        if spec.toneAmplitude >= 0.04 {
            return L10n.tr("清脆咔哒", "Crisp click")
        }
        return L10n.tr("轻柔敲击", "Soft tap")
    }
}
