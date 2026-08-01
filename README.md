# Touchpad Gestures

> 一个 macOS 菜单栏 App，通过自定义触控板手势调节系统音量与亮度。
> 双击触控板边缘 + 保持 + 上下滑动，即可精确调节，带刻度震动反馈。

![platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)
![language](https://img.shields.io/badge/language-Swift%205.9-orange)
![license](https://img.shields.io/badge/license-MIT-green)

## 功能

- **右侧边缘双击保持 + 上下滑动**：调节系统音量
- **左侧边缘双击保持 + 上下滑动**：调节屏幕亮度
- **系统 HUD 联动**：调节时自动唤起系统音量/亮度指示框
- **刻度震动反馈**：每滑动一格触发一次轻震动，边界触发强震动
- **边界检测**：到达 0% / 100% 时强震动提示并冻结手势
- **鼠标锁定**：手势期间光标原地不动，避免误触
- **面积过滤**：通过接触面积过滤手掌误触（可配置上下限）
- **完全可配置**：所有参数暴露在 UI 中，支持单项重置 / 全局重置 / 保存为默认
- **国际化**：根据系统语言自动切换中英文
- **菜单栏图标**：SF Symbol 可自定义（默认 `hand.tap`）
- **App 图标颜色**：10 个预设色板 + RGB 自定义
- **Dock 显示开关**：菜单栏 App 与普通 App 模式自由切换
- **开机自启动**：通过 System Events 登录项管理

## 截图

> 手势设置 tab（7 张参数卡片 + 触觉波形对照）+ 软件设置 tab（软件信息 / 触控板规格 / 启动 / 菜单栏图标 / App 图标 / 配置默认值）

## 系统要求

- macOS 15 (Sequoia) 或更高
- MacBook 内置触控板（MultitouchSupport.framework 兼容机型）
- 需授予「输入监控」权限（读取触控板数据）
- 使用「系统媒体键」模式需额外授予「辅助功能」权限（模拟媒体键触发 HUD）

## 下载安装

### 方式一：直接下载 Release（推荐）

1. 前往 [Releases](https://github.com/Zekilou/mac_touchpad/releases) 下载最新版 `TouchpadGestures.app.zip`
2. 解压后拖入「应用程序」文件夹
3. 首次运行在「系统设置 → 隐私与安全性 → 输入监控」中授予权限
4. 使用「系统媒体键」模式还需在「辅助功能」中添加并启用 TouchpadGestures

### 方式二：从源码构建

```bash
git clone https://github.com/Zekilou/mac_touchpad.git
cd mac_touchpad
swift run TouchpadGestures
```

## 使用方法

1. 启动后菜单栏出现 `hand.tap` 图标
2. 点击图标 → 「设置...」打开配置界面
3. 双击触控板右边缘并保持 → 上下滑动调节音量
4. 双击触控板左边缘并保持 → 上下滑动调节亮度
5. 到达边界会有强震动提示

### 手势流程

```
idle → firstTapDown → firstTapUp → secondTapDown → holding → idle
                                                     ↓
                                            上下滑动调节 + 刻度震动
                                            边界冻结 + 强震动
```

## 配置参数

所有参数都在设置 UI 中可调，按手势执行流程分 7 组：

| 分组 | 参数 |
|------|------|
| 1. 触摸数据流 | 帧限频、接触面积上下限 |
| 2. 第一次轻点 | 边缘阈值、最长轻点时长、最大位移容差 |
| 3. 两次轻点衔接 | 两次轻点间隔 |
| 4. 第二次轻点保持 | 保持确认时长、进入反馈波形 |
| 5. 滑动调节 | 音量/亮度滑动刻度、变化量、刻度波形 |
| 6. 边界检测 | 边界阈值、边界波形、震动间隔 |
| 7. 鼠标控制 | 解除鼠标关联开关 |
| 8. 触觉波形对照 | waveform ID ↔ 触感 ↔ 项目用途 |

## 技术实现

- **MultitouchSupport.framework**（Apple 私有框架）：通过 `dlopen`/`dlsym` 动态加载，避开 ARM64e PAC 指针认证问题，获取 96 字节/手指的 `MTTouch` 结构化数据
- **C 桥接层** (`mt_bridge`)：封装设备发现、触摸回调、触觉反馈，暴露最小 C API 给 Swift
- **手势状态机** (`GestureEngine`)：左右边缘独立状态机，支持位移容差、超时冷却、面积过滤
- **媒体键模拟**：发送 `NX_SYSDEFINED` 系统事件触发系统 HUD
- **鼠标锁定**：进入 holding 时记录光标位置，每帧 `CGWarpMouseCursorPosition` 钉回原位

## 致谢

本项目借鉴了 [MatMercer/mactic](https://github.com/MatMercer/mactic)（MIT License）的 MultitouchSupport 桥接实现，包括 `MTTouch` struct 字段布局与 deviceID 获取方法。

## 风险声明

- 使用 Apple 私有框架，任何 macOS 更新可能改变 struct 偏移或函数签名
- 不追求 App Store 兼容性
- 仅供个人使用

## License

MIT License — Copyright © 2026 @zekiwithcat
