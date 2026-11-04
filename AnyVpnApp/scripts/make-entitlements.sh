#!/usr/bin/env bash
#
# 从描述文件反推一份「与它严格匹配」的 entitlements。
#
# 手动重签最容易翻车的地方：entitlements 里写了描述文件没授权的键
# （比如具体的 keychain group、application-groups），
# iOS 安装时直接判定签名无效 → “ApplicationVerificationFailed”。
#
# 用法：
#   bash make-entitlements.sh <profile.mobileprovision> <out.entitlements> [bundle-id]
#
# 例：
#   bash make-entitlements.sh App.mobileprovision App.entitlements com.anyvpn.app
#   bash make-entitlements.sh Tunnel.mobileprovision Tunnel.entitlements com.anyvpn.app.tunnel
#
set -euo pipefail

PROFILE="${1:-}"
OUT="${2:-}"
BUNDLE_ID="${3:-}"
if [ -z "$PROFILE" ] || [ -z "$OUT" ]; then
  echo "用法: $0 <profile.mobileprovision> <out.entitlements> [bundle-id]" >&2
  exit 2
fi
if [ ! -f "$PROFILE" ]; then
  echo "找不到描述文件: $PROFILE" >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
security cms -D -i "$PROFILE" > "$TMP/profile.plist"

python3 - "$TMP/profile.plist" "$OUT" "$BUNDLE_ID" <<'PY'
import plistlib, sys

src, out, bundle = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, "rb") as f:
    p = plistlib.load(f)
ents = p.get("Entitlements", {}) or {}

ne = ents.get("com.apple.developer.networking.networkextension")
if isinstance(ne, str):
    ne = [ne]
if not ne:
    print("❌ 这张描述文件没有 NetworkExtension 能力，重签后也装不了 VPN。", file=sys.stderr)
    print("   需要在开发者后台为该 AppID 勾选 Network Extensions（Packet Tunnel Provider）"
          "后重新生成描述文件。", file=sys.stderr)
    sys.exit(1)

res = {"com.apple.developer.networking.networkextension": ne}

kg = ents.get("keychain-access-groups")
if kg:
    res["keychain-access-groups"] = kg
ag = ents.get("com.apple.security.application-groups")
if ag:
    res["com.apple.security.application-groups"] = ag

app_id = ents.get("application-identifier", "")
prefix = app_id.split(".")[0] if app_id else ""
if prefix and bundle:
    res["application-identifier"] = "%s.%s" % (prefix, bundle)
if "get-task-allow" in ents:
    res["get-task-allow"] = bool(ents["get-task-allow"])

with open(out, "wb") as f:
    plistlib.dump(res, f)

print("✅ 已生成 %s" % out)
print("   NetworkExtension : %s" % ", ".join(ne))
print("   keychain groups  : %s" % ", ".join(res.get("keychain-access-groups", [])))
if res.get("com.apple.security.application-groups"):
    print("   app groups       : %s" % ", ".join(res["com.apple.security.application-groups"]))
PY
