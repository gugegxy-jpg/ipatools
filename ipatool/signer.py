"""重签名：优先 macOS 的 codesign，其次跨平台的 zsign。"""
from __future__ import annotations

import os
import platform
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
import plistlib

from cryptography.hazmat.primitives.serialization import pkcs7

from .ipa import is_bundle_dir, is_dylib

BACKENDS = ("auto", "codesign", "zsign", "none")

ZSIGN_DIR = "zsign"                  # 项目里放 zsign 的目录（zsign/zsign.exe）
ZSIGN_HINT = ("https://github.com/zhlynn/zsign（跨平台，含 Windows）"
              "或 https://github.com/claration/Zsign-Package")


class SignError(RuntimeError):
    pass


def _have(tool: str) -> bool:
    return shutil.which(tool) is not None


def config_path() -> str:
    """
    ipatool 的本地配置（GUI 写、CLI 也读）。目前存签名相关的东西：上次选的证书、
    密码等。Windows 用 %APPDATA%，macOS 用 Application Support，其它用 XDG。
    """
    system = platform.system()
    if system == "Windows":
        base = os.environ.get("APPDATA") or os.path.expanduser("~")
        return os.path.join(base, "ipatool", "gui.json")
    if system == "Darwin":
        return os.path.expanduser("~/Library/Application Support/ipatool/gui.json")
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "ipatool", "gui.json")


def app_root() -> str:
    """项目根目录：源码运行时是 ipatool/ 的上一级，打包成 exe 后是 exe 所在目录。"""
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def zsign_dirs() -> list[str]:
    """可能放着 zsign 的目录：打包临时目录、项目根、以及 ipatool/ 自己那一层。"""
    roots: list[str] = []
    meipass = getattr(sys, "_MEIPASS", "")      # PyInstaller 解包出来的临时目录
    if meipass:
        roots.append(str(meipass))
    roots.append(app_root())
    roots.append(os.path.dirname(os.path.abspath(__file__)))
    unique: list[str] = []
    for root in roots:
        if root not in unique:
            unique.append(root)
    return unique


def zsign_candidates() -> list[str]:
    """本项目自带的那份 zsign 可能在哪（zsign/ 目录里，或直接扔在项目根）。"""
    out: list[str] = []
    for root in zsign_dirs():
        folder = os.path.join(root, ZSIGN_DIR)
        out += [os.path.join(folder, "zsign.exe"), os.path.join(folder, "zsign")]
        out += [os.path.join(root, "zsign.exe"), os.path.join(root, "zsign")]
    return out


def _runnable(path: str) -> bool:
    """是不是一个能直接执行的文件（Windows 上不看执行位）。"""
    if not os.path.isfile(path):
        return False
    return os.name == "nt" or os.access(path, os.X_OK)


def _scan_zsign_dir(folder: str) -> str | None:
    """zsign/ 里文件名不标准（zsign-1.1.2.exe、zsign_macos 之类）也认。"""
    try:
        names = sorted(os.listdir(folder))
    except OSError:
        return None
    for name in sorted(names, key=lambda n: (not n.lower().endswith(".exe"), n.lower())):
        base, ext = os.path.splitext(name.lower())
        if not base.startswith("zsign") or ext in (".zip", ".md", ".txt", ".json", ".html"):
            continue
        path = os.path.join(folder, name)
        if _runnable(path):
            return os.path.abspath(path)
    return None


def zsign_binary() -> str | None:
    """找 zsign：项目自带的那份（zsign/zsign.exe）→ PATH 里的。

    项目里已经放了一份，正常不用配任何东西；PATH 兜底是给「自己装过 zsign」的人。
    """
    for path in zsign_candidates():
        if _runnable(path):
            return os.path.abspath(path)
    for folder in zsign_dirs():
        found = _scan_zsign_dir(os.path.join(folder, ZSIGN_DIR))
        if found:
            return found
    return shutil.which("zsign")


def zsign_report() -> str:
    """找不到 zsign 时把「查过哪几处、各是什么结果」列出来，省得瞎猜。"""
    lines = ["  查过这些位置:"]
    for path in zsign_candidates():
        lines.append(f"    [{'有' if os.path.isfile(path) else '无'}] {path}")
    lines.append(f"  PATH 里的 zsign : {shutil.which('zsign') or '(没有)'}")
    lines.append(f"  解决: 把 zsign(.exe) 放进 {os.path.join(app_root(), ZSIGN_DIR)} 里，"
                 f"文件名保持 zsign.exe / zsign 即可\n"
                 f"        下载: {ZSIGN_HINT}")
    return "\n".join(lines)


