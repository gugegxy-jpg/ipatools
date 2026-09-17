#!/usr/bin/env bash
#
# 编译注入用的 dylib（画中画 / 后台保活 / 悬浮控制面板 / 文件导入导出）。需要 macOS + Xcode 命令行工具：
#   xcode-select --install
#
#   ./tweak/build.sh                               编译全部（四个目标）
#   IPATOOL_TARGETS=KeepAlive ./tweak/build.sh     只编译指定目标
#
# 可通过环境变量调整：
#   IPATOOL_MIN_IOS   最低系统版本，默认 14.0（画中画内置画面源需要 iOS 15+）
#   IPATOOL_ARCHS     架构列表，默认 "arm64"（可写 "arm64 arm64e"）
#   IPATOOL_OUT_DIR   产物目录，默认 tweak/build
#   IPATOOL_TARGETS   目标列表，默认 "PiPBackground KeepAlive ControlPanel FileBridge"
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${IPATOOL_OUT_DIR:-$HERE/build}"
MIN_IOS="${IPATOOL_MIN_IOS:-14.0}"
ARCHS="${IPATOOL_ARCHS:-arm64}"
TARGETS="${IPATOOL_TARGETS:-PiPBackground KeepAlive ControlPanel FileBridge}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "错误：编译 iOS dylib 需要 macOS + Xcode 命令行工具（当前系统：$(uname -s)）" >&2
  exit 1
fi
if ! command -v xcrun >/dev/null 2>&1; then
  echo "错误：找不到 xcrun，请先安装 Xcode 命令行工具：xcode-select --install" >&2
  exit 1
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p "$OUT_DIR"

ARCH_FLAGS=()
for arch in $ARCHS; do
  ARCH_FLAGS+=(-arch "$arch")
done

build_target() {
  local name="$1"
  local src="$HERE/$name.m"
  local out="$OUT_DIR/$name.dylib"
  local extra=()

  if [[ ! -f "$src" ]]; then
    echo "跳过 $name：找不到 $src" >&2
    return 1
  fi

  case "$name" in
    PiPBackground) extra=(-weak_framework AVKit) ;;
    KeepAlive)     extra=(-framework CoreLocation -weak_framework BackgroundTasks) ;;
    ControlPanel)  extra=() ;;
    # UniformTypeIdentifiers 是 iOS 14 才有的框架，用 weak 链接兼容更低的部署目标
    FileBridge)    extra=(-weak_framework UniformTypeIdentifiers) ;;
  esac

  echo "编译 $name: min-iOS=$MIN_IOS archs=$ARCHS"
  xcrun -sdk iphoneos clang \
    -dynamiclib -fobjc-arc -O2 \
    "${ARCH_FLAGS[@]}" \
    -mios-version-min="$MIN_IOS" \
    -isysroot "$SDK" \
    -framework Foundation -framework UIKit -framework AVFoundation \
    -framework CoreMedia -framework CoreVideo -framework QuartzCore \
    ${extra[@]+"${extra[@]}"} \
    -install_name "@executable_path/Frameworks/$name.dylib" \
    -o "$out" "$src"

  # 先用 ad-hoc 签名占位，正式签名由 ipatool 重签时用 codesign/zsign 覆盖
  if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$out" >/dev/null 2>&1 || true
  fi

  echo "已生成: $out"
}

status=0
for target in $TARGETS; do
  build_target "$target" || status=1
done
exit "$status"
