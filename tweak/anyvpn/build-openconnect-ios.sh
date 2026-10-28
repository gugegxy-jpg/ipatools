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
# 注意：OpenSSL 1.1.1 系列的 tag 是 OpenSSL_1_1_1w 驼峰命名（openssl-x.y.z 是 3.x 的风格）
fetch openssl     https://github.com/openssl/openssl.git         OpenSSL_1_1_1w
fetch libxml2     https://gitlab.gnome.org/GNOME/libxml2.git     v2.12.4
# lwIP 的发布 tag 都带 _RELEASE 后缀
fetch lwip        https://github.com/lwip-tcpip/lwip.git         STABLE-2_1_3_RELEASE

PREFIX="$WORK/prefix-$ARCH"
LOGF="$WORK/build-$ARCH.log"
: > "$LOGF"

# --- 构建依赖：libxml2 / openconnect 从 git 源码构建需要 autotools ---------
# GitHub 的 macOS runner 默认没装这三样；本机已装则直接跳过
if ! command -v autoreconf >/dev/null 2>&1 || ! command -v automake >/dev/null 2>&1 \
   || ! command -v libtoolize >/dev/null 2>&1; then
  echo ">>> 缺 autoconf/automake/libtool，用 brew 安装（首次约 1 分钟）"
  brew install autoconf automake libtool pkg-config || true
fi

# --- OpenSSL（静态库）------------------------------------------------------
# 1.1.1 的 ios64-cross 目标靠 CROSS_TOP / CROSS_SDK 找 iPhoneOS SDK；
# 3.0 系列才用 CROSS_SYSROOT。两个都设上，脚本以后换版本也能用。
export CROSS_SDK="$(basename "$SDK")"
export CROSS_TOP="$(dirname "$(dirname "$SDK")")"
export CROSS_SYSROOT="$SDK"
if [ -f "$PREFIX/lib/libcrypto.a" ] && [ -f "$PREFIX/lib/libssl.a" ]; then
  echo ">>> OpenSSL 已构建，跳过"
else
  pushd openssl
    make clean 2>&1 | tee -a "$LOGF" || true
    # 注意：1.1.1 的 Configure 不认裸的 -arch/-fPIC 选项（3.0 才行）；
    # arch / min-version 已含在 CC 里，PIC 用 CFLAGS 传
    ./Configure "$OPENSSL_TARGET" --prefix="$PREFIX" \
        no-shared no-tests no-asm no-hw \
        CC="$CC" CFLAGS="-fPIC" 2>&1 | tee -a "$LOGF"
    make -j"$(sysctl -n hw.ncpu)" build_libs 2>&1 | tee -a "$LOGF"
    make install_sw 2>&1 | tee -a "$LOGF"
  popd
fi

# --- libxml2（openconnect 解析认证 XML 必需）-------------------------------
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

# --- openconnect -----------------------------------------------------------
pushd openconnect
  [ -f configure ] || NOCONFIGURE=1 ./autogen.sh >>"$LOGF" 2>&1
  make clean >>"$LOGF" 2>&1 || true
  # 注意：续行（\）中间不能插注释行——拼接后 # 会把后面所有参数吞成注释。
  # openconnect 的 configure 只在 DIR 下直接找 libssl.a/libcrypto.a（不查
  # DIR/lib/），所以 --with-openssl 指到 lib 目录；头文件走 CFLAGS 的 -I。
  PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
  ./configure --host="$TRIPLE" --prefix="$PREFIX" \
      --with-openssl="$PREFIX/lib" \
      --without-gnutls --without-libpskc --without-stoken \
      --without-liboath --without-lz4 \
      --enable-static --disable-shared \
      --with-vpnc-script=/etc/vpnc/vpnc-script \
      --disable-nls \
      CC="$CC" \
      CFLAGS="-I$PREFIX/include -fPIC" LDFLAGS="-L$PREFIX/lib" 2>&1 | tee -a "$LOGF"
  make -j"$(sysctl -n hw.ncpu)" libopenconnect.la 2>&1 | tee -a "$LOGF"
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
        $CC -c "$f" -I../src/include $EXTRA_INC -o "$(basename "${f%.c}").o" >>"$LOGF" 2>&1 \
          || { echo "lwIP 编译失败: $f"; tail -40 "$LOGF"; exit 1; }
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
