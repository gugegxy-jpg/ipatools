#!/bin/bash
# 编译 ipatool 真机验证 Demo App 并打包成未签名的 .ipa
#
# 需要 macOS + Xcode 命令行工具（和 tweak/build.sh 一样），Linux/Windows 上无法编译。
# 产物：demo/build/IPATDemo.ipa（未签名，真机安装请用 Sideloadly / 爱思 / AltStore 重签）
set -euo pipefail

cd "$(dirname "$0")"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "错误：编译 iOS App 需要 macOS + Xcode 命令行工具（当前系统：$(uname -s)）" >&2
  exit 1
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"

APP="IPATDemo.app"
EXE="IPATDemo"
OUT="build"

BUNDLE="$OUT/Payload/$APP"   # IPA 必须是 Payload/xxx.app 结构

rm -rf "$OUT"
mkdir -p "$BUNDLE"

echo "编译 ${EXE} (arm64 / min iOS 14.0)"
"$CC" -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min=14.0 \
  -fobjc-arc -O2 -Wall \
  -Wl,-headerpad_max_install_names \
  -framework Foundation \
  -framework UIKit \
  -framework AVFoundation \
  -o "$BUNDLE/$EXE" \
  Demo.m

cp Info.plist "$BUNDLE/Info.plist"

# ad-hoc 签名只为让包结构完整；真机安装必须由重签工具换成开发者证书
codesign -f -s - "$BUNDLE" >/dev/null 2>&1 || echo "  提示: ad-hoc 签名失败（不影响后续注入）"

(cd "$OUT" && zip -qry "IPATDemo.ipa" Payload)

echo "已生成: demo/${OUT}/IPATDemo.ipa"
