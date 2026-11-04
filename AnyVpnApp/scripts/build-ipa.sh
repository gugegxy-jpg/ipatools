#!/usr/bin/env bash
#
# 生成 Xcode 工程并构建未签名 IPA（真机 arm64）。
# 签名需要 NetworkExtension capability 的描述文件，见 README。
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

# 构建期挡回归：Xcode 15+ 的 GENERATE_INFOPLIST_FILE 若被打开，会自动生成一份
# 不带 NSExtension 的 appex Info.plist，包装得出来但装不上真机
# （IXErrorDomain Code=17 "extensionDictionary must be set"）。
APPEX="$APP/PlugIns/PacketTunnel.appex"
if [ ! -f "$APPEX/Info.plist" ]; then
  echo "❌ 缺少 $APPEX/Info.plist" >&2
  exit 1
fi
if ! /usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionPointIdentifier" \
        "$APPEX/Info.plist" 2>/dev/null | grep -q "packet-tunnel"; then
  echo "❌ appex Info.plist 缺 NSExtension 字典：检查 GENERATE_INFOPLIST_FILE 是否为 NO" >&2
  exit 1
fi
echo "✅ appex NSExtension 校验通过"

OUT="$ROOT/out"
rm -rf "$OUT"
mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
(cd "$OUT" && zip -qr AnyVpnApp-unsigned.ipa Payload)
echo "产物：$OUT/AnyVpnApp-unsigned.ipa"
