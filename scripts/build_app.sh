#!/bin/bash
# 构建 TouchpadGestures.app 分发包
# 用法: ./scripts/build_app.sh [output_dir]
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TouchpadGestures"
VERSION="2.0.0"
BUILD_NUM="1"
OUTPUT_DIR="${1:-$PROJECT_DIR/dist}"

cd "$PROJECT_DIR"

echo "==> swift build -c release"
swift build -c release

BINARY="$PROJECT_DIR/.build/release/$APP_NAME"
if [ ! -f "$BINARY" ]; then
    echo "[ERROR] 构建产物未找到: $BINARY"
    exit 1
fi

APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
echo "==> 组装 .app bundle: $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Touchpad Gestures</string>
    <key>CFBundleDisplayName</key>
    <string>Touchpad Gestures</string>
    <key>CFBundleIdentifier</key>
    <string>com.zekiwithcat.TouchpadGestures</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUM</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 @zekiwithcat. All rights reserved.</string>
    <key>NSInputMonitoringUsageDescription</key>
    <string>Touchpad Gestures 需要输入监控权限来读取触控板原始数据，用于识别自定义手势。</string>
</dict>
</plist>
EOF

# PkgInfo
printf "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> 生成 App 图标 (hand.tap SF Symbol, 1024pt, 多倍率 icns)"
# 用 sips 从 SF Symbol 渲染生成 iconset
ICONSET="$APP_BUNDLE/Contents/Resources/AppIcon.iconset"
mkdir -p "$ICONSET"

# 生成临时 PNG（用 Swift 脚本渲染 SF Symbol 到多种尺寸）
cat > /tmp/render_icon.swift <<'SWIFT'
import AppKit
let size = NSSize(width: 1024, height: 1024)
let img = NSImage(size: size)
img.lockFocus()
let config = NSImage.SymbolConfiguration(pointSize: 700, weight: .regular)
if let symbol = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let r = NSRect(x: (size.width - symbol.size.width)/2,
                   y: (size.height - symbol.size.height)/2,
                   width: symbol.size.width, height: symbol.size.height)
    symbol.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
    NSColor.white.set()
    NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
}
img.unlockFocus()
img.isTemplate = false

let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "/tmp/AppIcon_1024.png"))
SWIFT
swift /tmp/render_icon.swift

# 生成各尺寸
for spec in "16 16" "32 16@2x" "32 32" "64 32@2x" "128 128" "256 128@2x" "256 256" "512 256@2x" "512 512" "1024 512@2x"; do
    set -- $spec
    SIZE=$1
    NAME=$2
    sips -z $SIZE $SIZE /tmp/AppIcon_1024.png --out "$ICONSET/icon_$NAME.png" >/dev/null 2>&1
done
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || echo "[warn] iconutil 失败，跳过 icns"
rm -rf "$ICONSET"

echo "==> 打包 zip"
cd "$OUTPUT_DIR"
rm -f "$APP_NAME.zip"
ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip"

# 解压后会出现 "已损坏" 提示：未签名 + com.apple.quarantine 属性导致 Gatekeeper 拦截
# ad-hoc 签名可消除 "damaged" 提示（仍会提示"无法验证开发者"，用户右键打开即可）
echo "==> Ad-hoc 签名 (消除 damaged 提示)"
codesign --force --deep --sign - "$APP_BUNDLE" 2>&1 | tail -5 || echo "[warn] codesign 失败"
codesign --verify --verbose=1 "$APP_BUNDLE" 2>&1 | tail -3 || true

# 重新打包签名后的版本
rm -f "$APP_NAME.zip"
ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip"

echo "==> 完成"
echo "    App:   $APP_BUNDLE"
echo "    Zip:   $OUTPUT_DIR/$APP_NAME.zip"
echo ""
echo "    用户首次打开方式："
echo "    1. 解压 zip"
echo "    2. 终端执行: xattr -cr TouchpadGestures.app"
echo "    3. 或右键 → 打开（绕过 Gatekeeper）"