def resolve_backend(backend: str) -> str:
    if backend != "auto":
        if backend == "codesign" and not (platform.system() == "Darwin" and _have("codesign")):
            raise SignError("当前系统不是 macOS 或找不到 codesign，无法使用 codesign 后端")
        if backend == "zsign" and zsign_binary() is None:
            raise SignError("找不到 zsign，无法签名。\n" + zsign_report())
        return backend

    if platform.system() == "Darwin" and _have("codesign"):
        return "codesign"
    if zsign_binary() is not None:
        return "zsign"
    return "none"


def auto_backend_hint() -> str:
    """auto 落到 none 时把原因和出路说清楚（否则用户只会看到一句「已忽略证书」）。"""
    system = platform.system()
    lines: list[str] = []
    if system == "Darwin":
        lines.append("原因: macOS 上靠系统自带的 codesign 签名，但现在找不到 codesign"
                     "（装了 Xcode 命令行工具吗？xcrun --find codesign）")
    else:
        lines.append(f"原因: 当前系统是 {system}，用不了 macOS 自带的 codesign；"
                     "非 macOS 上签 IPA 只能靠 zsign，而项目里 / PATH 里都没有 zsign")
    lines.append(f"想在本机签: 把 zsign(.exe) 放进 {os.path.join(app_root(), ZSIGN_DIR)}"
                 f"（下载 {ZSIGN_HINT}）；"
                 "证书用 --p12 cert.p12，或 Windows 证书存储里的身份加 --identity <指纹>")
    lines.append("不想在本机签: 保留 --sign none，把未签名的 IPA 交给 "
                 "Sideloadly / AltStore / SideStore / LiveContainer 去签")
    return "\n".join(lines)


def _sign_items(payload_dir: str) -> list[str]:
    """
    收集需要签名的条目：所有 bundle 目录 + 游离的 dylib。
    按路径深度从深到浅排序，保证先签内嵌项再签宿主。
    """
    items: list[str] = []
    for cur, dirs, files in os.walk(payload_dir):
        for d in dirs:
            if is_bundle_dir(d):
                items.append(os.path.join(cur, d))
        for f in files:
            if is_dylib(f):
                items.append(os.path.join(cur, f))
    items.sort(key=lambda p: (-p.count(os.sep), p))
    return items


def _dump_entitlements(path: str) -> bytes | None:
    """从已有签名中提取 entitlements，避免重签后丢失权限。"""
    try:
        r = subprocess.run(
            ["codesign", "--display", "--entitlements", ":-", path],
            capture_output=True,
            check=False,
        )
    except OSError:
        return None
    if r.returncode == 0 and r.stdout.strip():
        return r.stdout
    return None


def _temp_plist(data: bytes) -> str:
    fd, path = tempfile.mkstemp(suffix=".plist")
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    return path


def _provision_entitlements(provision: str) -> dict:
    """从 .mobileprovision 解出 Entitlements 字典，作为合并基线。

    描述文件允许的键（application-identifier / keychain-access-groups /
    get-task-allow / com.apple.developer.* 等）必须出现在最终签名里，否则 iOS 会报
    0xe8008015（找不到有效的描述文件）。
    """
    try:
        data = open(provision, "rb").read()
    except OSError:
        return {}
    content = None
    try:
        sig = pkcs7.load_der_pkcs7_signature(data)
        content = sig.get_content()
    except Exception:
        m = re.search(rb"<\?xml.*?</plist>", data, re.S)
        content = m.group(0) if m else None
    if not content:
        return {}
    try:
        plist = plistlib.loads(content)
    except Exception:
        return {}
    ents = plist.get("Entitlements")
    return ents if isinstance(ents, dict) else {}


# 这些键只有「开发(Development)描述文件」才允许；Ad-Hoc / 发行描述文件里出现会直接
# 触发 0xe8008015。而本工具把 dylib 注进 Frameworks/ 用同证书签，library validation 自然
# 通过，并不需要它们——所以非开发描述文件下直接丢弃，避免把能装的包签坏。
_DEV_ONLY_KEYS = (
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.allow-dyld-environment-variables",
    "com.apple.security.cs.disable-executable-page-protection",
    "com.apple.security.cs.debuggable",
)


