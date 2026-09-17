"""plist 与 .strings 文件的读写（保持原有格式）。"""
from __future__ import annotations

import os
import plistlib
import re

_NAME_RE = re.compile(r'("?\s*CFBundleDisplayName\s*"?\s*=\s*")((?:[^"\\]|\\.)*)("\s*;)')

_BOMS = (
    (b"\xff\xfe", "utf-16-le", b"\xff\xfe"),
    (b"\xfe\xff", "utf-16-be", b"\xfe\xff"),
    (b"\xef\xbb\xbf", "utf-8", b"\xef\xbb\xbf"),
)


def load_plist(path: str) -> dict:
    with open(path, "rb") as f:
        data = plistlib.load(f)
    if not isinstance(data, dict):
        raise ValueError(f"{path} 不是字典类型的 plist")
    return data


def _detect_fmt(path: str) -> int:
    try:
        with open(path, "rb") as f:
            head = f.read(8)
    except OSError:
        return plistlib.FMT_XML
    return plistlib.FMT_BINARY if head.startswith(b"bplist") else plistlib.FMT_XML


def dump_plist(path: str, data: dict) -> None:
    """写回 plist，沿用原文件的 XML / Binary 格式。"""
    fmt = _detect_fmt(path)
    with open(path, "wb") as f:
        plistlib.dump(data, f, fmt=fmt, sort_keys=False)


def _decode(raw: bytes) -> tuple[str, str, bytes]:
    for bom, enc, bom_bytes in _BOMS:
        if raw.startswith(bom):
            return raw.decode(enc).lstrip("\ufeff"), enc, bom_bytes
    try:
        return raw.decode("utf-8"), "utf-8", b""
    except UnicodeDecodeError:
        return raw.decode("utf-16-le").lstrip("\ufeff"), "utf-16-le", b""


def _escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _unescape(value: str) -> str:
    return value.replace("\\n", "\n").replace('\\"', '"').replace("\\\\", "\\")


def read_strings_display_name(path: str) -> str | None:
    """读取 InfoPlist.strings 中 CFBundleDisplayName 的当前值。"""
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return None
    try:
        text, _, _ = _decode(raw)
    except UnicodeDecodeError:
        return None
    m = _NAME_RE.search(text)
    return _unescape(m.group(2)) if m else None


def set_strings_display_name(path: str, new_name: str, only_if: str | None = None) -> bool:
    """
    改写 InfoPlist.strings 中的 CFBundleDisplayName。
    only_if 不为 None 时，仅当原值等于 only_if 才替换。
    """
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return False
    try:
        text, enc, bom = _decode(raw)
    except UnicodeDecodeError:
        return False

    if only_if is not None and read_strings_display_name(path) != only_if:
        return False

    new_text, count = _NAME_RE.subn(
        lambda m: m.group(1) + _escape(new_name) + m.group(3), text
    )
    if not count:
        return False

    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(bom + new_text.encode(enc))
    os.replace(tmp, path)
    return True
