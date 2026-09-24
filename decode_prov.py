import plistlib, zipfile, re
from cryptography.hazmat.primitives.serialization import pkcs7

PROV = r"F:/download/放三2苹果证书_20260917/SG2_Dev20260917.mobileprovision"
IPA = r"F:/download/zsign-windows-x64/Debug_f2_v1.4.2615.416700_202607242138-injected.ipa"


def decode_prov(path):
    data = open(path, "rb").read()
    content = None
    try:
        sig = pkcs7.load_der_pkcs7_signature(data)
        content = sig.get_content()
    except Exception:
        m = re.search(rb"<\?xml.*?</plist>", data, re.S)
        content = m.group(0) if m else None
    if not content:
        print("无法解析描述文件内容"); return
    plist = plistlib.loads(content)
    print("名称            :", plist.get("Name"))
    print("UUID            :", plist.get("UUID"))
    print("TeamIdentifier  :", plist.get("TeamIdentifier"))
    print("过期时间        :", plist.get("ExpirationDate"))
    print("ProvisionsAllDevices:", plist.get("ProvisionsAllDevices"))
    ents = plist.get("Entitlements", {})
    aid = ents.get("application-identifier")
    print("application-identifier:", aid)
    print("是否通配符       :", str(aid).endswith("*"))
    print("描述文件允许的 entitlements 键:")
    for k, v in sorted(ents.items()):
        print("   ", k, "=", v)
    devs = plist.get("ProvisionedDevices") or []
    print("包含设备数       :", len(devs))
    for d in devs:
        print("   ", d)


def bundle_of(ipa):
    with zipfile.ZipFile(ipa) as z:
        for n in z.namelist():
            if n.endswith("Info.plist") and "/Payload/" in n and n.endswith(".app/Info.plist"):
                try:
                    pl = plistlib.loads(z.read(n))
                except Exception:
                    return "(无法解析 %s)" % n
                return pl.get("CFBundleIdentifier"), n
    return None, None


print("=== 描述文件 ===")
decode_prov(PROV)
print()
print("=== IPA Bundle ID ===")
b, n = bundle_of(IPA)
print("Info.plist:", n)
print("CFBundleIdentifier:", b)
if b is not None:
    want = "UNGLAJ4B3V.com.xuehai.fknsg2"
    print("与描述文件要求一致:", b == "com.xuehai.fknsg2" or b == want)
