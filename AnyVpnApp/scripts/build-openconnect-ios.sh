#!/usr/bin/env bash
#
# 交叉编译 libopenconnect / OpenSSL / libxml2（iOS arm64 静态库）
# 产物落到 AnyVpnApp/Vendor/openconnect/{lib,include}，由 Xcode 工程链接。
#
# 相对 tweak/anyvpn/build-openconnect-ios.sh 的差别：不编译 lwIP。
# 独立 App 直接用系统协议栈，不需要用户态 TCP/IP 栈，也不需要
# -Dudp_connect=... 那个规避符号冲突的宏。
#
# 在 macOS + Xcode 命令行工具下运行（GitHub Actions macos runner 亦可）。
#
set -euo pipefail

ARCH="${ANYVPN_ARCH:-arm64}"
MIN_IOS="${ANYVPN_MIN_IOS:-14.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$ROOT/Vendor/openconnect"
WORK="${ANYVPN_BUILD_WORK:-$ROOT/.build-openconnect}"

# CI 缓存命中时直接跳过（缓存只收 OUT，不收 WORK）
if [ -f "$OUT/lib/libopenconnect.a" ] && [ -f "$OUT/lib/libssl.a" ] \
   && [ -f "$OUT/lib/libcrypto.a" ] && [ -f "$OUT/lib/libxml2.a" ] \
   && [ -f "$OUT/include/openconnect.h" ]; then
  echo ">>> openconnect 静态库已齐备，跳过编译：$OUT"
  exit 0
fi

case "$ARCH" in
  arm64|arm64e) TRIPLE=aarch64-apple-darwin; OPENSSL_TARGET=ios64-cross ;;
  *) echo "不支持的架构：$ARCH" >&2; exit 1 ;;
esac

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="xcrun -sdk iphoneos clang -arch $ARCH -mios-version-min=$MIN_IOS"

mkdir -p "$WORK" "$OUT/lib" "$OUT/include"
cd "$WORK"

fetch() { [ -d "$1" ] || git clone --depth 1 --branch "$3" "$2" "$1"; }
fetch openconnect https://gitlab.com/openconnect/openconnect.git v9.12
# 1.1.1 的 tag 是驼峰 OpenSSL_1_1_1w（openssl-x.y.z 是 3.x 的命名）
fetch openssl     https://github.com/openssl/openssl.git         OpenSSL_1_1_1w
fetch libxml2     https://gitlab.gnome.org/GNOME/libxml2.git     v2.12.4

PREFIX="$WORK/prefix-$ARCH"
LOGF="$WORK/build-$ARCH.log"
: > "$LOGF"

# OpenSSL 3.0 把 SSL_OP_LEGACY_SERVER_CONNECT 从默认选项里去掉了，老网关
# 握手会失败；Android 端靠 GNU ld --wrap 补，iOS ld64 不支持，所以固定 1.1.1w。
if ! command -v autoreconf >/dev/null 2>&1 || ! command -v automake >/dev/null 2>&1 \
   || ! command -v libtoolize >/dev/null 2>&1; then
  echo ">>> 安装 autoconf/automake/libtool"
  brew install autoconf automake libtool pkg-config || true
fi

export CROSS_SDK="$(basename "$SDK")"
export CROSS_TOP="$(dirname "$(dirname "$SDK")")"
export CROSS_SYSROOT="$SDK"

if [ -f "$PREFIX/lib/libcrypto.a" ] && [ -f "$PREFIX/lib/libssl.a" ]; then
  echo ">>> OpenSSL 已构建，跳过"
else
  pushd openssl
    make clean 2>&1 | tee -a "$LOGF" || true
    ./Configure "$OPENSSL_TARGET" --prefix="$PREFIX" \
        no-shared no-tests no-asm no-hw \
        CC="$CC" CFLAGS="-fPIC" 2>&1 | tee -a "$LOGF"
    make -j"$(sysctl -n hw.ncpu)" build_libs 2>&1 | tee -a "$LOGF"
    make install_sw 2>&1 | tee -a "$LOGF"
  popd
fi

if [ -f "$PREFIX/lib/libxml2.a" ]; then
  echo ">>> libxml2 已构建，跳过"
else
  pushd libxml2
    [ -f configure ] || NOCONFIGURE=1 ./autogen.sh 2>&1 | tee -a "$LOGF"
    make clean 2>&1 | tee -a "$LOGF" || true
    ./configure --host="$TRIPLE" --prefix="$PREFIX" \
        --without-python --without-lzma --without-zlib \
        --enable-static --disable-shared \
        CC="$CC" CFLAGS="-fPIC" 2>&1 | tee -a "$LOGF"
    make -j"$(sysctl -n hw.ncpu)" 2>&1 | tee -a "$LOGF" && make install 2>&1 | tee -a "$LOGF"
  popd
fi

pushd openconnect
  [ -f configure ] || NOCONFIGURE=1 ./autogen.sh >>"$LOGF" 2>&1
  make clean >>"$LOGF" 2>&1 || true
  # configure 只在 DIR 下直接找 libssl.a/libcrypto.a（不查 DIR/lib/）
  PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
  ./configure --host="$TRIPLE" --prefix="$PREFIX" \
      --with-openssl="$PREFIX/lib" \
      --without-gnutls --without-libpskc --without-stoken \
      --without-lz4 --without-libpcsclite \
      --enable-static --disable-shared \
      --with-vpnc-script=/etc/vpnc/vpnc-script \
      --disable-nls \
      CC="$CC" \
      CFLAGS="-I$PREFIX/include -fPIC" LDFLAGS="-L$PREFIX/lib" 2>&1 | tee -a "$LOGF"
  make -j"$(sysctl -n hw.ncpu)" libopenconnect.la 2>&1 | tee -a "$LOGF"
popd

# libtool 的嵌套归档要展开重打，否则 Xcode 链接器读不到 .o
OC_OBJ="$WORK/oc-obj-$ARCH"
rm -rf "$OC_OBJ"
mkdir -p "$OC_OBJ"
pushd "$OC_OBJ" >/dev/null
  xcrun -sdk iphoneos ar x "$WORK/openconnect/.libs/libopenconnect.a"
  rm -f ./*.a
  xcrun -sdk iphoneos ar rcs libopenconnect.a ./*.o
popd >/dev/null

cp -L "$OC_OBJ/libopenconnect.a" "$OUT/lib/"
cp -L "$PREFIX/lib/libssl.a"     "$OUT/lib/"
cp -L "$PREFIX/lib/libcrypto.a"  "$OUT/lib/"
cp -L "$PREFIX/lib/libxml2.a"    "$OUT/lib/"
cp "$WORK/openconnect/openconnect.h" "$OUT/include/"
cp -r "$PREFIX/include/openssl"  "$OUT/include/" || true
cp -r "$PREFIX/include/libxml2"  "$OUT/include/" || true

echo "产出: $OUT/lib/ + $OUT/include/"
ls -l "$OUT/lib"
