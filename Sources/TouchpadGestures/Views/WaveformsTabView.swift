import SwiftUI
import GestureEngine

// MARK: - 波形选择标识

/// 波形栏中的选中项：预设（只读）或自定义（可编辑）
enum WaveformSelection: Hashable {
    case preset(Int32)
    case custom(UUID)
}

// MARK: - 波形页（一级导航）

/// 「波形」页：左侧波形栏（预设 + 自定义库），右侧可视化编辑器。
///
/// - 左栏：列出 Apple 预设波形（1~16）与用户自定义波形，各带缩略预览
/// - 右栏：大图可视化编辑——**可直接拖拽曲线上的控制点**调整包络与音调，
///   下方滑块做精确微调；改动实时预览并可试听
/// - 预设只读，可「另存为自定义」后编辑
struct WaveformsTabView: View {
    @Binding var config: AppConfig

    @EnvironmentObject var appDelegate: AppDelegate

    @State private var selection: WaveformSelection = .preset(2)
    /// 待删除的自定义波形（确认弹窗）
    @State private var pendingDelete: CustomWaveform?

    var body: some View {
        HSplitView {
            WaveformListColumn(config: $config, selection: $selection,
                               onDelete: { pendingDelete = $0 })
                .frame(minWidth: 200, idealWidth: 226, maxWidth: 300)

            WaveformEditorPane(config: $config, selection: $selection)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            L10n.tr("删除波形「\(pendingDelete?.name ?? "")」？",
                    "Delete waveform \"\(pendingDelete?.name ?? "")\"?"),
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } })
        ) {
            Button(L10n.tr("删除", "Delete"), role: .destructive) {
                if let wf = pendingDelete {
                    config.deleteCustomWaveform(id: wf.id)
                    // 选中项被删 → 回退到预设
                    if case .custom(let id) = selection, id == wf.id {
                        selection = .preset(2)
                    }
                }
                pendingDelete = nil
            }
            Button(L10n.tr("取消", "Cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(L10n.tr("引用该波形的手势会自动回退为预设波形。此操作不可撤销。",
                         "Gestures using it fall back to preset waveforms. This cannot be undone."))
        }
    }
}

// MARK: - 左侧：波形栏

/// 波形栏：预设分组 + 自定义分组；底部「新建波形」。
struct WaveformListColumn: View {
    @Binding var config: AppConfig
    @Binding var selection: WaveformSelection
    let onDelete: (CustomWaveform) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    sectionHeader(L10n.tr("预设波形", "Presets"))
                    ForEach(WaveformPresetCatalog.all, id: \.id) { item in
                        presetRow(item.id, spec: item.spec)
                    }

