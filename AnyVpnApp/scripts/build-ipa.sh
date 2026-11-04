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

OUT="$ROOT/out"
rm -rf "$OUT"
mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
(cd "$OUT" && zip -qr AnyVpnApp-unsigned.ipa Payload)
echo "产物：$OUT/AnyVpnApp-unsigned.ipa"
