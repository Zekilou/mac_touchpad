import Foundation

/// 手势生效区域（矩形对象，归一化坐标 0~1）
/// @ai: do not change field names (Codable 合同)
public struct RegionConfig: Codable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public var name: String
    public var xMin: Float
    public var xMax: Float
    public var yMin: Float
    public var yMax: Float

    public init(id: UUID = UUID(), name: String, xMin: Float, xMax: Float, yMin: Float, yMax: Float) {
        self.id = id
        self.name = name
        self.xMin = xMin
        self.xMax = xMax
        self.yMin = yMin
        self.yMax = yMax
    }

    /// 判断归一化坐标是否在区域内
    public func contains(x: Float, y: Float) -> Bool {
        x >= xMin && x <= xMax && y >= yMin && y <= yMax
    }

    /// 默认左边缘区域
    public static let defaultLeft = RegionConfig(
        name: "左边缘", xMin: 0, xMax: 0.2, yMin: 0, yMax: 1)

    /// 默认右边缘区域
    public static let defaultRight = RegionConfig(
        name: "右边缘", xMin: 0.8, xMax: 1, yMin: 0, yMax: 1)
}