def _merge_entitlements(user_path: str, base: dict, dev_profile: bool | None = None,
                        log=print) -> str:
    """把用户自定义 entitlements 合并进 base，写临时 plist 返回路径。

    规则（避免 0xe8008015）：
      - base = 描述文件允许的 entitlements，是**权威基线**，它的键原样保留；
      - 用户只负责「追加」描述文件里没有的键；
      - 用户**不能覆盖**描述文件已管控的键——尤其 get-task-allow；
      - 当 dev_profile 显式给出时：disable-library-validation / com.apple.security.cs.*
        这类「仅开发描述文件可用」的键，若描述文件不是开发型就丢弃并提示（加了会 0xe8008015，
        而包内注入本就不需要它们）。
    """
    try:
        user = plistlib.loads(open(user_path, "rb").read())
    except Exception:
        user = {}
    if not isinstance(user, dict):
        user = {}
    merged = dict(base)
    dropped: list[str] = []
    for k, v in user.items():
        # 描述文件已经管控这个键 -> 必须跟描述文件一致，禁止用户覆盖
        if k in base:
            continue
        # get-task-allow 是描述文件强约束键：只有描述文件自己允许（已出现）时才用用户值，
        # 描述文件没列它（多为发行/Ad-Hoc）时一律不额外加，否则 0xe8008015。
        if k == "get-task-allow":
            continue
        # 仅开发描述文件可用的键：非开发描述文件下丢弃（避免把包签坏）
        if dev_profile is not None and not dev_profile and k in _DEV_ONLY_KEYS:
            dropped.append(k)
            continue
        merged[k] = v
    if dropped:
        log(f"[签名] 描述文件不是开发型，已忽略不需要的 entitlements 键（否则 iOS 会"
            f" 0xe8008015）：{', '.join(dropped)}")
    return _temp_plist(plistlib.dumps(merged))


def codesign_one(
    path: str,
    identity: str = "-",
    entitlements: str | None = None,
    hardened_runtime: bool = False,
    keychain: str | None = None,
    log=None,
) -> None:
    """
    用 codesign 给单个 Mach-O（.dylib / .app / .framework ...）签名。

    给插件 dylib 签名时用这个：运行时 dlopen 的库必须自己带一份有效签名，
    而且是签主 App 的同一把证书（iOS 的 library validation 看 Team ID）。
    没给 entitlements 时会先把原签名里的 entitlements 导出来带上，避免权限丢失。
    """
    temps: list[str] = []
    try:
        ent_file = None
        if entitlements:
            # 合并：以原签名里的 entitlements 为基线，叠加用户自定义键（如
            # disable-library-validation），避免整包替换丢权限。
            dumped = _dump_entitlements(path)
            base = {}
            if dumped:
                try:
                    base = plistlib.loads(dumped) or {}
                except Exception:
                    base = {}
            ent_file = _merge_entitlements(entitlements, base)
            temps.append(ent_file)
        else:
            dumped = _dump_entitlements(path)
            if dumped:
                ent_file = _temp_plist(dumped)
                temps.append(ent_file)

        cmd = ["codesign", "--force", "--sign", identity, "--timestamp=none"]
        if keychain:
            cmd += ["--keychain", keychain]
        if ent_file:
            cmd += ["--entitlements", ent_file]
        if hardened_runtime:
            cmd += ["--options", "runtime"]
        cmd += ["--generate-entitlements-der", path]

        r = subprocess.run(cmd, capture_output=True, check=False)
        if r.returncode != 0 and "--generate-entitlements-der" in cmd:
            # 老版本 macOS 不支持 DER，降级重试
            cmd.remove("--generate-entitlements-der")
            r = subprocess.run(cmd, capture_output=True, check=False)
        if r.returncode != 0:
            raise SignError(
                f"codesign 失败：{os.path.basename(path)}\n"
                + (r.stderr.decode("utf-8", "replace").strip() or r.stdout.decode("utf-8", "replace").strip())
            )
        if log:
            log(f"已签名 {os.path.basename(path)}")
    finally:
        for t in temps:
            try:
                os.remove(t)
            except OSError:
                pass


