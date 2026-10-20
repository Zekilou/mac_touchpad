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
    VERSION="2.1.3-dev"
    BUILD_NUM="$(date +%Y%m%d)"      # 日期构建号，区分不同 dev 包
else
    echo "==> [正式版] swift build -c release（不含诊断模块）"
    swift build --disable-sandbox -c release
    VERSION="2.1.3"
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
    <string>Touchpad Gestures reads raw trackpad data to recognize custom gestures.</string>
    <!-- 系统级本地化：权限弹窗 / Finder 简介由系统读 .lproj/InfoPlist.strings。
         主 plist 用英文兜底（CFBundleDevelopmentRegion=en），中文用户走
         Resources/zh-Hans.lproj/InfoPlist.strings 里的译文。 -->
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
</dict>
</plist>
EOF

# ── 系统级本地化资源（.lproj）────────────────────────────────────────────
# 应用内的 tr() 只覆盖自绘 UI；以下由 **系统** 渲染，只能走 .lproj：
#   - 首次授权时弹出的系统对话框（NSInputMonitoringUsageDescription）
#   - Finder「显示简介」里的名称/版本信息
# 没有 .lproj 时系统会退回 development region 的字符串 —— 英文用户
# 会在系统权限弹窗里看到一整句中文。
echo "==> 生成 .lproj 本地化资源"
mkdir -p "$APP_BUNDLE/Contents/Resources/en.lproj" \
         "$APP_BUNDLE/Contents/Resources/zh-Hans.lproj"

cat > "$APP_BUNDLE/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleDisplayName" = "Touchpad Gestures";
"CFBundleName" = "Touchpad Gestures";
"NSInputMonitoringUsageDescription" = "Touchpad Gestures reads raw trackpad data to recognize custom gestures. This permission is optional — trackpad gestures work without it.";
STRINGS

cat > "$APP_BUNDLE/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleDisplayName" = "Touchpad Gestures";
"CFBundleName" = "Touchpad Gestures";
"NSInputMonitoringUsageDescription" = "Touchpad Gestures 需要输入监控权限来读取触控板原始数据，用于识别自定义手势。（可选项，不授权也能正常使用触控板手势）";
STRINGS

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

// 图标由两部分组成：深色圆角底 + 白色手势图形。
//
// 历史问题：原实现只把 SF Symbol 填成白色、没有底色，导出的是白线稿。
// 在白底 Finder / Dock / 通知里几乎不可见，等于没有图标。
// 现在固定深色底（#1C1C1E，接近系统深灰），保证在任何背景上都有对比度。
let size = NSSize(width: 1024, height: 1024)
let img = NSImage(size: size)
img.lockFocus()

// macOS 图标惯例：留出约 10% 边距，主体是圆角矩形（非全出血）
let inset: CGFloat = 100
let bodyRect = NSRect(x: inset, y: inset,
                      width: size.width - inset * 2,
                      height: size.height - inset * 2)
let corner = bodyRect.width * 0.2237   // 接近 macOS Big Sur+ 的圆角比例

let path = NSBezierPath(roundedRect: bodyRect, xRadius: corner, yRadius: corner)

// 轻微渐变，避免大块纯色显得扁平
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.20, alpha: 1.0),
    NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1.0),
])
gradient?.draw(in: path, angle: -90)

// 手势图形：白色，占底色约 62%
//
// 注意：不能用 `fill(using: .sourceAtop)` 去染白——那会把**整个矩形**填白，
// 连刚画好的底色一起盖掉（曾经的 bug：导出图标变成一块白板）。
// 正确做法是把图形单独渲染到一张透明小图，对该图的**非透明像素**上色，再合成。
let config = NSImage.SymbolConfiguration(pointSize: 620, weight: .regular)
if let symbol = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let w = symbol.size.width
    let h = symbol.size.height

    let glyph = NSImage(size: NSSize(width: w, height: h))
    glyph.lockFocus()
    symbol.draw(in: NSRect(x: 0, y: 0, width: w, height: h),
                from: .zero, operation: .sourceOver, fraction: 1.0)
    // 只染这张小图的非透明部分
    NSColor.white.set()
    NSRect(x: 0, y: 0, width: w, height: h).fill(using: .sourceAtop)
    glyph.unlockFocus()

    let r = NSRect(x: (size.width - w) / 2,
                   y: (size.height - h) / 2,
                   width: w, height: h)
    glyph.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
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

# 把 dSYM 一起放进包里（Contents/Resources/dSYM）：
# 崩溃上报只带得到栈地址，没有 dSYM 就无法把地址还原成函数名/行号。
# 用户把这个文件夹连同报告一起给过来，就能定位到具体代码。
DSYM_SRC="$PROJECT_DIR/.build/$([ "$MODE" = "dev" ] && echo debug || echo release)/$APP_NAME.dSYM"
if [ -d "$DSYM_SRC" ]; then
    echo "==> 收集 dSYM（崩溃符号化用）"
    mkdir -p "$APP_BUNDLE/Contents/Resources/dSYM"
    cp -R "$DSYM_SRC" "$APP_BUNDLE/Contents/Resources/dSYM/"
    # 同时记录 UUID：服务端可用它匹配对应版本的 dSYM（符号文件无需随包分发）
    DWARF="$APP_BUNDLE/Contents/Resources/dSYM/$APP_NAME.dSYM/Contents/Resources/DWARF/$APP_NAME"
    if [ -f "$DWARF" ]; then
        dwarfdump --uuid "$DWARF" 2>/dev/null | sed 's/^/    UUID: /' || true
        dwarfdump --uuid "$DWARF" 2>/dev/null > "$APP_BUNDLE/Contents/Resources/dSYM/UUID.txt" || true
    fi
else
    # 变量用 ${} 括起来：`（$DSYM_SRC）` 里全角括号的 UTF-8 字节会被 bash 当成
    # 变量名的一部分 → set -u 下报 "DSYM_SRC\xef: unbound variable" 直接中断打包
    echo "[warn] 未找到 dSYM（${DSYM_SRC}），崩溃报告将无法符号化"
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
