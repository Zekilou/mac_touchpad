import SwiftUI
import GestureEngine

// MARK: - Primary Tab

enum PrimaryTab: String, CaseIterable, Identifiable, Hashable {
    case gestures, events, regions, morphology, settings

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .gestures: return L10n.tr("手势", "Gestures")
        case .events:   return L10n.tr("事件", "Events")
        case .regions:  return L10n.tr("区域", "Regions")
        case .morphology: return L10n.tr("形态识别", "Morphology")
        case .settings: return L10n.tr("设置", "Settings")
        }
    }

    var sfSymbol: String {
        switch self {
        case .gestures: return "hand.tap"
        case .events:   return "bolt.fill"
        case .regions:  return "rectangle.dashed"
        case .morphology: return "hand.point.up.left"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Delete Target

enum DeleteTarget: Equatable {
    case event(UUID)
    case region(UUID)
}

// MARK: - ConfigView
// NavigationSplitView 作为窗口根视图（官方左右分栏组件）
// - sidebar：一级导航，底部 Reset All（safeAreaInset）
// - detail：二级 TabView（tab bar 在上，内容在下）
// - 不用 .toolbar（避免创建标题栏区域）
// - 窗口配置 titlebarAppearsTransparent，sidebar 模糊背景延伸到顶部

struct ConfigView: View {
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        NavigationSplitView {
            // ── 左栏：一级导航 ──
            List(selection: $appDelegate.currentEditingTab) {
                ForEach(PrimaryTab.allCases) { tab in
                    Label(tab.localizedName, systemImage: tab.sfSymbol)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    // 权限状态指示器（常驻）
                    PermissionStatusBar()
                        .environmentObject(appDelegate.permissionManager)

                    HStack {
                        Spacer()
                        Button {
                            appDelegate.showResetAllAlert = true
                        } label: {
                            Label(L10n.tr("重置全部", "Reset All"),
                                  systemImage: "arrow.counterclockwise")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(L10n.tr("重置所有手势配置为默认值",
                                     "Reset all gesture settings to defaults"))
                        Spacer()
                    }
                }
                .padding(.vertical, 8)
            }
        } detail: {
            // ── 右栏：二级导航 + 内容 ──
            DetailContent()
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        // 设置类页（设置/形态识别）不显示增删改编辑菜单
                        if appDelegate.currentEditingTab != .settings
                            && appDelegate.currentEditingTab != .morphology {
                            EditMenu(tab: appDelegate.currentEditingTab)
                        }
                    }
                }
        }
        .onChange(of: appDelegate.config) { _, newValue in
            appDelegate.updateConfig(newValue)
        }
        // ── Alerts ──
        .alert(L10n.tr("确认重置全部配置？", "Reset all settings?"),
               isPresented: $appDelegate.showResetAllAlert) {
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
            Button(L10n.tr("重置", "Reset"), role: .destructive) {
                appDelegate.config = ConfigStore.loadDefault()
            }
        } message: {
            Text(L10n.tr("所有配置将恢复为默认值，此操作不可撤销。",
                        "All settings will be restored to defaults. This cannot be undone."))
        }
        .alert(L10n.tr("重命名", "Rename"),
               isPresented: $appDelegate.showRenameAlert) {
            TextField(L10n.tr("名称", "Name"), text: $appDelegate.renameText)
            Button(L10n.tr("取消", "Cancel"), role: .cancel) { appDelegate.renameText = "" }
            Button(L10n.tr("好", "OK")) { appDelegate.performRename() }
        }
        .alert(L10n.tr("确认删除？", "Delete?"),
               isPresented: $appDelegate.showDeleteAlert) {
            Button(L10n.tr("取消", "Cancel"), role: .cancel) { appDelegate.pendingDelete = nil }
            Button(L10n.tr("删除", "Delete"), role: .destructive) {
                appDelegate.performConfirmedDelete()
            }
        } message: {
            if let target = appDelegate.pendingDelete {
                let count = appDelegate.boundGestureCount(for: target)
                Text(L10n.tr("\(count) 个手势将解绑并重新绑定。此操作不可撤销。",
                            "\(count) gesture(s) will be rebound. This cannot be undone."))
            }
        }
    }
}

// MARK: - 右栏：二级导航 + 内容

