"""重签名：优先 macOS 的 codesign，其次跨平台的 zsign。"""
from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
import tempfile

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
        ent_file = entitlements
        if not ent_file:
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
    if entitlements:
        cmd += ["-e", entitlements]
    if bundle_id:
        cmd += ["-b", bundle_id]
    cmd += ["-z", "9", "-o", out_ipa, in_ipa]

    r = subprocess.run(cmd, capture_output=True, check=False)
    if r.returncode != 0:
        raise SignError(
            "zsign 失败：\n" + (r.stderr.decode("utf-8", "replace").strip() or r.stdout.decode("utf-8", "replace").strip())
        )
    log(f"  zsign 完成 -> {out_ipa}")


def embed_provision(app_dir: str, provision: str) -> str:
    dest = os.path.join(app_dir, "embedded.mobileprovision")
    shutil.copyfile(provision, dest)
    return dest
