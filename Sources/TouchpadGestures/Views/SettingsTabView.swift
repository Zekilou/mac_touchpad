import SwiftUI
import AppKit
import GestureEngine

/// 设置 tab：全局触摸数据流 + 软件信息 + 触控板规格 + 启动 + 菜单栏图标 + App 图标 + 配置默认值 + 版权
struct SettingsTabView: View {
    @Binding var config: AppConfig
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject private var reportCenter = ReportCenter.shared
    @State private var showRestoreFactoryAlert = false
    @State private var showSavedAsDefault = false
    @State private var showDiagAlert = false
    @State private var diagResult = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // 全局触摸数据流
                    Card(title: L10n.tr("触摸数据流", "Touch Data Stream")) {
                        HStack {
                            Text(L10n.tr("帧处理限频 (Hz)", "Frame Rate Limit (Hz)"))
                                .frame(width: 150, alignment: .leading)
                            Slider(value: $config.global.frameRateLimit, in: 0...240)
                            Text(config.global.frameRateLimit < 1 ? L10n.tr("不限", "off") : String(format: "%.0f", config.global.frameRateLimit))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                        HStack {
                            Text(L10n.tr("接触面积下限", "Touch Size Min"))
                                .frame(width: 150, alignment: .leading)
                            Slider(value: $config.global.touchSizeMin, in: 0...0.5)
                            Text(String(format: "%.2f", config.global.touchSizeMin))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                        HStack {
                            Text(L10n.tr("接触面积上限", "Touch Size Max"))
                                .frame(width: 150, alignment: .leading)
                            Slider(value: $config.global.touchSizeMax, in: 0.5...2.0)
                            Text(String(format: "%.2f", config.global.touchSizeMax))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                    }

                    // 软件信息
                    Card(title: L10n.tr("软件信息", "App Info")) {
                        HStack {
                            Text(L10n.tr("名称", "Name")).frame(width: 150, alignment: .leading)
                            Text("Touchpad Gestures")
                            Spacer()
                        }
                        HStack {
                            Text(L10n.tr("版本", "Version")).frame(width: 150, alignment: .leading)
                            Text("\(appDelegate.appVersion) (\(appDelegate.appBuild))").monospacedDigit()
                            Spacer()
                        }
                    }

                    // 语言（跟随系统/中文/英文；修改即时生效，@Published 通知全部 UI 重算）
                    Card(title: L10n.tr("语言", "Language")) {
                        HStack {
                            Text(L10n.tr("界面语言", "UI Language")).frame(width: 150, alignment: .leading)
                            Picker(L10n.tr("界面语言", "UI Language"), selection: Binding(
                                get: { appDelegate.appSettings.language },
                                set: { appDelegate.appSettings.language = $0 }
                            )) {
                                ForEach(AppLanguage.allCases, id: \.self) { lang in
                                    Text(lang.displayName).tag(lang)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            Spacer()
                        }
                    }

                    // 触控板规格
                    Card(title: L10n.tr("触控板规格", "Trackpad Spec")) {
                        HStack {
                            Text(L10n.tr("检测到的设备数", "Detected Devices")).frame(width: 150, alignment: .leading)
                            Text("\(appDelegate.trackpadDeviceCount)").monospacedDigit()
                            Spacer()
                        }
                        HStack {
                            Text(L10n.tr("设备 ID", "Device ID")).frame(width: 150, alignment: .leading)
                            Text(String(format: "%llu", appDelegate.trackpadDeviceID)).monospacedDigit().textSelection(.enabled)
                            Spacer()
                        }
                        HStack {
                            Text(L10n.tr("引擎状态", "Engine")).frame(width: 150, alignment: .leading)
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(appDelegate.engineIsRunning ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(appDelegate.engineIsRunning
                                     ? L10n.tr("运行中 (120Hz)", "Running (120Hz)")
                                     : L10n.tr("未运行", "Not running"))
                                    .font(.caption)
                            }
                            Spacer()
                        }
                        // 每手势健康：红点 = 该手势被引擎静默跳过（"权限正常但无反馈"定位断点）
                        ForEach(appDelegate.gestureHealth) { h in
                            HStack(spacing: 5) {
                                Circle()
                                    .fill((h.enabled && h.boundOK && h.graphOK) ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(h.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                if !h.enabled { statusTag(L10n.tr("已禁用", "Disabled"), color: .orange) }
                                if !h.boundOK { statusTag(L10n.tr("绑定无效", "Binding broken"), color: .red) }
                                if !h.graphOK { statusTag(L10n.tr("图无效", "Invalid graph"), color: .red) }
                                Spacer()
                            }
                        }
                    }

                    // 诊断日志（发布版可用——"权限全绿但无反馈"时开日志定位数据流断点）
                    Card(title: L10n.tr("诊断日志", "Diagnostics Log")) {
                        HStack {
                            Text(L10n.tr("启用日志", "Enable Logging")).frame(width: 150, alignment: .leading)
                            Toggle("", isOn: Binding(
                                get: { appDelegate.debugLoggingEnabled },
                                set: { appDelegate.debugLoggingEnabled = $0 }
                            )).labelsHidden()
                            Spacer()
                        }
                        Text(L10n.tr("开启后在触控板上操作，日志实时写入 /tmp/touchpad_run.log，终端执行 tail -f /tmp/touchpad_run.log 即可观察手指/量化/进入 holding 的数据流。排障完成后关闭。",
                                    "While enabled, gesture data flows are written to /tmp/touchpad_run.log in real time. Run `tail -f /tmp/touchpad_run.log` in Terminal. Turn off after troubleshooting."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // 启动
                    Card(title: L10n.tr("启动", "Startup")) {
                        HStack {
                            Text(L10n.tr("登录时自动启动", "Launch at login")).frame(width: 150, alignment: .leading)
                            Toggle("", isOn: Binding(
                                get: { appDelegate.appSettings.launchAtLogin },
                                set: { newVal in
                                    appDelegate.appSettings.launchAtLogin = newVal
                                    appDelegate.setLaunchAtLogin(newVal)
                                }
                            )).labelsHidden()
                            Spacer()
                        }
                        HStack {
                            Text(L10n.tr("在 Dock 中显示", "Show in Dock")).frame(width: 150, alignment: .leading)
                            Toggle("", isOn: Binding(
                                get: { appDelegate.appSettings.showInDock },
                                set: { newVal in
                                    appDelegate.appSettings.showInDock = newVal
                                    appDelegate.applyDockPolicy()
                                }
                            )).labelsHidden()
                            Spacer()
                        }
                    }

                    // 菜单栏图标
                    Card(title: L10n.tr("菜单栏图标", "Menu Bar Icon")) {
                        HStack {
                            Text(L10n.tr("图标 (SF Symbol)", "Icon (SF Symbol)")).frame(width: 150, alignment: .leading)
                            TextField("hand.tap", text: Binding(
                                get: { appDelegate.appSettings.menuBarIcon },
                                set: { newVal in
                                    appDelegate.appSettings.menuBarIcon = newVal
                                    appDelegate.applyMenuBarIcon()
                                }
                            ))
                            .frame(maxWidth: 200)
                            Spacer()
                        }
                        HStack {
                            Text(L10n.tr("图标尺寸", "Icon Size")).frame(width: 150, alignment: .leading)
                            Slider(value: Binding(
                                get: { appDelegate.appSettings.menuBarIconSize },
                                set: { newVal in
                                    appDelegate.appSettings.menuBarIconSize = newVal
                                    appDelegate.applyMenuBarIcon()
                                }
                            ), in: 10...24)
                            Text(String(format: "%.0f", appDelegate.appSettings.menuBarIconSize))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                    }

                    // App 图标
                    Card(title: L10n.tr("App 图标", "App Icon")) {
                        HStack {
                            Text(L10n.tr("颜色", "Color")).frame(width: 150, alignment: .leading)
                            ForEach([
                                (NSColor.white, "白"), (NSColor.black, "黑"),
                                (NSColor.systemRed, "红"), (NSColor.systemOrange, "橙"),
                                (NSColor.systemYellow, "黄"), (NSColor.systemGreen, "绿"),
                                (NSColor.systemCyan, "青"), (NSColor.systemBlue, "蓝"),
                                (NSColor.systemPurple, "紫"), (NSColor.systemPink, "粉"),
                            ], id: \.1) { color, _ in
                                Circle()
                                    .fill(Color(nsColor: color))
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().stroke(.separator, lineWidth: 0.5))
                                    .onTapGesture {
                                        appDelegate.appSettings.appIconColorRed = Double(color.redComponent)
                                        appDelegate.appSettings.appIconColorGreen = Double(color.greenComponent)
                                        appDelegate.appSettings.appIconColorBlue = Double(color.blueComponent)
                                        appDelegate.applyAppIcon()
                                    }
                            }
                            Spacer()
                        }
                    }

                    // 配置默认值
                    Card(title: L10n.tr("配置默认值", "Config Defaults")) {
                        HStack {
                            Button(L10n.tr("保存当前为默认", "Save as Default")) {
                                ConfigStore.saveAsDefault(config)
                                showSavedAsDefault = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Spacer()
                        }
                        HStack {
                            Button(L10n.tr("恢复代码默认值", "Restore Factory Defaults")) {
                                showRestoreFactoryAlert = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.red)
                            Spacer()
                        }
                        Text(L10n.tr("「保存为默认」后，重置全部将恢复到此配置；「恢复代码默认值」会清除自定义默认。",
                                    "After 'Save as Default', 'Reset All' restores to this config; 'Restore Factory Defaults' clears the custom default."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // 反馈与诊断（正式版可用）
                    Card(title: L10n.tr("反馈与诊断", "Feedback & Diagnostics")) {
                        HStack {
                            Text(L10n.tr("自动收集错误", "Collect errors automatically"))
                                .frame(width: 150, alignment: .leading)
                            Toggle("", isOn: Binding(
                                get: { reportCenter.autoCollectEnabled },
                                set: { reportCenter.setAutoCollect($0) }
                            )).labelsHidden().toggleStyle(.switch)
                            Spacer()
                        }
                        Text(L10n.tr("开启后只在本地记录崩溃与错误；发送前一定会先问你。",
                                    "When on, crashes and errors are kept locally. Nothing is sent without asking you first."))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Button(L10n.tr("报告问题…", "Report a Problem…")) {
                                ReportWindowController.shared.show(manual: true)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button(L10n.tr("导出诊断包…", "Export Diagnostics…")) {
                                exportDiagnostics()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Spacer()
                        }

                        HStack(spacing: 10) {
                            if !reportCenter.issues.isEmpty {
                                Label(L10n.tr("\(reportCenter.issues.count) 个问题待处理",
                                              "\(reportCenter.issues.count) issue(s) pending"),
                                      systemImage: "exclamationmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            if reportCenter.pendingUploadCount > 0 {
                                Label(L10n.tr("\(reportCenter.pendingUploadCount) 份报告待发送",
                                              "\(reportCenter.pendingUploadCount) report(s) queued"),
                                      systemImage: "arrow.up.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        Text(L10n.tr("报告发送到 \(ReportScope.endpoint.host ?? "debug.zeki.casa")，仅用于定位问题。",
                                    "Reports are sent to \(ReportScope.endpoint.host ?? "debug.zeki.casa"), used only to diagnose issues."))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            // 底部固定版权声明
            Divider()
            VStack(alignment: .center, spacing: 2) {
                Text("Copyright © 2026 @zekiwithcat")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(L10n.tr("基于 Apple MultitouchSupport 私有框架，仅用于个人使用。",
                            "Built on Apple MultitouchSupport private framework, for personal use only."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.tr("借鉴 MatMercer/mactic 项目（MIT License）。",
                            "Inspired by MatMercer/mactic (MIT License)."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .alert(L10n.tr("确认恢复代码默认值？", "Restore factory defaults?"),
               isPresented: $showRestoreFactoryAlert) {
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
            Button(L10n.tr("恢复", "Restore"), role: .destructive) {
                ConfigStore.clearUserDefault()
                config = AppConfig()
            }
        } message: {
            Text(L10n.tr("将清除自定义默认配置并恢复到代码默认值，此操作不可撤销。",
                        "This clears the custom default and restores to factory defaults. This cannot be undone."))
        }
        .alert(L10n.tr("已保存为默认", "Saved as Default"),
               isPresented: $showSavedAsDefault) {
            Button(L10n.tr("好", "OK"), role: .cancel) {}
        } message: {
            Text(L10n.tr("当前配置已保存为默认，重置全部时将恢复到此配置。",
                        "Current config saved as default. 'Reset All' will restore to this."))
        }
        .alert(L10n.tr("诊断包", "Diagnostics Package"),
               isPresented: $showDiagAlert) {
            Button(L10n.tr("好", "OK"), role: .cancel) {}
        } message: {
            Text(diagResult)
        }
    }

    /// 健康状态小标签（手势健康列表用）
    @ViewBuilder
    private func statusTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundColor(color)
    }

    // MARK: - 诊断导出（正式版可用）

    /// 选目录 → 生成诊断包文件夹 → 提示用户手动发送给开发者
    /// 这是「不想上传」时的替代方案：内容与上报一致，只是走文件。
    private func exportDiagnostics() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L10n.tr("选择导出位置", "Choose folder")
        panel.message = L10n.tr("选择保存诊断包的文件夹", "Choose a folder to save the diagnostics package")
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            let host = reportCenter.hostInfo()
            let env = host.map { DiagnosticsCollector.environmentText(from: $0) } ?? ""
            let configData = try? JSONEncoder().encode(appDelegate.config)
            let files = DiagnosticsExporter.writeDiagnostics(
                to: url,
                includeConfig: true,
                includeLogs: true,
                includeCrash: true,
                environment: env,
                configData: configData)
            diagResult = files.isEmpty
                ? L10n.tr("导出失败，请重试。", "Export failed, please retry.")
                : L10n.tr("已生成 \(files.count) 个文件：\n\(files.joined(separator: "\n"))\n\n请将文件夹发送给开发者。",
                          "\(files.count) files written:\n\(files.joined(separator: "\n"))\n\nSend the folder to the developer.")
            showDiagAlert = true
        }
    }
}