def codesign_payload(
    payload_dir: str,
    identity: str = "-",
    main_app: str | None = None,
    entitlements: str | None = None,
    hardened_runtime: bool = False,
    keychain: str | None = None,
    log=print,
) -> None:
    """用 codesign 对 Payload 内的所有条目按正确顺序重签名。"""
    main_abs = os.path.abspath(main_app) if main_app else None

    for path in _sign_items(payload_dir):
        # --entitlements 只给主 App，其余项沿用自己原来的 entitlements
        ent = entitlements if (main_abs and os.path.abspath(path) == main_abs) else None
        codesign_one(
            path,
            identity=identity,
            entitlements=ent,
            hardened_runtime=hardened_runtime,
            keychain=keychain,
        )
        log(f"  已签名 {os.path.relpath(path, payload_dir)}")


def _ipa_bundle_id(in_ipa: str) -> str | None:
    """从 IPA 里读出主 App 当前的 CFBundleIdentifier（用于把 embedded
    application-identifier 对齐到它，从而保留原 bundleId、不强制改写 Info.plist）。"""
    try:
        with zipfile.ZipFile(in_ipa) as z:
            for name in z.namelist():
                if re.match(r"Payload/[^/]+\\.app/Info\\.plist$", name):
                    try:
                        return plistlib.loads(z.read(name)).get("CFBundleIdentifier")
                    except Exception:
                        return None
    except Exception:
        pass
    return None


def zsign_ipa(
    in_ipa: str,
    out_ipa: str,
    p12: str | None = None,
    p12_password: str | None = None,
    provision: str | None = None,
    entitlements: str | None = None,
    bundle_id: str | None = None,
    log=print,
) -> None:
    """用 zsign 对 IPA 文件重签名（Windows / Linux / macOS 通用）。"""
    if not p12:
        raise SignError("zsign 后端需要 --p12 证书，通常还要配合 --provision 描述文件")

    binary = zsign_binary()
    if not binary:
        raise SignError("找不到 zsign。\n" + zsign_report())

    cmd = [binary, "-k", p12]
    if p12_password:
        cmd += ["-p", p12_password]
    if provision:
        cmd += ["-m", provision]

    # 从描述文件解析基线（一次性），合并 entitlements 用到
    base = _provision_entitlements(provision) if provision else {}

    ent_file = None
    tmp = None
    if entitlements:
        # 合并而非替换：以描述文件允许的 entitlements 为基线，叠加用户自定义键。
        # dev_profile：描述文件 Entitlements 里 get-task-allow=true 即视为开发型，
        # 只有开发型才允许 disable-library-validation / com.apple.security.cs.*。
        if not base or "application-identifier" not in base:
            # 拿不到描述文件的应用标识 -> 绝不能硬塞一份缺 application-identifier 的
            # entitlements（否则 iOS 报 0xe8008015「找不到有效描述文件」）。退回让 zsign
            # 按描述文件自动推导（用户已验证这条路径能装），只损失 disable-library-validation
            # 等额外键（包内注入本就不需要）。
            log("[签名] 未能从描述文件解析出 application-identifier，已改用 zsign 按描述文件"
                "自动生成 entitlements（跳过 --entitlements），以保证可安装。")
        else:
            # 推导「最终生效的 Bundle ID」：用户显式给了 --bundle-id 就用它，否则沿用 IPA
            # 里 Info.plist 的 CFBundleIdentifier（保持原 bundleId，装不同 App 互不覆盖）。
            # 然后把 embedded 的 application-identifier / keychain 组对齐成 TeamID.该BundleID，
            # 这样「描述文件允许范围」和「Info.plist 的 bundleId」一致，不会 0xe8008015。
            # 说明：你用指定 App 的描述文件也能装不同 bundleId，靠的是设备端绕过
            # 「描述文件 vs embedded」的校验（越狱+AppSync 之类），工具这边只需保证
            # Info.plist 与 embedded entitlements 自洽即可。通配符描述文件
            # （application-identifier 形如 TEAMID.*）保持通配，不拼成 TEAMID.*.xxx。
            eff_bid = bundle_id or _ipa_bundle_id(in_ipa)
            if eff_bid:
                app_id = base["application-identifier"]
                if app_id.endswith(".*"):
                    base["application-identifier"] = app_id
                else:
                    team = app_id.split(".", 1)[0]
                    base["application-identifier"] = f"{team}.{eff_bid}"
                    if "keychain-access-groups" in base:
                        # 只重映射 Team 作用域的组（team.*），保留 com.apple.token
                        # 这类跨 App 共享组，避免误删导致 Keychain 共享失效。
                        new_groups = []
                        for g in base["keychain-access-groups"]:
                            if g == f"{team}.*" or g.startswith(f"{team}."):
                                new_groups.append(f"{team}.{eff_bid}")
                            else:
                                new_groups.append(g)
                        base["keychain-access-groups"] = new_groups
            log(f"[签名] embedded application-identifier = {base.get('application-identifier')}"
                f"（开发型={bool(base.get('get-task-allow'))}）；按此合并 entitlements，"
                f"保留原 bundleId={eff_bid or '（未知）'}。")
            is_dev = bool(base.get("get-task-allow"))
            tmp = _merge_entitlements(entitlements, base, dev_profile=is_dev, log=log)
            ent_file = tmp
    if ent_file:
        cmd += ["-e", ent_file]
    if bundle_id:
        cmd += ["-b", bundle_id]
    cmd += ["-z", "9", "-o", out_ipa, in_ipa]

    try:
        r = subprocess.run(cmd, capture_output=True, check=False)
    finally:
        if tmp and os.path.isfile(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass
    if r.returncode != 0:
        raise SignError(
            "zsign 失败：\n" + (r.stderr.decode("utf-8", "replace").strip() or r.stdout.decode("utf-8", "replace").strip())
        )
    log(f"  zsign 完成 -> {out_ipa}")


def _write_minimal_plist(app_dir: str, exe_name: str) -> None:
    """写一个最小可用的 Info.plist，让 zsign 能把目录当成 .app 来签。

    只用 ASCII，避免 UTF-8 BOM 让 zsign 解析不到 CFBundleExecutable 而报错。
    """
    plist = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.app.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict>\n'
        '<key>CFBundleName</key><string>Wrap</string>\n'
        '<key>CFBundleIdentifier</key><string>com.example.wrap</string>\n'
        '<key>CFBundleVersion</key><string>1.0</string>\n'
        '<key>CFBundleShortVersionString</key><string>1.0</string>\n'
        f'<key>CFBundleExecutable</key><string>{exe_name}</string>\n'
        '<key>MinimumOSVersion</key><string>12.0</string>\n'
        '<key>CFBundlePackageType</key><string>APPL</string>\n'
        '</dict></plist>\n'
    )
    with open(os.path.join(app_dir, "Info.plist"), "w", encoding="ascii") as f:
        f.write(plist)


