import Foundation

/// v2 手势配置（迁移前的完整结构，仅用于解码旧 JSON）
/// 含 v1→v2 内部字段迁移（slideStepNorm/haptic Int32 → HapticEvent）
/// @ai: 此类型仅用于迁移，字段与解码逻辑不得改动
public struct GestureConfigV2: Codable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public var name: String
    public var regionID: UUID
    public var eventID: UUID

    public var tapMaxDuration: Double
    public var tapMaxDrift: Float
    public var tapMaxGap: Double
    public var holdMinDuration: Double

    public var disassociateMouse: Bool

    public var signalSource: SignalSource
    public var transformMode: TransformMode
    public var triggerMode: TriggerMode
    public var stepNorm: Float
    public var sensitivity: Float

    public var hapticEnter: HapticEvent
    public var hapticTick: HapticEvent
    public var hapticBoundary: HapticEvent
    public var hapticExit: HapticEvent

    enum CodingKeys: String, CodingKey {
        case id, name, regionID, eventID
        case tapMaxDuration, tapMaxDrift, tapMaxGap, holdMinDuration
        case disassociateMouse
        case slideStepNorm
        case hapticEnter, hapticTick, hapticBoundary, boundaryHapticInterval
        case signalSource, transformMode, triggerMode, stepNorm, sensitivity
        case hapticEnterV2, hapticTickV2, hapticBoundaryV2, hapticExitV2
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        regionID = try container.decode(UUID.self, forKey: .regionID)
        eventID = try container.decode(UUID.self, forKey: .eventID)
        tapMaxDuration = try container.decode(Double.self, forKey: .tapMaxDuration)
        tapMaxDrift = try container.decode(Float.self, forKey: .tapMaxDrift)
        tapMaxGap = try container.decode(Double.self, forKey: .tapMaxGap)
        holdMinDuration = try container.decode(Double.self, forKey: .holdMinDuration)
        disassociateMouse = try container.decode(Bool.self, forKey: .disassociateMouse)

        signalSource = try container.decodeIfPresent(SignalSource.self, forKey: .signalSource) ?? .normY
        transformMode = try container.decodeIfPresent(TransformMode.self, forKey: .transformMode) ?? .delta
        triggerMode = try container.decodeIfPresent(TriggerMode.self, forKey: .triggerMode) ?? .discrete
        if let v2Step = try container.decodeIfPresent(Float.self, forKey: .stepNorm) {
            stepNorm = v2Step
        } else if let v1SlideStep = try container.decodeIfPresent(Float.self, forKey: .slideStepNorm) {
            stepNorm = v1SlideStep
        } else {
            stepNorm = 0.02
        }
        sensitivity = try container.decodeIfPresent(Float.self, forKey: .sensitivity) ?? 1.0

        if let v2 = try container.decodeIfPresent(HapticEvent.self, forKey: .hapticEnterV2) {
            hapticEnter = v2
        } else {
            let oldWave = try container.decodeIfPresent(Int32.self, forKey: .hapticEnter) ?? 2
            hapticEnter = HapticEvent(enabled: true, waveform: oldWave, count: 1, intervalUs: 0)
        }
        if let v2 = try container.decodeIfPresent(HapticEvent.self, forKey: .hapticTickV2) {
            hapticTick = v2
        } else {
            let oldWave = try container.decodeIfPresent(Int32.self, forKey: .hapticTick) ?? 4
            hapticTick = HapticEvent(enabled: true, waveform: oldWave, count: 1, intervalUs: 0)
        }
        if let v2 = try container.decodeIfPresent(HapticEvent.self, forKey: .hapticBoundaryV2) {
            hapticBoundary = v2
        } else {
            let oldWave = try container.decodeIfPresent(Int32.self, forKey: .hapticBoundary) ?? 2
            let oldInterval = try container.decodeIfPresent(Int32.self, forKey: .boundaryHapticInterval) ?? 50000
            hapticBoundary = HapticEvent(enabled: true, waveform: oldWave, count: 2, intervalUs: oldInterval)
        }
        hapticExit = try container.decodeIfPresent(HapticEvent.self, forKey: .hapticExitV2) ?? .exit
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(regionID, forKey: .regionID)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(tapMaxDuration, forKey: .tapMaxDuration)
        try container.encode(tapMaxDrift, forKey: .tapMaxDrift)
        try container.encode(tapMaxGap, forKey: .tapMaxGap)
        try container.encode(holdMinDuration, forKey: .holdMinDuration)
        try container.encode(disassociateMouse, forKey: .disassociateMouse)
        try container.encode(signalSource, forKey: .signalSource)
        try container.encode(transformMode, forKey: .transformMode)
        try container.encode(triggerMode, forKey: .triggerMode)
        try container.encode(stepNorm, forKey: .stepNorm)
        try container.encode(sensitivity, forKey: .sensitivity)
        try container.encode(hapticEnter, forKey: .hapticEnterV2)
        try container.encode(hapticTick, forKey: .hapticTickV2)
        try container.encode(hapticBoundary, forKey: .hapticBoundaryV2)
        try container.encode(hapticExit, forKey: .hapticExitV2)
    }
}
