// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mac_touchpad",
    platforms: [.macOS(.v12)],
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
        .executableTarget(
            name: "TouchpadGestures",
            dependencies: ["mt_bridge", "GestureEngine"],
            path: "Sources/TouchpadGestures",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("dl")
            ]
        ),

        // 单元测试
        .testTarget(
            name: "GestureEngineTests",
            dependencies: ["GestureEngine"],
            path: "Tests/GestureEngineTests"
        )
    ]
)
