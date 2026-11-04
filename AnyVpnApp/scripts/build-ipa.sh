#!/usr/bin/env bash
#
# 生成 Xcode 工程并构建未签名 IPA（真机 arm64）。
# 真机安装前需用自己的证书给 App 和 appex 分别签名，描述文件必须带
# NetworkExtension (packet-tunnel-provider) capability。
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

bash "$HERE/build-openconnect-ios.sh"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "缺少 xcodegen，请先：brew install xcodegen" >&2
  exit 1
fi
xcodegen generate

# 诊断：确认 target 级真的在用我们手写的 Info.plist（曾出现只在 project 级
# 设 GENERATE_INFOPLIST_FILE=NO 被 target 级覆盖的情况）
for T in PacketTunnel AnyVpnApp; do
  echo ">>> build settings: $T"
  xcodebuild -project AnyVpnApp.xcodeproj -target "$T" \
    -configuration Release -showBuildSettings 2>/dev/null \
    | grep -E "GENERATE_INFOPLIST_FILE|INFOPLIST_FILE|INFOPLIST_EXPAND_BUILD_SETTINGS" || true
done

xcodebuild -project AnyVpnApp.xcodeproj \
  -scheme AnyVpnApp -configuration Release \
  -sdk iphoneos -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build

APP="$ROOT/build/Build/Products/Release-iphoneos/AnyVpnApp.app"
if [ ! -d "$APP" ]; then
  echo "没找到构建产物 $APP" >&2
  exit 1
fi

# Xcode 15+ 的 GENERATE_INFOPLIST_FILE 会自动生成一份不带 NSExtension 的
# appex Info.plist：包能编出来，但装真机时报 IXErrorDomain Code=17
# "extensionDictionary must be set in placeholder attributes"。
# 工程里已显式关掉；这里再做一次构建后补齐 + 校验，兜住任何工程配置回归。
# IPA 未签名，改 plist 不会影响后续重签。
APPEX="$APP/PlugIns/PacketTunnel.appex"
APPEX_PLIST="$APPEX/Info.plist"
PB=/usr/libexec/PlistBuddy
if [ ! -f "$APPEX_PLIST" ]; then
  echo "❌ 缺少 $APPEX_PLIST" >&2
  exit 1
fi
if ! "$PB" -c "Print :NSExtension:NSExtensionPointIdentifier" \
        "$APPEX_PLIST" 2>/dev/null | grep -q "packet-tunnel"; then
  echo ">>> 构建产物缺 NSExtension，补写扩展字典"
  "$PB" -c "Delete :NSExtension" "$APPEX_PLIST" 2>/dev/null || true
  "$PB" -c "Add :NSExtension dict" "$APPEX_PLIST"
  "$PB" -c "Add :NSExtension:NSExtensionPointIdentifier string com.apple.networkextension.packet-tunnel" "$APPEX_PLIST"
  "$PB" -c "Add :NSExtension:NSExtensionPrincipalClass string PacketTunnel.PacketTunnelProvider" "$APPEX_PLIST"
fi
if ! "$PB" -c "Print :NSExtension:NSExtensionPointIdentifier" \
        "$APPEX_PLIST" 2>/dev/null | grep -q "packet-tunnel"; then
  echo "❌ appex Info.plist 仍缺 NSExtension 字典" >&2
  exit 1
fi
echo "✅ appex NSExtension 校验通过"

# App 的 Info.plist 必须带 UILaunchScreen：缺了 iOS 会用 3.5 寸兼容模式跑，
# 屏幕上下留黑块（用户反馈"只有中间区域显示内容"）。这里强校验。
APP_PLIST="$APP/Info.plist"
if [ ! -f "$APP_PLIST" ]; then
  echo "❌ 缺少 $APP_PLIST" >&2
  exit 1
fi
if ! "$PB" -c "Print :UILaunchScreen" "$APP_PLIST" >/dev/null 2>&1; then
  echo "❌ App Info.plist 缺 UILaunchScreen（会上下黑块）" >&2
  exit 1
fi
if ! "$PB" -c "Print :UISupportedInterfaceOrientations" "$APP_PLIST" >/dev/null 2>&1; then
  echo "❌ App Info.plist 缺 UISupportedInterfaceOrientations" >&2
  exit 1
fi
echo "✅ App Info.plist 校验通过（UILaunchScreen / 方向支持）"

OUT="$ROOT/out"
rm -rf "$OUT"
mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
(cd "$OUT" && zip -qr AnyVpnApp-unsigned.ipa Payload)
echo "产物：$OUT/AnyVpnApp-unsigned.ipa"
