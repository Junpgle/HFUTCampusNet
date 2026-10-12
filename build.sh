#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

echo "🔨 开始构建 HFUTCampusNet (通用架构 Universal arm64 + x86_64)..."

APP_NAME="HFUTCampusNet"
BUNDLE_DIR="$DIR/${APP_NAME}.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
CACHE_DIR="$DIR/.swift_cache"

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$CACHE_DIR"

SOURCES=(
    "HFUTCampusNet/Models.swift"
    "HFUTCampusNet/ElectricityModels.swift"
    "HFUTCampusNet/CourseModels.swift"
    "HFUTCampusNet/EmptyClassroomModels.swift"
    "HFUTCampusNet/AcademicAndCardModels.swift"
    "HFUTCampusNet/CampusHistoryManager.swift"
    "HFUTCampusNet/ElectricityService.swift"
    "HFUTCampusNet/CampusCardService.swift"
    "HFUTCampusNet/CourseScheduleService.swift"
    "HFUTCampusNet/EmptyClassroomService.swift"
    "HFUTCampusNet/AcademicService.swift"
    "HFUTCampusNet/CourseLoginWebViewController.swift"
    "HFUTCampusNet/UnifiedLoginWebViewController.swift"
    "HFUTCampusNet/CourseScheduleWindowController.swift"
    "HFUTCampusNet/EmptyClassroomWindowController.swift"
    "HFUTCampusNet/AcademicWindowController.swift"
    "HFUTCampusNet/HistoryStatsWindowController.swift"
    "HFUTCampusNet/SettingsManager.swift"
    "HFUTCampusNet/NotificationHelper.swift"
    "HFUTCampusNet/UpdateChecker.swift"
    "HFUTCampusNet/NetworkSpeedMonitor.swift"
    "HFUTCampusNet/PortalAuthService.swift"
    "HFUTCampusNet/CampusNetworkClient.swift"
    "HFUTCampusNet/DesktopWidgetController.swift"
    "HFUTCampusNet/LoginWebViewController.swift"
    "HFUTCampusNet/SettingsWindowController.swift"
    "HFUTCampusNet/MenubarController.swift"
    "HFUTCampusNet/main.swift"
)

echo "📦 正在编译 Apple Silicon (arm64) 架构..."
swiftc -target arm64-apple-macosx12.0 -module-cache-path "$CACHE_DIR" -O "${SOURCES[@]}" -o "$MACOS_DIR/${APP_NAME}_arm64"

echo "📦 正在编译 Intel (x86_64) 架构..."
swiftc -target x86_64-apple-macosx12.0 -module-cache-path "$CACHE_DIR" -O "${SOURCES[@]}" -o "$MACOS_DIR/${APP_NAME}_x86_64"

echo "🔀 正在合成 Universal 通用二进制..."
lipo -create "$MACOS_DIR/${APP_NAME}_arm64" "$MACOS_DIR/${APP_NAME}_x86_64" -output "$MACOS_DIR/$APP_NAME"
rm -f "$MACOS_DIR/${APP_NAME}_arm64" "$MACOS_DIR/${APP_NAME}_x86_64"

echo "📝 正在生成 Info.plist 与复制应用图标..."
if [ -f "$DIR/HFUTCampusNet/AppIcon.icns" ]; then
    cp "$DIR/HFUTCampusNet/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>HFUTCampusNet</string>
    <key>CFBundleIdentifier</key>
    <string>cn.edu.hfut.campusnet.monitor</string>
    <key>CFBundleName</key>
    <string>HFUT校园网助手</string>
    <key>CFBundleDisplayName</key>
    <string>HFUT校园网助手</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.8.2</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

chmod +x "$MACOS_DIR/$APP_NAME"

echo "🔏 正在执行标准 Ad-Hoc 代码签名封装..."
codesign --force --deep --sign - "$BUNDLE_DIR"

echo "📦 正在打包发布压缩包 HFUTCampusNet-macOS.zip..."
rm -f "$DIR/HFUTCampusNet-macOS.zip"
ditto -c -k --keepParent "$BUNDLE_DIR" "$DIR/HFUTCampusNet-macOS.zip"

if [ "${SKIP_APP_INSTALL:-0}" != "1" ] && [ -d "/Applications/${APP_NAME}.app" ]; then
    echo "🔄 正在同步更新 /Applications/${APP_NAME}.app..."
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$BUNDLE_DIR" "/Applications/${APP_NAME}.app"
    codesign --force --deep --sign - "/Applications/${APP_NAME}.app"
elif [ "${SKIP_APP_INSTALL:-0}" == "1" ]; then
    echo "⏭️  已设置 SKIP_APP_INSTALL=1，跳过 /Applications 覆盖安装。"
fi

echo "✅ 构建成功！生成通用架构应用："
echo "   👉 $BUNDLE_DIR"
echo "   👉 /Applications/${APP_NAME}.app"
echo "   👉 $DIR/HFUTCampusNet-macOS.zip"
file "$MACOS_DIR/$APP_NAME"

