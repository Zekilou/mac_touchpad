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

    /// 判断归一化坐标是否在区域内。
    /// 对 `xMin > xMax`（用户在区域页拖四个独立滑杆时一步可达）做顺序归一化，
    /// 否则恒返回 false → 绑定该区域的手势静默失效。
    public func contains(x: Float, y: Float) -> Bool {
        let loX = min(xMin, xMax), hiX = max(xMin, xMax)
        let loY = min(yMin, yMax), hiY = max(yMin, yMax)
        return x >= loX && x <= hiX && y >= loY && y <= hiY
    }

    /// 规范化：把 min/max 顺序摆正并钳到 0...1（非有限值回退为全区域）。
    /// 解码与用户编辑后调用，保证区域始终是合法矩形。
    public mutating func normalize() {
        func fix(_ a: Float, _ b: Float) -> (Float, Float) {
            guard a.isFinite, b.isFinite else { return (0, 1) }
            let lo = min(max(min(a, b), 0), 1)
            let hi = min(max(max(a, b), 0), 1)
            return (lo, hi)
        }
        let (nx0, nx1) = fix(xMin, xMax)
        let (ny0, ny1) = fix(yMin, yMax)
        xMin = nx0; xMax = nx1; yMin = ny0; yMax = ny1
    }

    /// 解码后立即规范化：旧配置/手改 JSON 里的越界或反向值一律修正为合法矩形
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        xMin = try c.decode(Float.self, forKey: .xMin)
        xMax = try c.decode(Float.self, forKey: .xMax)
        yMin = try c.decode(Float.self, forKey: .yMin)
        yMax = try c.decode(Float.self, forKey: .yMax)
        normalize()
    }

    /// 默认左边缘区域
    public static let defaultLeft = RegionConfig(
        name: "左边缘", xMin: 0, xMax: 0.2, yMin: 0, yMax: 1)

    /// 默认右边缘区域
    public static let defaultRight = RegionConfig(
        name: "右边缘", xMin: 0.8, xMax: 1, yMin: 0, yMax: 1)

    /// 默认上边缘区域（norm_y 0 = 触控板顶部）
    /// x 限中段 0.2~0.8：与左右边缘（x 0~0.2 / 0.8~1，全高）四角不重叠，
    /// 避免同一次触摸同时落入两个手势区域（会同时调两个事件）
    public static let defaultTop = RegionConfig(
        name: "上边缘", xMin: 0.2, xMax: 0.8, yMin: 0, yMax: 0.2)

    /// 默认下边缘区域（norm_y 1 = 触控板底部），x 限中段原因同上
    public static let defaultBottom = RegionConfig(
        name: "下边缘", xMin: 0.2, xMax: 0.8, yMin: 0.8, yMax: 1)
}
