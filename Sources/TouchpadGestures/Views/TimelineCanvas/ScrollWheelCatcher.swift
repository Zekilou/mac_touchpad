import SwiftUI
import AppKit

/// 捕获 NSScrollView 事件（触控板两指滑动）→ 转发为画布平移增量
/// SwiftUI 没有公开的 scrollWheel 修饰符，用 NSViewRepresentable 桥接
struct ScrollWheelCatcher: NSViewRepresentable {
    /// 滚动增量（像素）：dx = 水平，dy = 垂直（内容方向，取反后用于平移）
    var onScroll: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = WheelView()
        view.onScroll = { dx, dy in
            context.coordinator.onScroll(dx, dy)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    final class Coordinator {
        var onScroll: (CGFloat, CGFloat) -> Void = { _, _ in }
    }

    /// NSView 子类：重写 scrollWheel 捕获触控板滑动
    private final class WheelView: NSView {
        var onScroll: ((CGFloat, CGFloat) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            // 触控板两指滑动的 deltaX/deltaY；像素滚动值可能带小数
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            if event.hasPreciseScrollingDeltas, abs(dx) > 0.01 || abs(dy) > 0.01 {
                onScroll?(dx, dy)
            }
        }

        override var acceptsFirstResponder: Bool { true }

        // 确保滚动事件进入本视图（即使手势系统介入也兜底）
        override func hitTest(_ point: NSPoint) -> NSView? { self }
    }
}
