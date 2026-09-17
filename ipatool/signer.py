"""重签名：优先 macOS 的 codesign，其次跨平台的 zsign。"""
from __future__ import annotations

import os
import platform
import shutil
import subprocess
import tempfile

from .ipa import is_bundle_dir, is_dylib

BACKENDS = ("auto", "codesign", "zsign", "none")


class SignError(RuntimeError):
    pass


def _have(tool: str) -> bool:
    return shutil.which(tool) is not None


def resolve_backend(backend: str) -> str:
    if backend != "auto":
        if backend == "codesign" and not (platform.system() == "Darwin" and _have("codesign")):
            raise SignError("当前系统不是 macOS 或找不到 codesign，无法使用 codesign 后端")
        if backend == "zsign" and not _have("zsign"):
            raise SignError("找不到 zsign，请先安装（https://github.com/zhlynn/zsign）或改用其它后端")
        return backend

    if platform.system() == "Darwin" and _have("codesign"):
        return "codesign"
    if _have("zsign"):
        return "zsign"
    return "none"


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
    temps: list[str] = []

    try:
        for path in _sign_items(payload_dir):
            ent_file = None
            if main_abs and os.path.abspath(path) == main_abs and entitlements:
                ent_file = entitlements
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
                    f"codesign 失败：{os.path.relpath(path, payload_dir)}\n"
                    + (r.stderr.decode("utf-8", "replace").strip() or r.stdout.decode("utf-8", "replace").strip())
                )
            log(f"  已签名 {os.path.relpath(path, payload_dir)}")
    finally:
        for t in temps:
            try:
                os.remove(t)
            except OSError:
                pass


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

    cmd = ["zsign", "-k", p12]
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