struct DetailContent: View {
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        Group {
            switch appDelegate.currentEditingTab {
            case .gestures: GesturesDetail()
            case .events:   EventsDetail()
            case .regions:  RegionsDetail()
            case .morphology: MorphologyDetail()
            case .settings: SettingsDetail()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 二级 Tab 详情页
// TabView 天然结构：上面 tab bar，下面内容

/// 手势二级
struct GesturesDetail: View {
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        TabView(selection: $appDelegate.selectedGestureID) {
            ForEach(appDelegate.config.gestures) { g in
                Tab(value: g.id) {
                    GestureTabView(config: $appDelegate.config,
                                  selectedGestureID: .constant(g.id))
                } label: {
                    Text(g.name)
                }
            }
        }
        .onChange(of: appDelegate.config.gestures.count) { _, _ in
            if !appDelegate.config.gestures.contains(where: { $0.id == appDelegate.selectedGestureID }) {
                appDelegate.selectedGestureID = appDelegate.config.gestures.first?.id
            }
        }
    }
}

/// 事件二级
struct EventsDetail: View {
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        TabView(selection: $appDelegate.selectedEventID) {
            ForEach(appDelegate.config.events) { e in
                Tab(value: e.id) {
                    EventTabView(config: $appDelegate.config,
                                selectedEventID: .constant(e.id))
                } label: {
                    Text(e.name)
                }
            }
        }
        .onChange(of: appDelegate.config.events.count) { _, _ in
            if !appDelegate.config.events.contains(where: { $0.id == appDelegate.selectedEventID }) {
                appDelegate.selectedEventID = appDelegate.config.events.first?.id
            }
        }
    }
}

/// 区域二级
struct RegionsDetail: View {
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        TabView(selection: $appDelegate.selectedRegionID) {
            ForEach(appDelegate.config.regions) { r in
                Tab(value: r.id) {
                    RegionTabView(config: $appDelegate.config,
                                 selectedRegionID: .constant(r.id))
                } label: {
                    Text(r.name)
                }
            }
        }
        .onChange(of: appDelegate.config.regions.count) { _, _ in
            if !appDelegate.config.regions.contains(where: { $0.id == appDelegate.selectedRegionID }) {
                appDelegate.selectedRegionID = appDelegate.config.regions.first?.id
            }
        }
    }
}

/// 设置（无二级 tab）
struct SettingsDetail: View {
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        SettingsTabView(config: $appDelegate.config, appDelegate: appDelegate)
    }
}

// MARK: - EditMenu

struct EditMenu: View {
    @EnvironmentObject var appDelegate: AppDelegate
    let tab: PrimaryTab

    var body: some View {
        Menu {
            Button(action: { appDelegate.addItem() }) {
                Label(L10n.tr("新增", "New"), systemImage: "plus")
            }
            Divider()
            if let name = appDelegate.currentSecondaryName {
                Button(action: { appDelegate.startRename() }) {
                    Label(L10n.tr("重命名「\(name)」", "Rename \"\(name)\""),
                          systemImage: "pencil")
                }
                Button(role: .destructive, action: { appDelegate.requestDelete() }) {
                    Label(L10n.tr("删除「\(name)」", "Delete \"\(name)\""),
                          systemImage: "trash")
                }
                .disabled(!appDelegate.canDeleteSecondary)
            }
        } label: {
            Label(L10n.tr("编辑", "Edit"), systemImage: "ellipsis.circle")
        }
        .help(L10n.tr("新增、重命名或删除", "Add, rename or delete"))
    }
}

// MARK: - 权限状态指示器（侧栏常驻）

struct PermissionStatusBar: View {
    @EnvironmentObject var permManager: PermissionManager

    var body: some View {
        VStack(spacing: 4) {
            permRow(
                label: L10n.tr("输入监控", "Input Monitoring"),
                status: permManager.inputMonitoring,
                isOK: permManager.inputMonitoring.isOK,
                action: { permManager.openInputMonitoringSettings() }
            )
            permRow(
                label: L10n.tr("辅助功能", "Accessibility"),
                status: permManager.accessibility,
                isOK: permManager.accessibility.isOK,
                action: { permManager.openAccessibilitySettings() }
            )

            // 媒体键测试按钮
            if permManager.allGranted {
                Button {
                    SystemControl.volumeUp()
                } label: {
                    Label(L10n.tr("测试媒体键", "Test Media Key"),
                          systemImage: "speaker.wave.2")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func permRow(label: String, status: PermissionStatus, isOK: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: status.symbolName)
                    .foregroundColor(colorFor(status))
                    .font(.system(size: 12))
                Text(label)
                    .font(.system(size: 11))
                Spacer()
                Text(status.label)
                    .font(.system(size: 10))
                    .foregroundColor(colorFor(status))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func colorFor(_ status: PermissionStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied:  return .red
        case .unknown: return .orange
        }
    }
}
