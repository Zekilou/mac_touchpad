# Touchpad Gestures

> 一个 macOS 菜单栏 App，通过自定义触控板手势调节系统音量与亮度。
> 双击触控板边缘保持滑动，或 Force 按压保持滑动，精确调节，带刻度震动反馈。

![platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)
![language](https://img.shields.io/badge/language-Swift%205.9-orange)
![license](https://img.shields.io/badge/license-MIT-green)

## 功能

- **双击边缘保持 + 滑动**：右边缘调音量、左边缘调亮度
- **Force 按压手势**：重按边缘保持进入调节（压力阈值 / 保持时长可调，带迟滞防抖）
- **系统 HUD 联动**：媒体键模式自动唤起系统音量/亮度指示框
- **刻度震动反馈**：滑动每格一次轻震动，可独立配置波形/次数/间隔
- **节点图画布编辑器**：整张手势行为（识别/信号/震动/鼠标）用 Blender 风格节点图可视化编辑，支持模块折叠、自动整理、框选复制粘贴
- **基础设置页**：卡片式高层配置（绑定/识别/信号/触觉），与画布双向同步，降低学习成本
- **语言切换**：跟随系统 / 中文 / English，即时生效
- **形态识别**：独立一级设置页——手指识别（接触面积范围）+ 手掌过滤开关 + 触摸阶段参考
- **手势启用开关**：每个手势可独立启用/禁用，立即生效
- **边界检测**：到达 0% / 100% 时值自然停住（系统 clamp），不会卡中间
- **鼠标锁定**：手势期间光标原地不动，避免误触
- **完全可配置**：所有参数暴露在 UI 中，支持单项重置 / 全局重置 / 保存为默认
- **菜单栏图标 / App 图标颜色 / Dock 显示开关 / 开机自启动**

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
3. **双击边缘**：快速双击触控板右/左边缘并保持 → 上下滑动调节
4. **Force 按压**：重按触控板右/左边缘并保持（压力 ≥ 阈值持续 0.3s）→ 上下滑动调节
5. 到达 0% / 100% 时值停住，继续滑动不会卡死，反向滑动立即恢复

## 配置说明

设置窗口左侧为一级导航：

| 页 | 内容 |
|------|------|
| **手势** | 基础设置（绑定/识别/信号处理/触觉反馈）或高级画布（节点图编辑） |
| **事件** | 动作目标（音量/亮度）、方向映射、执行方式（媒体键/直接 API）、步长、边界阈值 |
| **区域** | 手势触发区域矩形坐标 + 可视化预览 |
| **形态识别** | 手指识别（接触面积范围）、手掌过滤开关、触摸阶段参考 |
| **设置** | 语言、触摸数据流、软件信息、启动、菜单栏图标、App 图标、配置默认值 |

## 技术实现

- **MultitouchSupport.framework**（Apple 私有框架）：`dlopen`/`dlsym` 动态加载，避开 ARM64e PAC 指针认证，获取 96 字节/手指的 `MTTouch` 结构化数据
- **C 桥接层** (`mt_bridge`)：设备发现、触摸回调、触觉反馈
- **节点图执行引擎** (`GestureEngine`)：手势 = 单张自由节点图；识别状态机（轻点/双击/Force/计时/漂移）、信号管线（变换/量化）、反馈（震动/调节/鼠标）全部是图节点；摩尔状态机语义（帧首读旧值 / 帧尾统一写）；固定步长帧循环（Godot 式，MT 回调只更新快照）
- **媒体键模拟**：`NX_SYSDEFINED` 系统事件触发系统 HUD
- **鼠标锁定**：`CGAssociateMouseAndMouseCursorPosition` + 每帧 `CGWarpMouseCursorPosition`

## 致谢

本项目借鉴了 [MatMercer/mactic](https://github.com/MatMercer/mactic)（MIT License）的 MultitouchSupport 桥接实现，包括 `MTTouch` struct 字段布局与 deviceID 获取方法。

## 风险声明

- 使用 Apple 私有框架，任何 macOS 更新可能改变 struct 偏移或函数签名
- 不追求 App Store 兼容性
- 仅供个人使用

## License

MIT License — Copyright © 2026 @zekiwithcat
