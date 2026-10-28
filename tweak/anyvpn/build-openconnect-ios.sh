#!/usr/bin/env bash
#
# 交叉编译 libopenconnect / OpenSSL / libxml2（iOS arm64 静态库）
#
# 在 macOS + Xcode 命令行工具环境跑（GitHub Actions macos runner 也可以）：
#   ./tweak/anyvpn/build-openconnect-ios.sh
#
# 产物落到 tweak/anyvpn/prebuilt/{lib,include}/，tweak/build.sh 的 AnyVpn
# 目标从这里取库链接进 AnyVpn.dylib。
#
# 与 Android 端（build-openconnect-android.sh）的两点差异：
#   1) 工具链换成 xcrun/iphoneos SDK，目标 aarch64-apple-darwin；
#   2) OpenSSL 用 1.1.1w 而不是 3.0.x —— 3.0 把 SSL_OP_LEGACY_SERVER_CONNECT
#      从默认选项去掉了，老网关握手会失败，Android 端靠 GNU ld 的 --wrap
#      拦截 SSL_CTX_new 补选项，但 iOS 的 ld64 不支持 --wrap，静态库内部
#      又是直接调用拦不进去，所以干脆用 1.1.1（该选项默认开启）。
#
set -euo pipefail

ARCH="${IPATOOL_ARCH:-arm64}"
MIN_IOS="${IPATOOL_MIN_IOS:-14.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/prebuilt"
WORK="${ANYVPN_BUILD_WORK:-$HERE/.build}"

case "$ARCH" in
  arm64)  TRIPLE=aarch64-apple-darwin; OPENSSL_TARGET=ios64-cross ;;
  arm64e) TRIPLE=aarch64-apple-darwin; OPENSSL_TARGET=ios64-cross ;;
  *) echo "不支持的架构：$ARCH" >&2; exit 1 ;;
esac

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="xcrun -sdk iphoneos clang -arch $ARCH -mios-version-min=$MIN_IOS"

mkdir -p "$WORK" "$OUT"
cd "$WORK"

fetch() { [ -d "$1" ] || git clone --depth 1 --branch "$3" "$2" "$1"; }
fetch openconnect https://gitlab.com/openconnect/openconnect.git v9.12
fetch openssl     https://github.com/openssl/openssl.git         openssl-1.1.1w
fetch libxml2     https://gitlab.gnome.org/GNOME/libxml2.git     v2.12.4
fetch lwip        https://github.com/lwip-tcpip/lwip.git         STABLE-2_1_3

PREFIX="$WORK/prefix-$ARCH"
LOGF="$WORK/build-$ARCH.log"
: > "$LOGF"

# --- OpenSSL（静态库；ios64-cross 读 CROSS_SYSROOT）-----------------------
export CROSS_SYSROOT="$SDK"
export CROSS_TOP="$(dirname "$(dirname "$SDK")")"
if [ -f "$PREFIX/lib/libcrypto.a" ] && [ -f "$PREFIX/lib/libssl.a" ]; then
  echo ">>> OpenSSL 已构建，跳过"
else
  pushd openssl
    make clean >>"$LOGF" 2>&1 || true
    ./Configure "$OPENSSL_TARGET" --prefix="$PREFIX" \
        no-shared no-tests no-asm no-hw -fPIC \
        -arch "$ARCH" -mios-version-min="$MIN_IOS" \
        CC="$CC" >>"$LOGF" 2>&1
    make -j"$(sysctl -n hw.ncpu)" build_libs >>"$LOGF" 2>&1
    make install_sw >>"$LOGF" 2>&1
  popd
fi

# --- libxml2（openconnect 解析认证 XML 必需）-------------------------------
if [ -f "$PREFIX/lib/libxml2.a" ]; then
  echo ">>> libxml2 已构建，跳过"
