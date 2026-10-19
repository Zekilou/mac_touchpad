// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "mac_touchpad",
    platforms: [.macOS(.v15)],
    targets: [
        // IOKit HID 早期探索版本（保留作参考）
        .executableTarget(
            name: "TrackpadHIDTool",
            path: "Sources/TrackpadHIDTool",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),

        // MultitouchSupport C 桥接层
        .target(
            name: "mt_bridge",
            path: "Sources/mt_bridge",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include")
            ],
            linkerSettings: [
                .linkedLibrary("dl"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),

        // 手势引擎库
        .target(
            name: "GestureEngine",
            dependencies: ["mt_bridge"],
            path: "Sources/GestureEngine",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit")
            ]
        ),

        // SwiftUI 菜单栏 App（主产品）
        // 错误上报（Diagnostics/）也在这个 target 内——它需要 AppKit/SwiftUI 上下文，
        // 单测通过 @testable import 直接覆盖其中的纯逻辑（指纹/脱敏/请求构造/队列）。
        .executableTarget(
            name: "TouchpadGestures",
            dependencies: ["mt_bridge", "GestureEngine"],
            path: "Sources/TouchpadGestures",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CryptoKit"),
                .linkedLibrary("dl")
            ]
        ),

        // 本地验收工具（起 HTTP 服务收客户端真实请求，校验上报契约）
        .executableTarget(
            name: "ReportProbe",
            dependencies: ["GestureEngine"],
            path: "Tools/ReportProbe"
        ),

        // 单元测试
        .testTarget(
            name: "GestureEngineTests",
            dependencies: ["GestureEngine"],
            path: "Tests/GestureEngineTests"
        ),

        .testTarget(
            name: "ReportTests",
            dependencies: ["TouchpadGestures"],
            path: "Tests/ReportTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
