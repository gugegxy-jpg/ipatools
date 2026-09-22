#!/usr/bin/env python
"""诊断：复刻 zsign_ipa 的 entitlements 合并逻辑，打印 zsign 实际会收到的最终 entitlements。

用法（在 Windows PowerShell / 终端里）：
    python diag_sign.py <描述文件.mobileprovision> <entitlements.plist> [新BundleID]

把输出整段贴回来，我就能看出 application-identifier 对不对、有没有被丢弃的键。
"""
import sys, os, plistlib, pprint
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ipatool import signer

def pd(d):
    return pprint.pformat(d)

DEV_ONLY = signer._DEV_ONLY_KEYS

def main():
    if len(sys.argv) < 3:
        print("用法: python diag_sign.py <描述文件> <entitlements> [bundle_id]")
        return
    provision, ent_path = sys.argv[1], sys.argv[2]
    bundle_id = sys.argv[3] if len(sys.argv) > 3 else None

    base = signer._provision_entitlements(provision)
    print("=== 从描述文件解析出的 Entitlements (基线) ===")
    print(pd(base) if base else "(空！解析失败或描述文件无 Entitlements)")

    try:
        user = plistlib.loads(open(ent_path, "rb").read())
    except Exception as e:
        print("读取 entitlements 失败:", e)
        return
    print("=== 你的 entitlements.plist ===")
    print(pd(user))

    if not base or "application-identifier" not in base:
        print("\n!!! 基线缺少 application-identifier -> 实际签名会退回「不传 -e」，让 zsign 自动推导。")
        return

    # 同步 bundle_id
    if bundle_id:
        app_id = base["application-identifier"]
        if app_id.endswith(".*"):
            print(f"\n[通配符描述文件] Bundle ID 改为 {bundle_id}，application-identifier 保持 {app_id}")
        else:
            team = app_id.split(".", 1)[0]
            base["application-identifier"] = f"{team}.{bundle_id}"
            if "keychain-access-groups" in base:
                base["keychain-access-groups"] = [f"{team}.{bundle_id}"]
            print(f"\n[同步 Bundle ID] application-identifier -> {base['application-identifier']}")

    is_dev = bool(base.get("get-task-allow"))
    print(f"[开发型描述文件?] {is_dev} (get-task-allow={base.get('get-task-allow')})")

    merged = dict(base)
    dropped = []
    for k, v in user.items():
        if k in base:
            continue
        if k == "get-task-allow":
            continue
        if (not is_dev) and k in DEV_ONLY:
            dropped.append(k)
            continue
        merged[k] = v

    print("=== 最终合并结果（即 zsign 收到的 -e 内容）===")
    print(pd(merged))
    if dropped:
        print(f"\n[已丢弃 dev-only 键] {dropped}  -> 非开发描述文件不允许，去掉才能装")
    print(f"\n[application-identifier 是否仍在] {merged.get('application-identifier')}")
    print(f"[get-task-allow 最终值] {merged.get('get-task-allow')}")

if __name__ == "__main__":
    main()
