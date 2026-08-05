import SwiftUI
import AppKit

/// 捕获 AppKit 触控板事件 → 转发为画布平移/缩放
/// - scrollWheel（两指滑动）→ 平移增量
/// - magnify（捏合）→ 缩放因子（1 + 增量）
///
/// 实现：窗口级 local event monitor（不依赖 hitTest，SwiftUI 层无法可靠命中 NSView 的 scrollWheel）。
/// 事件位置落在 excludeRect（如左侧工具栏区域）内时放行，避免干扰面板内部滚动。
struct ScrollWheelCatcher: NSViewRepresentable {
    /// 滚动增量（像素）：dx = 水平，dy = 垂直（内容跟随手指）
    var onScroll: (CGFloat, CGFloat) -> Void
    /// 捏合缩放：因子（1 + 增量）+ 手势中心（画布视图坐标，缩放以指针为锚点）
    var onMagnify: (CGFloat, CGPoint) -> Void
    /// 排除区域（window 坐标）：该区域内的触控板事件不拦截（放行给系统）
    var excludeRect: CGRect = .zero

    func makeNSView(context: Context) -> NSView {
        let view = WheelView()
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        view.excludeRect = excludeRect
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WheelView else { return }
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        view.excludeRect = excludeRect
    }

    /// NSView：挂窗口级事件监听，拦截 scrollWheel / magnify
    private final class WheelView: NSView {
        var onScroll: ((CGFloat, CGFloat) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        var excludeRect: CGRect = .zero
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self else { return event }
                // 左侧栏等排除区域内 → 放行（让面板内滚动正常工作）
                if !self.excludeRect.contains(event.locationInWindow) {
                    switch event.type {
                    case .scrollWheel:
                        if event.hasPreciseScrollingDeltas,
                           abs(event.scrollingDeltaX) > 0.01 || abs(event.scrollingDeltaY) > 0.01 {
                            self.onScroll?(event.scrollingDeltaX, event.scrollingDeltaY)
                            return nil
                        }
                    case .magnify:
                        // 手势中心：窗口坐标 → 画布视图坐标（缩放以此为锚点）
                        // 注意 y 翻转：locationInWindow/frame.origin 是 AppKit 坐标（y 向上），
                        // 画布视图坐标 y 向下（原点左上）——不翻转会导致缩放锚点垂直错位（缩放时曲线/节点位移）
                        let origin = self.frame.origin
                        let center = CGPoint(x: event.locationInWindow.x - origin.x,
                                             y: self.bounds.height - (event.locationInWindow.y - origin.y))
                        self.onMagnify?(1 + event.magnification, center)
                        return nil
                    default:
                        break
                    }
                }
                return event
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { removeMonitor() }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
