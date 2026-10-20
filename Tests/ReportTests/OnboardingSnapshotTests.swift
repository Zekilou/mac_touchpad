import XCTest
import SwiftUI
import AppKit
@testable import TouchpadGestures
import GestureEngine

// MARK: - 引导页快照（人工确认排版用）

@MainActor
final class OnboardingSnapshotTests: XCTestCase {

    func testRenderOnboarding() throws {
        let perm = PermissionManager()
        let host = NSHostingView(rootView: OnboardingView(
            permissionManager: perm,
            appVersion: "2.1.3",
            onFinish: {}))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 460)

        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let outDir = URL(fileURLWithPath: "/tmp/touchpad-report-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try png.write(to: outDir.appendingPathComponent("onboarding.png"))
        print("[snapshot] \(outDir.appendingPathComponent("onboarding.png").path)")
    }
}
