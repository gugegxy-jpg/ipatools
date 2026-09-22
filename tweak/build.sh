#!/usr/bin/env bash
#
# 编译注入用的 dylib（悬浮控制面板 / 文件导入导出 / 弱网测试）。需要 macOS + Xcode 命令行工具：
#   xcode-select --install
#
#   ./tweak/build.sh                               默认出 IPATool.dylib + QNet.dylib
#   IPATOOL_TARGETS="ControlPanel FileBridge QNet" ./tweak/build.sh   只编译指定目标（单独出包）
#
# 默认两个产物：
#   - IPATool.dylib  = ControlPanel + FileBridge（悬浮面板 / 文件导入导出）
#   - QNet.dylib      = 弱网测试，单独一个 dylib（见下）
# 说明：运行时「插件加载」(PluginLoader) 已从默认合编里移除 —— iOS 从沙盒 Documents 加载
# dylib 必须有 disable-library-validation（系统强约束，很多开发描述文件不放行），
# 故默认不再编入；需要该能力时单独出 PluginLoader.dylib 并经越狱/TrollStore 等环境安装。
# QNet 单独出包：它和面板之间只用「通知 + NSUserDefaults」通信（IPATControlShared.h），
# 不链接彼此符号，所以单独编成 QNet.dylib、靠 --qnet 注入 Frameworks 或运行时当插件加载都行，
# 加载后自己 post IPATControlRegister，面板就会多出弱网那一节。这样改 QNet 不用重编主 dylib。
#
# 可通过环境变量调整：
#   IPATOOL_MIN_IOS   最低系统版本，默认 14.0
#   IPATOOL_ARCHS     架构列表，默认 "arm64"（可写 "arm64 arm64e"）
#   IPATOOL_OUT_DIR   产物目录，默认 tweak/build
#   IPATOOL_TARGETS   目标列表，默认 "IPATool QNet"；也可写单个功能名
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${IPATOOL_OUT_DIR:-$HERE/build}"
MIN_IOS="${IPATOOL_MIN_IOS:-14.0}"
ARCHS="${IPATOOL_ARCHS:-arm64}"
TARGETS="${IPATOOL_TARGETS:-IPATool QNet}"

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

# 把悬浮按钮图标（tweak/AppIcon20x20@2x.png）编码成 C 字节数组编进 dylib，
# 运行时通过 [UIImage imageWithData:scale:2.0] 加载，不需要额外资源 bundle
ICON_PNG="$HERE/AppIcon20x20@2x.png"
ICON_M="$OUT_DIR/IPAToolIcon.m"
python3 - "$ICON_PNG" "$ICON_M" <<'PY'
import sys, pathlib
png_path = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])
if png_path.is_file():
    data = png_path.read_bytes()
    rows = [f"    0x{b:02x}," for b in data]
    if rows:
        rows[-1] = rows[-1].rstrip(",")
    body = "\n".join(rows) if rows else ""
    icon_data = (
        "static const unsigned char kIPAToolIconBytes[] = {\n"
        + body + "\n"
        + "};\n"
    )
else:
    icon_data = "static const unsigned char kIPAToolIconBytes[] = {0};\n"
out_path.write_text(
    "#include <Foundation/Foundation.h>\n"
    "#include <UIKit/UIKit.h>\n"
    "\n"
    + icon_data
    + "\n"
    "NSData *IPAToolIconImageData(void) {\n"
    "    return [NSData dataWithBytesNoCopy:(void *)kIPAToolIconBytes length:sizeof(kIPAToolIconBytes) freeWhenDone:NO];\n"
    "}\n"
    "\n"
    "UIImage *IPAToolIconImage(void) {\n"
    "    NSData *data = IPAToolIconImageData();\n"
    "    return data ? [UIImage imageWithData:data scale:2.0] : nil;\n"
    "}\n"
)
PY

ARCH_FLAGS=()
for arch in $ARCHS; do
  ARCH_FLAGS+=(-arch "$arch")
done

# 目标 -> 源文件列表（合并目标 IPATool 把三份源码编进同一个 dylib）
sources_for_target() {
  case "$1" in
    IPATool)
      printf '%s\n' "$HERE/ControlPanel.m" "$HERE/FileBridge.m" "$OUT_DIR/IPAToolIcon.m"
      ;;
    *)
      if [[ "$1" == "ControlPanel" ]]; then
        printf '%s\n' "$HERE/$1.m" "$OUT_DIR/IPAToolIcon.m"
      else
        printf '%s\n' "$HERE/$1.m"
      fi
      ;;
  esac
}

# 源文件 -> 还需要额外链接的框架（合并目标取各源文件依赖的并集）
frameworks_for_source() {
  case "$(basename "$1" .m)" in
    # UniformTypeIdentifiers 是 iOS 14 才有的框架，用 weak 链接兼容更低的部署目标
    FileBridge)  printf '%s\n' -weak_framework UniformTypeIdentifiers -lz ;;
  esac
}

build_target() {
  local name="$1"
  local out="$OUT_DIR/$name.dylib"
  local line flag
  local -a srcs=()
  local -a extra=()

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ ! -f "$line" ]]; then
      echo "跳过 $name：找不到 $line" >&2
      return 1
    fi
    srcs+=("$line")
    while IFS= read -r flag; do
      if [[ -n "$flag" ]]; then extra+=("$flag"); fi
    done < <(frameworks_for_source "$line")
  done < <(sources_for_target "$name")

  if [[ ${#srcs[@]} -eq 0 ]]; then
    echo "跳过 $name：没有源文件" >&2
    return 1
  fi

  echo "编译 $name: min-iOS=$MIN_IOS archs=$ARCHS 源码=${#srcs[@]} 个"

  # 注意两点：
  # 1) 新版 iOS SDK 里 UIKit 不再间接导出 CoreGraphics 的 C 符号，用到
  #    CGBitmapContextCreate / CGAffineTransform* / CGRectGet* 必须显式链接 CoreGraphics；
  # 2) 必须用 if ! 显式判失败：build_target 是作为 `... || status=1` 的左操作数调用的，
  #    在那种上下文里 bash 会禁用函数内的 set -e，链接失败会被静默吞掉（还会误报"已生成"）。
  if ! xcrun -sdk iphoneos clang \
    -dynamiclib -fobjc-arc -O2 \
    "${ARCH_FLAGS[@]}" \
    -mios-version-min="$MIN_IOS" \
    -isysroot "$SDK" \
    -framework Foundation -framework UIKit -framework CoreGraphics \
    -framework QuartzCore \
    ${extra[@]+"${extra[@]}"} \
    -install_name "@executable_path/Frameworks/$name.dylib" \
    -o "$out" "${srcs[@]}"; then
    echo "编译失败: $name - 详见上方 clang 输出" >&2
    return 1
  fi

  # 先用 ad-hoc 签名占位，正式签名由 ipatool 重签时用 codesign/zsign 覆盖
  if [[ -f "$out" ]] && command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$out" >/dev/null 2>&1 || true
  fi

  echo "已生成: $out"
}

status=0
for target in $TARGETS; do
  build_target "$target" || status=1
done
exit "$status"
