"""IPA 包的解包 / 打包（尽可能保留 Mach-O 可执行权限）。"""
from __future__ import annotations

import os
import stat
import time
import zipfile

# Mach-O 32/64 位及 fat binary 的 magic
MACHO_MAGICS = (
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
)

# 需要被当作 bundle 整体签名的目录后缀
BUNDLE_SUFFIXES = (".app", ".appex", ".framework", ".xctest", ".bundle", ".qlgenerator", ".appex")

# 需要单独签名的动态库后缀
DYLIB_SUFFIXES = (".dylib", ".so")


def is_macho(path: str) -> bool:
    """通过文件头判断是否为 Mach-O 可执行文件。"""
    try:
        with open(path, "rb") as f:
            head = f.read(4)
    except OSError:
        return False
    return head in MACHO_MAGICS


def is_shebang(path: str) -> bool:
    try:
        with open(path, "rb") as f:
            return f.read(2) == b"#!"
    except OSError:
        return False


def extract(ipa_path: str, dest: str) -> None:
    """把 IPA 解压到 dest。"""
    with zipfile.ZipFile(ipa_path) as zf:
        zf.extractall(dest)


def _mode_of(path: str, is_dir: bool = False) -> int:
    """
    计算重新打包时应写入的权限位。
    POSIX（macOS/Linux）直接沿用原文件权限；Windows 上权限在解压时已丢失，
    因此用"是否 Mach-O / shebang"来推断可执行位。
    """
    if os.name == "posix":
        mode = stat.S_IMODE(os.lstat(path).st_mode)
        return mode or (0o755 if is_dir else 0o644)
    if is_dir:
        return 0o755
    return 0o755 if (is_macho(path) or is_shebang(path)) else 0o644


def _set_mtime(zi: zipfile.ZipInfo, path: str) -> None:
    try:
        zi.date_time = time.localtime(os.stat(path).st_mtime)[:6]
    except (OSError, ValueError):
        pass


def archive(src: str, out_path: str, compresslevel: int = 9) -> None:
    """把目录重新打包成 IPA。"""
    os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED, compresslevel=compresslevel) as zf:
        for root, dirs, files in os.walk(src):
            dirs.sort()
            files.sort()
            rel_root = os.path.relpath(root, src).replace(os.sep, "/")
            if rel_root != ".":
                zi = zipfile.ZipInfo(rel_root + "/")
                zi.external_attr = (_mode_of(root, True) | stat.S_IFDIR) << 16 | 0x10
                _set_mtime(zi, root)
                zf.writestr(zi, b"")

            for name in files:
                full = os.path.join(root, name)
                rel = name if rel_root == "." else f"{rel_root}/{name}"

                if os.path.islink(full):
                    zi = zipfile.ZipInfo(rel)
                    zi.external_attr = (0o777 | stat.S_IFLNK) << 16
                    _set_mtime(zi, full)
                    zf.writestr(zi, os.readlink(full).replace(os.sep, "/"))
                    continue

                zi = zipfile.ZipInfo(rel)
                zi.external_attr = _mode_of(full) << 16
                zi.compress_type = zipfile.ZIP_DEFLATED
                _set_mtime(zi, full)
                with open(full, "rb") as f:
                    zf.writestr(zi, f.read())


def is_bundle_dir(name: str) -> bool:
    return name.endswith(BUNDLE_SUFFIXES)


def is_dylib(name: str) -> bool:
    return name.endswith(DYLIB_SUFFIXES)