def zsign_one(
    in_path: str,
    out_path: str,
    p12: str,
    p12_password: str | None = None,
    provision: str | None = None,
    entitlements: str | None = None,
    log=print,
) -> None:
    """用 zsign 给单个插件 dylib 签名（Windows / Linux / macOS 通用）。

    **关键点**：zsign v1.1.2 不支持给「独立的 .dylib」文件签名——直接给它 -o 或
    就地签都会空过（文件原样不动，还谎报成功，正是之前 dylib 变 0KB 的根因）。
    正确做法是把 dylib 包进一个临时 .app，用 zsign 签整个包（它会签 Frameworks/
    下的 dylib），再把签好名的 dylib 抽出来写到 out_path。
    """
    if not p12:
        raise SignError("zsign 签名 dylib 需要 --p12 证书文件")
    binary = zsign_binary()
    if not binary:
        raise SignError("找不到 zsign。\n" + zsign_report())

    name = os.path.basename(in_path)
    work = tempfile.mkdtemp(prefix="zsign-dylib-")
    try:
        app_dir = os.path.join(work, "_Wrap.app")
        fw_dir = os.path.join(app_dir, "Frameworks")
        os.makedirs(fw_dir)
        # dylib 放进 Frameworks；主程序用一个副本占位（签完即丢弃）
        shutil.copyfile(in_path, os.path.join(fw_dir, name))
        shutil.copyfile(in_path, os.path.join(app_dir, "_Wrap"))
        _write_minimal_plist(app_dir, "_Wrap")

        # 注意：zsign 对 .app 输入**不要**传 -o（指向 .app 时会去找 Payload/ 目录、报
        # "Can't find payload directory!" 然后退出非 0）。直接就地签整个 _Wrap.app，
        # 它会签 Frameworks/ 下的 dylib，签完从输入 app 里把 dylib 抽出来即可。
        cmd = [binary, "-k", p12]
        if p12_password:
            cmd += ["-p", p12_password]
        if provision:
            cmd += ["-m", provision]
        ent_file = None
        tmp = None
        if entitlements:
            # 与 zsign_ipa 一致：以描述文件允许的 entitlements 为基线合并，避免整包替换。
            # dylib 本身不绑描述文件、替换也无害，但统一行为更稳。
            base = _provision_entitlements(provision) if provision else {}
            tmp = _merge_entitlements(entitlements, base or {})
            ent_file = tmp
        if ent_file:
            cmd += ["-e", ent_file]
        cmd += ["-z", "9", app_dir]
        try:
            r = subprocess.run(cmd, capture_output=True, check=False)
        finally:
            if tmp and os.path.isfile(tmp):
                try:
                    os.remove(tmp)
                except OSError:
                    pass
        if r.returncode != 0:
            raise SignError(
                "zsign 失败：\n"
                + (r.stderr.decode("utf-8", "replace").strip() or r.stdout.decode("utf-8", "replace").strip())
            )
        signed = os.path.join(app_dir, "Frameworks", name)
        if not os.path.isfile(signed) or os.path.getsize(signed) == 0:
            raise SignError("zsign 未生成签名后的 dylib（请检查证书 / 描述文件是否匹配）")
        shutil.move(signed, out_path)
        # zsign 把 CMS 写到 0x10000 槽、非标准；纠正到 0x10001，否则从 Documents 独立
        # dlopen 时 dyld 报 code signature invalid。
        if _fix_codesignature_cms_slot(out_path):
            log("  已把 CMS 签名槽纠正到 0x10001（标准 CSSLOT_SIGNATURE）")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    log(f"  zsign 完成 -> {out_path}")


