import SwiftUI
import GestureEngine

/// 区域 tab 内容区：矩形坐标 Slider + 2:1 可视化预览
struct RegionTabView: View {
    @Binding var config: AppConfig
    @Binding var selectedRegionID: UUID?

    private var selectedRegion: RegionConfig? {
        config.regions.first { $0.id == selectedRegionID } ?? config.regions.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let region = selectedRegion, let idx = config.regions.firstIndex(where: { $0.id == region.id }) {
                    Card(title: L10n.tr("名称", "Name")) {
                        HStack {
                            Text(L10n.tr("区域名", "Region Name")).frame(width: 150, alignment: .leading)
                            TextField("区域名", text: Binding(
                                get: { config.regions[idx].name },
                                set: { config.regions[idx].name = $0 }
                            ))
                            .frame(maxWidth: 200)
                            Spacer()
                        }
                    }

                    Card(title: L10n.tr("矩形坐标（归一化 0~1）", "Rectangle Coordinates (normalized 0~1)")) {
                        sliderRow(L10n.tr("xMin", "xMin"),
                                  value: Binding(get: { config.regions[idx].xMin }, set: { config.regions[idx].xMin = $0 }),
                                  minVal: 0, maxVal: 1)
                        sliderRow(L10n.tr("xMax", "xMax"),
                                  value: Binding(get: { config.regions[idx].xMax }, set: { config.regions[idx].xMax = $0 }),
                                  minVal: 0, maxVal: 1)
                        sliderRow(L10n.tr("yMin", "yMin"),
                                  value: Binding(get: { config.regions[idx].yMin }, set: { config.regions[idx].yMin = $0 }),
                                  minVal: 0, maxVal: 1)
                        sliderRow(L10n.tr("yMax", "yMax"),
                                  value: Binding(get: { config.regions[idx].yMax }, set: { config.regions[idx].yMax = $0 }),
                                  minVal: 0, maxVal: 1)
                    }

                    Card(title: L10n.tr("可视化预览", "Visual Preview")) {
                        RegionPreview(region: region)
                            .frame(maxWidth: .infinity)
                            .frame(height: 200)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Float>, minVal: Float, maxVal: Float) -> some View {
        HStack {
            Text(label).frame(width: 150, alignment: .leading)
            Slider(value: value, in: minVal...maxVal)
            Text(String(format: "%.2f", value.wrappedValue))
                .monospacedDigit().frame(width: 50, alignment: .trailing)
        }
    }
}

/// 区域可视化预览：2:1 触控板示意图 + 半透明色块
struct RegionPreview: View {
    let region: RegionConfig

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.1)))

                let rectX = CGFloat(region.xMin) * w
                let rectY = CGFloat(region.yMin) * h
                let rectW = CGFloat(region.xMax - region.xMin) * w
                let rectH = CGFloat(region.yMax - region.yMin) * h
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.accentColor, lineWidth: 1)
                    )
                    .frame(width: rectW, height: rectH)
                    .offset(x: rectX, y: rectY)
            }
        }
        .aspectRatio(2, contentMode: .fit)
    }
}
