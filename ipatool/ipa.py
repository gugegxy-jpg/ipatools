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

# 本身已经是压缩格式的后缀：再 deflate 一遍几乎不省体积，纯烧 CPU，打包时直接存储。
# 漏了某项也没关系（只是慢一点），所以这里只列常见且一定能确定的。
ALREADY_COMPRESSED_SUFFIXES = (
    # 图片 / 纹理
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".heif", ".avif",
    ".astc", ".ktx", ".ktx2", ".pvr", ".dds", ".basis",
    # 音视频
    ".mp3", ".m4a", ".aac", ".ogg", ".oga", ".opus", ".wav", ".flac",
    ".mp4", ".m4v", ".mov", ".mkv", ".webm",
    # 压缩包 / 已压缩容器
    ".zip", ".gz", ".bz2", ".xz", ".7z", ".rar", ".jar", ".apk", ".ipa",
    ".unity3d", ".assetbundle", ".skadnetwork", ".pack",
    # 字体（自带压缩表）
    ".woff", ".woff2", ".otf",
)


def _already_compressed(name: str) -> bool:
    return name.lower().endswith(ALREADY_COMPRESSED_SUFFIXES)


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


def archive(src: str, out_path: str, compresslevel: int | None = None) -> None:
    """
    把目录重新打包成 IPA。

    compresslevel 是打包耗时的大头（IPA 体积多大、CPU 就烧多久）：
      None（默认）：智能。已经是压缩格式的资源（png / jpg / mp4 / astc / zip …）
                    再 deflate 一遍几乎不省体积，直接 STORED；其余用 deflate。
      0          ：全部 STORED，最快，体积最大。
      1-9        ：全部 deflate，数字越小越快、越大越慢越小。
    """
    os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
    default_type = zipfile.ZIP_STORED if compresslevel == 0 else zipfile.ZIP_DEFLATED
    open_kwargs = {} if compresslevel in (None, 0) else {"compresslevel": compresslevel}
    with zipfile.ZipFile(out_path, "w", default_type, **open_kwargs) as zf:
        for root, dirs, files in os.walk(src):
            dirs.sort()
            files.sort()
            rel_root = os.path.relpath(root, src).replace(os.sep, "/")
            if rel_root != ".":
                zi = zipfile.ZipInfo(rel_root + "/")
                zi.external_attr = (_mode_of(root, True) | stat.S_IFDIR) << 16 | 0x10
                zi.compress_type = zipfile.ZIP_STORED
                _set_mtime(zi, root)
                zf.writestr(zi, b"", compress_type=zipfile.ZIP_STORED)

            for name in files:
                full = os.path.join(root, name)
                # 输出文件本身，以及工具在工作目录里生成的中间包（如 zsign 的 unsigned.ipa）
                # 都不属于 App，不能打进最终产物
                if os.path.abspath(full) == os.path.abspath(out_path):
                    continue
                if rel_root == "." and name.lower().endswith(".ipa"):
                    continue

                rel = name if rel_root == "." else f"{rel_root}/{name}"

                if os.path.islink(full):
                    zi = zipfile.ZipInfo(rel)
                    zi.external_attr = (0o777 | stat.S_IFLNK) << 16
                    _set_mtime(zi, full)
                    zf.writestr(zi, os.readlink(full).replace(os.sep, "/"),
                                compress_type=zipfile.ZIP_STORED)
                    continue

                store = compresslevel == 0 or (
                    compresslevel is None and _already_compressed(name)
                )
                zi = zipfile.ZipInfo(rel)
                zi.external_attr = _mode_of(full) << 16
                _set_mtime(zi, full)
                with open(full, "rb") as f:
                    data = f.read()
                if store:
                    zf.writestr(zi, data, compress_type=zipfile.ZIP_STORED)
                else:
                    zf.writestr(zi, data, compress_type=zipfile.ZIP_DEFLATED,
                                compresslevel=compresslevel)


def is_bundle_dir(name: str) -> bool:
    return name.endswith(BUNDLE_SUFFIXES)


def is_dylib(name: str) -> bool:
    return name.endswith(DYLIB_SUFFIXES)