                    sectionHeader(L10n.tr("自定义波形", "Custom"))
                        .padding(.top, 8)
                    if config.customWaveforms.isEmpty {
                        Text(L10n.tr("点击下方「新建波形」创建。",
                                     "Use \"New Waveform\" below to create one."))
                            .font(.caption2).foregroundStyle(.tertiary)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                    } else {
                        ForEach(config.customWaveforms) { wf in
                            customRow(wf)
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            Divider()

            // 新建波形
            Button {
                let name = uniqueName(base: L10n.tr("新波形", "New Waveform"))
                let wf = CustomWaveform(name: name)
                config.customWaveforms.append(wf)
                selection = .custom(wf.id)
            } label: {
                Label(L10n.tr("新建波形", "New Waveform"), systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color.primary.opacity(0.02))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
    }

    private func presetRow(_ id: Int32, spec: WaveformSpec) -> some View {
        let isSelected = selection == .preset(id)
        return Button {
            selection = .preset(id)
        } label: {
            HStack(spacing: 8) {
                WaveformSparkline(spec: spec, lineWidth: 1.2)
                    .frame(width: 58, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(id) · \(WaveformPresetCatalog.displayName(id))")
                        .font(.caption)
                        .lineLimit(1)
                    Text(WaveformPreview.summary(for: spec))
                        .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func customRow(_ wf: CustomWaveform) -> some View {
        let isSelected = selection == .custom(wf.id)
        return Button {
            selection = .custom(wf.id)
        } label: {
            HStack(spacing: 8) {
                WaveformSparkline(spec: wf.spec, lineWidth: 1.2)
                    .frame(width: 58, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(wf.name).font(.caption).lineLimit(1)
                    Text(WaveformPreview.summary(for: wf.spec))
                        .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { onDelete(wf) } label: {
                Label(L10n.tr("删除", "Delete"), systemImage: "trash")
            }
        }
    }

    /// 生成不重名的波形名
    private func uniqueName(base: String) -> String {
        let existing = Set(config.customWaveforms.map(\.name))
        if !existing.contains(base) { return base }
        var i = 2
        while existing.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }
}

// MARK: - 右侧：编辑器

/// 可视化编辑器：大图（可拖拽控制点）+ 参数滑块 + 试听/另存为。
struct WaveformEditorPane: View {
    @Binding var config: AppConfig
    @Binding var selection: WaveformSelection

    @EnvironmentObject var appDelegate: AppDelegate

    /// 按压力度预览档位（0=轻 / 1=中 / 2=重）
    @State private var intensity: Int = 1

    /// 当前编辑的波形参数（预设为只读副本）
    private var spec: WaveformSpec {
        switch selection {
        case .preset(let id): return WaveformPresetCatalog.spec(for: id)
        case .custom(let id):
            return config.customWaveforms.first { $0.id == id }?.spec ?? WaveformSpec()
        }
    }

    /// 是否可编辑（仅自定义波形）
    private var isEditable: Bool { customIndex != nil }

    private var customIndex: Int? {
        guard case .custom(let id) = selection else { return nil }
        return config.customWaveforms.firstIndex { $0.id == id }
    }

    /// 可写 Binding：预设时返回只读（set 忽略），避免误改预设
    private var specBinding: Binding<WaveformSpec> {
        Binding(
            get: { spec },
            set: { newValue in
                guard let i = customIndex else { return }
                config.customWaveforms[i].spec = newValue
            }
        )
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: {
                if case .custom(let id) = selection,
                   let wf = config.customWaveforms.first(where: { $0.id == id }) {
                    return wf.name
                }
                return L10n.tr("预设波形", "Preset")
            },
            set: { newValue in
                guard let i = customIndex else { return }
                config.customWaveforms[i].name = newValue
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                canvasCard
                envelopeCard
                toneCard
                intensityCard
                if !isEditable { presetNotice }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: 顶部（名称 + 操作）

    private var header: some View {
        HStack(spacing: 10) {
            if isEditable {
                TextField(L10n.tr("波形名称", "Waveform name"), text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)
                    .frame(maxWidth: 260)
            } else {
                Text(L10n.tr("预设波形", "Preset"))
                    .font(.headline).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                appDelegate.engine.previewWaveform(spec)
            } label: {
                Label(L10n.tr("试听", "Preview"), systemImage: "play.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            if !isEditable {
                Button {
                    // 另存为自定义副本（预设参数 → 新自定义波形，保持选中）
                    let wf = CustomWaveform(
                        name: uniqueCustomName(base: presetName),
                        spec: spec)
                    config.customWaveforms.append(wf)
                    selection = .custom(wf.id)
                } label: {
                    Label(L10n.tr("另存为自定义", "Save as Custom"),
                          systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var presetName: String {
        if case .preset(let id) = selection {
            return "\(id) \(WaveformPresetCatalog.displayName(id))"
        }
        return L10n.tr("自定义副本", "Custom Copy")
    }

    private func uniqueCustomName(base: String) -> String {
        let existing = Set(config.customWaveforms.map(\.name))
        if !existing.contains(base) { return base }
        var i = 2
        while existing.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    // MARK: 大图可视化编辑

    private var canvasCard: some View {
        Card(title: L10n.tr("波形可视化编辑", "Waveform Editor")) {
            InteractiveWaveformCanvas(spec: specBinding, intensity: intensity,
                                      editable: isEditable)
                .frame(height: 150)
            Text(isEditable
                 ? L10n.tr("拖动橙色点调整包络（左右=时长，上下=幅度）；拖动蓝色点调整音调。",
                            "Drag the orange handle for the envelope (X = duration, Y = amplitude); drag the blue handle for the tone.")
                 : L10n.tr("预设波形只读。点击「另存为自定义」后可自由编辑。",
                            "Presets are read-only. Use \"Save as Custom\" to edit."))
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                legendDot(color: .orange, label: L10n.tr("包络", "Envelope"))
                legendDot(color: .blue, label: L10n.tr("音调", "Tone"))
                legendDot(color: .accentColor, label: L10n.tr("合成", "Combined"))
                Spacer()
                Text(String(format: L10n.tr("总时长 %.0f ms", "Total %.0f ms"),
                            spec.totalDurationMs))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    // MARK: 包络参数

    private var envelopeCard: some View {
        Card(title: L10n.tr("包络（敲击力度）", "Envelope (impact)")) {
            sliderRow(L10n.tr("包络幅度", "Envelope Amplitude"),
                      value: Binding(get: { specBinding.wrappedValue.envelopeAmplitude },
                                     set: { specBinding.wrappedValue.envelopeAmplitude = $0 }),
                      range: 0...40, format: "%.0f")
            sliderRow(L10n.tr("包络时长 (ms)", "Envelope Duration (ms)"),
                      value: Binding(get: { specBinding.wrappedValue.envelopeDurationMs },
                                     set: { specBinding.wrappedValue.envelopeDurationMs = $0 }),
                      range: 1...30, format: "%.0f")
        }
    }

    // MARK: 音调参数

    private var toneCard: some View {
        Card(title: L10n.tr("音调（音色）", "Tone (timbre)")) {
            HStack {
                Text(L10n.tr("类型", "Type")).frame(width: 150, alignment: .leading)
                Picker("", selection: Binding(
                    get: { specBinding.wrappedValue.toneType },
                    set: { specBinding.wrappedValue.toneType = $0 }
                )) {
                    ForEach(ToneType.allCases, id: \.self) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                Spacer()
            }
            sliderRow(L10n.tr("频率 (kHz)", "Frequency (kHz)"),
                      value: Binding(get: { specBinding.wrappedValue.toneFrequencyKHz },
                                     set: { specBinding.wrappedValue.toneFrequencyKHz = $0 }),
                      range: 0.05...5.0, format: "%.2f")
            sliderRow(L10n.tr("音调幅度", "Tone Amplitude"),
                      value: Binding(get: { specBinding.wrappedValue.toneAmplitude },
                                     set: { specBinding.wrappedValue.toneAmplitude = $0 }),
                      range: 0...0.35, format: "%.3f")
            sliderRow(L10n.tr("音调时长 (ms)", "Tone Duration (ms)"),
                      value: Binding(get: { specBinding.wrappedValue.toneDurationMs },
                                     set: { specBinding.wrappedValue.toneDurationMs = $0 }),
                      range: 1...30, format: "%.0f")
            sliderRow(L10n.tr("起始延迟 (ms)", "Tone Delay (ms)"),
                      value: Binding(get: { specBinding.wrappedValue.toneDelayMs },
                                     set: { specBinding.wrappedValue.toneDelayMs = $0 }),
                      range: 0...20, format: "%.0f")
        }
    }

    // MARK: 按压力度分级

    private var intensityCard: some View {
        Card(title: L10n.tr("按压力度分级", "Force Multipliers")) {
            HStack {
                Text(L10n.tr("预览档位", "Preview Level")).frame(width: 150, alignment: .leading)
                Picker("", selection: $intensity) {
                    Text(L10n.tr("轻", "Light")).tag(0)
                    Text(L10n.tr("中", "Medium")).tag(1)
                    Text(L10n.tr("重", "Firm")).tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                Spacer()
            }
            Text(L10n.tr("同一波形在轻/中/重按下时会按倍数缩放幅度——上方大图随档位变化。",
                         "The waveform scales by these multipliers for light/medium/firm presses — the preview above follows."))
                .font(.caption2).foregroundStyle(.secondary)
            sliderRow(L10n.tr("包络 Light", "Envelope Light"),
                      value: Binding(get: { specBinding.wrappedValue.envelopeLight },
                                     set: { specBinding.wrappedValue.envelopeLight = $0 }),
                      range: 0...2, format: "%.2f")
            sliderRow(L10n.tr("包络 Firm", "Envelope Firm"),
                      value: Binding(get: { specBinding.wrappedValue.envelopeFirm },
                                     set: { specBinding.wrappedValue.envelopeFirm = $0 }),
                      range: 0...2, format: "%.2f")
            sliderRow(L10n.tr("音调 Light", "Tone Light"),
                      value: Binding(get: { specBinding.wrappedValue.toneLight },
                                     set: { specBinding.wrappedValue.toneLight = $0 }),
                      range: 0...2, format: "%.2f")
            sliderRow(L10n.tr("音调 Firm", "Tone Firm"),
                      value: Binding(get: { specBinding.wrappedValue.toneFirm },
                                     set: { specBinding.wrappedValue.toneFirm = $0 }),
                      range: 0...2, format: "%.2f")
        }
    }

    private var presetNotice: some View {
        Text(L10n.tr("提示：预设波形的实际手感由固件按机型解释；此处曲线是参数近似，用于对比形状。",
                     "Note: preset feel is firmware-defined per model; this curve approximates the parameters for shape comparison."))
            .font(.caption2).foregroundStyle(.tertiary)
    }

    private func sliderRow(_ label: String, value: Binding<Double>,
                           range: ClosedRange<Double>, format: String) -> some View {
        HStack {
            Text(label).frame(width: 150, alignment: .leading)
            Slider(value: value, in: range)
                .disabled(!isEditable)
            Text(String(format: format, value.wrappedValue))
                .monospacedDigit().frame(width: 54, alignment: .trailing)
        }
    }
}

// MARK: - 交互式波形画布（可视化编辑核心）

/// 大图波形编辑器：显示包络填充、音调区间、合成曲线，
/// 并提供两个可拖拽控制点直接改参数。
struct InteractiveWaveformCanvas: View {
    @Binding var spec: WaveformSpec
    var intensity: Int
    /// 只读模式（预设波形）
    var editable: Bool

    /// 拖拽中的控制点
    @State private var dragging: Handle?

    private enum Handle { case envelope, tone }

    /// 硬件动态范围的参考上界（用于坐标映射）
    private static let maxEnvelopeAmplitude: Double = 40
    private static let maxToneAmplitude: Double = 0.35
    private static let minMs: Double = 1
    private static let maxMs: Double = 40

    private var data: WaveformPreviewData {
        WaveformPreview.data(for: spec, samples: 200, intensity: intensity)
    }

    /// 时间轴上限（留 15% 余量，便于拖长）
    private var axisMaxMs: Double {
        max(Self.maxMs * 0.75, spec.totalDurationMs * 1.15)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))

                gridLines(size: size)

                // 音调有效区间（背景高亮）
                toneSpan(size: size)

                // 包络填充
                envelopeFill(size: size)
                    .fill(Color.orange.opacity(0.18))

                // 包络轮廓
                envelopePath(size: size)
                    .stroke(Color.orange.opacity(0.85),
                            style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))

                // 合成曲线
                combinedPath(size: size)
                    .stroke(Color.accentColor,
                            style: StrokeStyle(lineWidth: 1.8,
                                               lineCap: .round, lineJoin: .round))

                // 控制点
                if editable {
                    handleDot(at: envelopeHandlePoint(size: size), color: .orange)
                    handleDot(at: toneHandlePoint(size: size), color: .blue)
                }
            }
            .contentShape(Rectangle())
            .gesture(editable ? dragGesture(size: size) : nil)
        }
    }

    // MARK: 坐标映射

    private func xFor(_ ms: Double, _ size: CGSize) -> CGFloat {
        CGFloat(min(max(ms, 0), axisMaxMs) / axisMaxMs) * size.width
    }

    private func msFor(_ x: CGFloat, _ size: CGSize) -> Double {
        Double(min(max(x, 0), size.width) / max(size.width, 1)) * axisMaxMs
    }

    /// 幅度 → y（零轴居中）
    private func yFor(_ value: Double, maxValue: Double, _ size: CGSize) -> CGFloat {
        let mid = size.height / 2
        let amp = size.height / 2 * 0.86
        return mid - CGFloat(min(max(value / maxValue, -1), 1)) * amp
    }

    private func valueForY(_ y: CGFloat, maxValue: Double, _ size: CGSize) -> Double {
        let mid = size.height / 2
        let amp = max(size.height / 2 * 0.86, 1)
        return Double((mid - y) / amp) * maxValue
    }

    // MARK: 控制点位置

    private func envelopeHandlePoint(size: CGSize) -> CGPoint {
        CGPoint(x: xFor(spec.envelopeDurationMs, size),
                y: yFor(spec.envelopeAmplitude, maxValue: Self.maxEnvelopeAmplitude, size))
    }

    private func toneHandlePoint(size: CGSize) -> CGPoint {
        let endMs = spec.toneDelayMs + spec.toneDurationMs
        return CGPoint(x: xFor(endMs, size),
                       y: yFor(spec.toneAmplitude, maxValue: Self.maxToneAmplitude, size))
    }

    // MARK: 手势

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                // 首次按下时判定抓住哪个控制点（就近）
                if dragging == nil {
                    let p = g.startLocation
                    let dEnv = hypot(p.x - envelopeHandlePoint(size: size).x,
                                     p.y - envelopeHandlePoint(size: size).y)
                    let dTone = hypot(p.x - toneHandlePoint(size: size).x,
                                      p.y - toneHandlePoint(size: size).y)
                    // 都较远时按水平位置推断（左半改包络，右半改音调）
                    if min(dEnv, dTone) > 26 {
                        dragging = p.x < size.width / 2 ? .envelope : .tone
                    } else {
                        dragging = dEnv <= dTone ? .envelope : .tone
                    }
                }
                applyDrag(to: g.location, size: size)
            }
            .onEnded { _ in dragging = nil }
    }

    private func applyDrag(to point: CGPoint, size: CGSize) {
        switch dragging {
        case .envelope:
            let ms = msFor(point.x, size)
            spec.envelopeDurationMs = clamp(ms, Self.minMs, Self.maxMs)
            let amp = valueForY(point.y, maxValue: Self.maxEnvelopeAmplitude, size)
            spec.envelopeAmplitude = clamp(amp, 0, Self.maxEnvelopeAmplitude)
        case .tone:
            let endMs = msFor(point.x, size)
            // 拖动右端 → 改时长（不早于延迟 + 1ms）
            spec.toneDurationMs = clamp(endMs - spec.toneDelayMs, Self.minMs, Self.maxMs)
            let amp = valueForY(point.y, maxValue: Self.maxToneAmplitude, size)
            spec.toneAmplitude = clamp(amp, 0, Self.maxToneAmplitude)
        case .none:
            break
        }
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }

    // MARK: 绘制

    private func gridLines(size: CGSize) -> some View {
        Path { p in
            // 零轴
            p.move(to: CGPoint(x: 0, y: size.height / 2))
            p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        }
        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
    }

    private func toneSpan(size: CGSize) -> some View {
        let x0 = xFor(spec.toneDelayMs, size)
        let x1 = xFor(spec.toneDelayMs + spec.toneDurationMs, size)
        return Rectangle()
            .fill(Color.blue.opacity(0.08))
            .frame(width: max(x1 - x0, 0), height: size.height)
            .position(x: (x0 + x1) / 2, y: size.height / 2)
    }

    private func combinedPath(size: CGSize) -> Path {
        let pts = data.combined
        let mid = size.height / 2
        let amp = size.height / 2 * 0.86
        return Path { p in
            for (i, v) in pts.enumerated() where pts.count > 1 {
                let x = size.width * CGFloat(i) / CGFloat(pts.count - 1)
                let y = mid - CGFloat(v) * amp
                if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }

    private func envelopePath(size: CGSize) -> Path {
        let pts = data.envelope
        let mid = size.height / 2
        let amp = size.height / 2 * 0.86
        return Path { p in
            for (i, v) in pts.enumerated() where pts.count > 1 {
                let x = size.width * CGFloat(i) / CGFloat(pts.count - 1)
                let y = mid - CGFloat(v) * amp
                if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }

    private func envelopeFill(size: CGSize) -> Path {
        let pts = data.envelope
        let mid = size.height / 2
        let amp = size.height / 2 * 0.86
        return Path { p in
            p.move(to: CGPoint(x: 0, y: mid))
            for (i, v) in pts.enumerated() where pts.count > 1 {
                let x = size.width * CGFloat(i) / CGFloat(pts.count - 1)
                p.addLine(to: CGPoint(x: x, y: mid - CGFloat(v) * amp))
            }
            p.addLine(to: CGPoint(x: size.width, y: mid))
            p.closeSubpath()
        }
    }

    private func handleDot(at point: CGPoint, color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.2))
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
            .position(point)
    }
}
