#!/bin/bash
# 构建 TouchpadGestures.app 分发包
# 用法:
#   ./scripts/build_app.sh          → 正式版（release，无诊断模块）
#   ./scripts/build_app.sh dev      → 开发版（debug，含诊断模块，版本号 2.1.1-dev）
#   ./scripts/build_app.sh dev 输出目录
#
# -u：引用未定义变量直接报错（避免 rm -rf "$UNSET/..." 之类误删）
# -o pipefail：管道中任一环节失败即整体失败——否则 `codesign ... | tail` 的退出码
#   取自 tail，签名失败会被静默吞掉并打包出未签名 app（正是本脚本注释声称要修的问题）
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TouchpadGestures"
MODE="${1:-release}"                 # release（正式版）/ dev（开发版带诊断）
OUTPUT_DIR="${2:-$PROJECT_DIR/dist}"

# 必须先切到项目目录：swift build 作用于当前目录的包，
# 在别处调用（如 ./scripts/build_app.sh）会编译错误的包或直接失败
cd "$PROJECT_DIR"

if [ "$MODE" = "dev" ]; then
    echo "==> [开发版] swift build (debug，含诊断模块)"
    swift build --disable-sandbox
    VERSION="2.1.1-dev"
    BUILD_NUM="$(date +%Y%m%d)"      # 日期构建号，区分不同 dev 包
else
    echo "==> [正式版] swift build -c release（不含诊断模块）"
    swift build --disable-sandbox -c release
    VERSION="2.1.1"
    BUILD_NUM="1"
fi

# 注意：此处不再无条件补一次 release 构建——dev 模式只需 debug 产物，
# 多跑一次 release 会让 release 专属的编译错误中断 dev 打包，并让构建时间翻倍。

if [ "$MODE" = "dev" ]; then
    BINARY="$PROJECT_DIR/.build/debug/$APP_NAME"      # dev 构建产物在 debug 目录
else
    BINARY="$PROJECT_DIR/.build/release/$APP_NAME"
fi
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
# 临时目录：mktemp 保证唯一且不可被预置符号链接劫持；
# trap 确保异常退出也清理（原实现写死 /tmp/render_icon.swift，构造符号链接可覆写任意可写文件）
ICON_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tpg_icon.XXXXXX")"
trap 'rm -rf "$ICON_TMP"' EXIT

cat > "$ICON_TMP/render_icon.swift" <<'SWIFT'
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
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT
ICON_PNG="$ICON_TMP/AppIcon_1024.png"
swift -module-cache-path "$PROJECT_DIR/.build/modulecache" \
      "$ICON_TMP/render_icon.swift" "$ICON_PNG" || {
    echo "[warn] 图标渲染失败，跳过自定义图标（App 仍可正常使用）"
    rm -rf "$ICONSET"
    ICON_OK=0
}

# 生成各尺寸（仅当渲染成功时）
if [ "${ICON_OK:-1}" = "1" ] && [ -f "$ICON_PNG" ]; then
    for spec in "16 16" "32 16@2x" "32 32" "64 32@2x" "128 128" "256 128@2x" "256 256" "512 256@2x" "512 512" "1024 512@2x"; do
        # 不用 `set --`：那会覆盖脚本自身的位置参数（此处恰好无害，但是隐患）
        SIZE="${spec%% *}"
        NAME="${spec##* }"
        sips -z "$SIZE" "$SIZE" "$ICON_PNG" --out "$ICONSET/icon_$NAME.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || echo "[warn] iconutil 失败，跳过 icns"
    rm -rf "$ICONSET"
fi

# 解压后会出现 "已损坏" 提示：未签名 + com.apple.quarantine 属性导致 Gatekeeper 拦截
# ad-hoc 签名可消除 "damaged" 提示（仍会提示"无法验证开发者"，用户右键打开即可）
# 断言式签名：失败即让脚本终止（不再用管道 + `|| echo` —— 管道退出码取自 tail，
# 会把签名失败伪装成成功，最终打包出未签名 app）
echo "==> Ad-hoc 签名 (消除 damaged 提示)"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --verbose=1 "$APP_BUNDLE" 2>&1 | tail -3 || true

echo "==> 打包 DMG (拖入 Applications 安装)"
STAGING="$OUTPUT_DIR/dmg_staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

DMG_NAME="$APP_NAME.dmg"
[ "$MODE" = "dev" ] && DMG_NAME="$APP_NAME-dev.dmg"
rm -f "$OUTPUT_DIR/$DMG_NAME"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$OUTPUT_DIR/$DMG_NAME"
rm -rf "$STAGING"

echo "==> 完成"
echo "    App:   $APP_BUNDLE"
echo "    DMG:   $OUTPUT_DIR/$DMG_NAME"
echo ""
echo "    用户首次打开方式："
echo "    1. 双击挂载 DMG"
echo "    2. 把 TouchpadGestures.app 拖入「应用程序」"
echo "    3. 首次打开若被 Gatekeeper 拦截：右键 → 打开"
