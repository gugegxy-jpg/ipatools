#!/usr/bin/env bash
#
# 重签 AnyVpnApp 的未签名 IPA（App 与 appex 分别签）。
#
# 关键点：
#   1. 两份描述文件：App 一个、appex 一个，bundle id 必须是各自的；
#   2. entitlements 用 make-entitlements.sh 从描述文件反推，保证与描述文件一致；
#   3. 先签 appex（嵌套的先签），再签 App；
#   4. 签名前不要动 appex 的 Info.plist（NSExtension 会丢 → 装不上）。
#
# 用法：
#   bash sign.sh <AnyVpnApp-unsigned.ipa> <AppProfile.mobileprovision> \
#                <TunnelProfile.mobileprovision> "<Signing Identity>" [out.ipa]
#
# 例：
#   bash sign.sh AnyVpnApp-unsigned.ipa App.mobileprovision Tunnel.mobileprovision \
#        "Apple Development: Your Name (TEAMID)"
#
set -euo pipefail

IPA="${1:-}"
APP_PROFILE="${2:-}"
TUNNEL_PROFILE="${3:-}"
IDENTITY="${4:-}"
OUT="${5:-}"

if [ -z "$IPA" ] || [ -z "$APP_PROFILE" ] || [ -z "$TUNNEL_PROFILE" ] || [ -z "$IDENTITY" ]; then
  echo "用法: $0 <ipa> <AppProfile> <TunnelProfile> <Identity> [out.ipa]" >&2
  exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -n "$OUT" ] || OUT="$(basename "$IPA" .ipa)-signed.ipa"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

unzip -q "$IPA" -d payload_dir
APP="payload_dir/Payload/AnyVpnApp.app"
APPEX="$APP/PlugIns/PacketTunnel.appex"

if [ ! -d "$APPEX" ]; then
  echo "❌ IPA 里没有 PlugIns/PacketTunnel.appex" >&2
  exit 1
fi
echo ">>> 生成 entitlements"
bash "$HERE/make-entitlements.sh" "$APP_PROFILE" "$WORK/App.entitlements" com.anyvpn.app
bash "$HERE/make-entitlements.sh" "$TUNNEL_PROFILE" "$WORK/Tunnel.entitlements" com.anyvpn.app.tunnel

echo ">>> 签 appex（先签嵌套的）"
codesign -f -s "$IDENTITY" \
  --entitlements "$WORK/Tunnel.entitlements" \
  --preserve-metadata=identifier,flags,runtime \
  "$APPEX"

echo ">>> 签 App"
codesign -f -s "$IDENTITY" \
  --entitlements "$WORK/App.entitlements" \
  --preserve-metadata=identifier,flags,runtime \
  "$APP"

echo ">>> 校验"
codesign -d --entitlements :- "$APP" > "$WORK/app.ents.check" 2>/dev/null || true
codesign -d --entitlements :- "$APPEX" > "$WORK/appex.ents.check" 2>/dev/null || true
codesign --verify --deep --strict "$APP" || true
grep -A2 networkextension "$WORK/app.ents.check" || \
  echo "⚠️ App 签名里没看到 networkextension，检查 entitlements"

cd payload_dir && zip -qr "$WORK/$OUT" Payload
cp "$WORK/$OUT" "./$OUT"
echo "✅ 已生成: $OUT"
