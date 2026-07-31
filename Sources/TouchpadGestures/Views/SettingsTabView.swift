import SwiftUI
import GestureEngine

/// 设置 tab：全局触摸数据流 + 软件信息 + 触控板规格 + 启动 + 菜单栏图标 + App 图标 + 配置默认值 + 版权
struct SettingsTabView: View {
    @Binding var config: AppConfig
    @ObservedObject var appDelegate: AppDelegate
    @State private var showRestoreFactoryAlert = false
    @State private var showSavedAsDefault = false

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
    }
}
