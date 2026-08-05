import SwiftUI
import AppKit

/// AppKit 级鼠标拖拽捕获（替代 SwiftUI DragGesture 实现节点拖动）
///
/// 为什么不用 DragGesture：macOS 上 SwiftUI DragGesture 在画布场景会被"取消-重新开始"，
/// 每次重启从新起点累计 translation，导致偏移值出现两条轨迹交替 → 节点在两个位置反复跳（横跳，
/// 已被日志证实：offset 在 (21,-49)/(17,-41) 两组值交替）。
/// AppKit mouseDown/Dragged/Up 事件流连续稳定、无"手势重启"概念，用增量 delta 单调累加 → 单轨迹。
///
/// 交互策略：
/// - mouseDown：命中检测（头部+端口区）记录候选，**不拦截**（点击/控件正常）
/// - mouseDragged：命中候选时**拦截**（SwiftUI 手势收不到 → 不会触发 DragGesture/取消重启），
///   增量 delta 上报（屏幕像素，y 已翻转 AppKit→SwiftUI）
/// - mouseUp：总位移 >3pt 视为拖动 → 上报总位移并拦截；否则视为点击 → 放行给 SwiftUI
struct DragMonitor: NSViewRepresentable {
    typealias NSViewType = DragView

    /// 命中检测：画布视图坐标点（y 向下）→ 节点 id（nil = 空白/控件区域，放行）
    var hitTestNode: (CGPoint) -> UUID?
    /// 命中节点（开始拖动候选）
    var onDragStart: (UUID) -> Void
    /// 拖拽增量（画布视图坐标方向，y 向下；相对上次事件）
    var onDragDelta: (CGSize) -> Void
    /// 拖拽结束（总位移，画布视图坐标方向）
    var onDragEnd: (CGSize) -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.hitTestNode = hitTestNode
        view.onDragStart = onDragStart
        view.onDragDelta = onDragDelta
        view.onDragEnd = onDragEnd
        return view
    }

    func updateNSView(_ nsView: DragView, context: Context) {
        nsView.hitTestNode = hitTestNode
        nsView.onDragStart = onDragStart
        nsView.onDragDelta = onDragDelta
        nsView.onDragEnd = onDragEnd
    }

    /// 窗口级 local monitor 监听鼠标三事件（不依赖 hitTest，SwiftUI 层无法可靠命中 NSView 的鼠标事件）
    final class DragView: NSView {
        var hitTestNode: ((CGPoint) -> UUID?)?
        var onDragStart: ((UUID) -> Void)?
        var onDragDelta: ((CGSize) -> Void)?
        var onDragEnd: ((CGSize) -> Void)?
        private var dragNodeID: UUID?
        private var lastPoint: NSPoint = .zero
        private var totalDelta: CGSize = .zero
        private var monitor: Any?

        /// y 向下（与 SwiftUI 视图坐标系一致）——convert 后坐标直接等于画布视图坐标，delta 无需取反
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self else { return event }
                switch event.type {
                case .leftMouseDown:
                    // 窗口坐标 → 画布视图坐标（isFlipped + convert）
                    let p = self.convert(event.locationInWindow, from: nil)
                    if let id = self.hitTestNode?(p) {
                        self.dragNodeID = id
                        self.lastPoint = p
                        self.totalDelta = .zero
                        self.onDragStart?(id)
                    } else {
                        self.dragNodeID = nil
                    }
                    return event  // 不拦截：点击选中 / 控件正常
                case .leftMouseDragged:
                    guard self.dragNodeID != nil else { return event }
                    let p = self.convert(event.locationInWindow, from: nil)
                    let delta = CGSize(width: p.x - self.lastPoint.x,
                                       height: p.y - self.lastPoint.y)
                    self.lastPoint = p
                    self.totalDelta = CGSize(width: self.totalDelta.width + delta.width,
                                             height: self.totalDelta.height + delta.height)
                    self.onDragDelta?(delta)
                    return nil  // 拦截：SwiftUI 手势收不到 → 无 DragGesture 取消重启
                case .leftMouseUp:
                    guard self.dragNodeID != nil else { return event }
                    self.dragNodeID = nil
                    if abs(self.totalDelta.width) > 3 || abs(self.totalDelta.height) > 3 {
                        self.onDragEnd?(self.totalDelta)
                        return nil
                    }
                    return event  // 无位移 = 点击：放行给 SwiftUI（onTapGesture）
                default:
                    break
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