def _fix_codesignature_cms_slot(path: str) -> bool:
    """zsign 会把 CMS 证书签名写到 superblob 的 0x10000 槽；但 Apple 规定该槽是
    “备用 CodeDirectory”(CSSLOT_ALTERNATE_CODEDIRECTORIES)，真正的签名必须放在
    0x10001(CSSLOT_SIGNATURE)。包内 dylib 由 App 的密封 CodeDirectory 担保、不受影响；
    但从 App 沙盒 Documents 独立 dlopen 的 dylib 要单独验自己的签名，dyld 在 0x10001
    找不到合法 CMS、却在 0x10000 撞到 CSMAGIC_BLOBWRAPPER(0xfade0b01)当 CodeDirectory
    解析 -> 报 code signature invalid。

    这里把 CMS blob 的槽位类型从 0x10000 改成 0x10001。仅改写 4 字节 type 字段、
    不动 blob 大小与内容；而 CodeDirectory 哈希只覆盖代码段、不覆盖签名区，因此
    修改签名槽位本身不会破坏签名有效性。返回是否做了修改。
    """
    try:
        d = bytearray(open(path, "rb").read())
    except OSError:
        return False
    if len(d) < 32 or d[:4] != b"\xcf\xfa\xed\xfe":
        return False
    _, ncmds, _, _ = struct.unpack("<4I", d[16:32])
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", d[off:off+8])
        if cmd == 0x1d:  # LC_CODE_SIGNATURE
            so, ss = struct.unpack("<II", d[off+8:off+16])
            cnt = struct.unpack(">I", d[so+8:so+12])[0]
            changed = False
            for j in range(cnt):
                ent = so + 12 + j * 8
                t, bo = struct.unpack(">II", d[ent:ent+8])
                magic = struct.unpack(">I", d[so+bo:so+bo+4])[0]
                # BLOBWRAPPER(CMS/PKCS7) 被放在了非标准槽 -> 纠正为 CSSLOT_SIGNATURE
                if magic == 0xfade0b01 and t != 0x10001:
                    d[ent:ent+4] = struct.pack(">I", 0x10001)
                    changed = True
            if changed:
                with open(path, "wb") as f:
                    f.write(d)
                return True
        off += cmdsize
    return False


def embed_provision(app_dir: str, provision: str) -> str:
    dest = os.path.join(app_dir, "embedded.mobileprovision")
    shutil.copyfile(provision, dest)
    return dest