else
  pushd libxml2
    [ -f configure ] || NOCONFIGURE=1 ./autogen.sh >>"$LOGF" 2>&1
    make clean >>"$LOGF" 2>&1 || true
    ./configure --host="$TRIPLE" --prefix="$PREFIX" \
        --without-python --without-lzma --without-zlib \
        --enable-static --disable-shared \
        CC="$CC" CFLAGS="-fPIC" >>"$LOGF" 2>&1
    make -j"$(sysctl -n hw.ncpu)" >>"$LOGF" 2>&1 && make install >>"$LOGF" 2>&1
  popd
fi

# --- openconnect -----------------------------------------------------------
pushd openconnect
  [ -f configure ] || NOCONFIGURE=1 ./autogen.sh >>"$LOGF" 2>&1
  make clean >>"$LOGF" 2>&1 || true
  PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
  ./configure --host="$TRIPLE" --prefix="$PREFIX" \
      --with-openssl="$PREFIX" \
      --without-gnutls --without-libpskc --without-stoken \
      --without-liboath --without-lz4 \
      --enable-static --disable-shared \
      --with-vpnc-script=/etc/vpnc/vpnc-script \
      --disable-nls \
      CC="$CC" \
      CFLAGS="-I$PREFIX/include -fPIC" LDFLAGS="-L$PREFIX/lib" >>"$LOGF" 2>&1
  make -j"$(sysctl -n hw.ncpu)" libopenconnect.la >>"$LOGF" 2>&1
popd

# --- lwIP（非越狱模式的用户态 TCP/IP 栈；NO_SYS 单线程，见 tweak/lwipopts.h）---
if [ -f "$PREFIX/lib/liblwip.a" ]; then
  echo ">>> lwIP 已构建，跳过"
else
  pushd lwip
    mkdir -p lwip-obj
    pushd lwip-obj >/dev/null
      rm -f ./*.o
      # 用 tweak/ 下的 lwipopts.h / arch/cc.h / arch/perf.h（本脚本在 tweak/anyvpn/ 下）
      EXTRA_INC="-I$HERE/.."
      for f in ../src/core/*.c ../src/core/ipv4/*.c; do
        [ -e "$f" ] || continue
        $CC -c "$f" -I../src/include $EXTRA_INC -o "$(basename "${f%.c}").o" >>"$LOGF" 2>&1
      done
      xcrun -sdk iphoneos ar rcs "$PREFIX/lib/liblwip.a" ./*.o
    popd >/dev/null
  popd
fi

# --- 收集产物：libtool 的嵌套归档要展开重打（同 Android 端的处理）----------
OC_OBJ="$WORK/oc-obj-$ARCH"
rm -rf "$OC_OBJ"
mkdir -p "$OC_OBJ"
pushd "$OC_OBJ" >/dev/null
  xcrun -sdk iphoneos ar x "$WORK/openconnect/.libs/libopenconnect.a"
  rm -f ./*.a
  xcrun -sdk iphoneos ar rcs libopenconnect.a ./*.o
popd >/dev/null

DEST="$OUT"
mkdir -p "$DEST/lib" "$DEST/include"

cp -L "$OC_OBJ/libopenconnect.a" "$DEST/lib/"
cp -L "$PREFIX/lib/libssl.a"    "$DEST/lib/"
cp -L "$PREFIX/lib/libcrypto.a" "$DEST/lib/"
cp -L "$PREFIX/lib/libxml2.a"   "$DEST/lib/"
cp -L "$PREFIX/lib/liblwip.a"   "$DEST/lib/"

cp "$WORK/openconnect/openconnect.h" "$DEST/include/"
cp -r "$PREFIX/include/openssl" "$DEST/include/" || true
cp -r "$PREFIX/include/libxml2" "$DEST/include/" || true
# lwIP 头文件：包含目录里要能以 "lwip/init.h" 形式找到
cp -r "$WORK/lwip/src/include/lwip" "$DEST/include/" || true

echo "产出: $DEST/lib/(libopenconnect.a libssl.a libcrypto.a libxml2.a liblwip.a)"
ls -l "$DEST/lib"
echo "完成。接下来 ./tweak/build.sh 会把 AnyVpn.dylib 链接出来。"
