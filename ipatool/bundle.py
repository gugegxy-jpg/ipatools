"""Bundle（.app / .appex / .framework ...）的发现与改写。"""
from __future__ import annotations

import copy
import os
from dataclasses import dataclass

from . import plistutil
from .ipa import is_bundle_dir

PAYLOAD = "Payload"


@dataclass
class Bundle:
    path: str
    rel: str
    kind: str
    plist_path: str | None = None
    identifier: str | None = None
    display_name: str | None = None
    bundle_name: str | None = None
    executable: str | None = None
    version: str | None = None
    build: str | None = None
    min_os: str | None = None


@dataclass
class Change:
    target: str
    key: str
    old: str | None
    new: str | None
    note: str = ""

    def __str__(self) -> str:
        scope = f" [{self.note}]" if self.note else ""
        return f"{self.target}  {self.key}: {self.old!r} -> {self.new!r}{scope}"


def _read_bundle(full: str, root: str) -> Bundle | None:
    rel = os.path.relpath(full, root).replace(os.sep, "/")
    kind = os.path.splitext(full)[1].lstrip(".") or "bundle"

    plist_path = os.path.join(full, "Info.plist")
    if not os.path.isfile(plist_path):
        # 很多 framework 把 Info.plist 放在 Resources 下
        alt = os.path.join(full, "Resources", "Info.plist")
        if os.path.isfile(alt):
            plist_path = alt
        else:
            return Bundle(path=full, rel=rel, kind=kind)

    data = plistutil.load_plist(plist_path)
    return Bundle(
        path=full,
        rel=rel,
        kind=kind,
        plist_path=plist_path,
        identifier=data.get("CFBundleIdentifier"),
        display_name=data.get("CFBundleDisplayName"),
        bundle_name=data.get("CFBundleName"),
        executable=data.get("CFBundleExecutable"),
        version=data.get("CFBundleShortVersionString"),
        build=data.get("CFBundleVersion"),
        min_os=data.get("MinimumOSVersion"),
    )


def discover(root: str) -> list[Bundle]:
    """找出 Payload 下的所有 bundle，按层级由浅到深排序。"""
    payload = os.path.join(root, PAYLOAD)
    base = payload if os.path.isdir(payload) else root

    bundles: list[Bundle] = []
    for cur, dirs, _ in os.walk(base):
        dirs.sort()
        for d in dirs:
            if not is_bundle_dir(d):
                continue
            b = _read_bundle(os.path.join(cur, d), root)
            if b:
                bundles.append(b)
    bundles.sort(key=lambda b: (b.rel.count("/"), b.rel))
    return bundles


def main_app(bundles: list[Bundle]) -> Bundle:
    """主 App：Payload 下第一层的 .app。"""
    apps = [b for b in bundles if b.kind == "app"]
    if not apps:
        raise ValueError("Payload 中未找到 .app 主程序")
    for b in apps:
        if b.rel.count("/") == 1 and b.rel.startswith(PAYLOAD + "/"):
            return b
    return apps[0]


def _map_identifier(current: str | None, old: str | None, new: str | None) -> str | None:
    """把子 bundle 的 id 按前缀映射到新的主 id。"""
    if not current or not old or not new or old == new:
        return None
    if current == old:
        return new
    if current.startswith(old + "."):
        return new + current[len(old):]
    return None


def _replace_identifier_refs(node, old: str, new: str, count: list[int]) -> object:
    """递归替换 plist 中所有引用旧 bundle id 的字符串值。"""
    if isinstance(node, dict):
        return {k: _replace_identifier_refs(v, old, new, count) for k, v in node.items()}
    if isinstance(node, list):
        return [_replace_identifier_refs(v, old, new, count) for v in node]
    if isinstance(node, str) and (node == old or node.startswith(old + ".")):
        count[0] += 1
        return new + node[len(old):] if node != old else new
    return node


def find_strings_files(root: str) -> list[str]:
    found: list[str] = []
    for cur, _, files in os.walk(root):
        for f in files:
            if f == "InfoPlist.strings":
                found.append(os.path.join(cur, f))
    return sorted(found)


def apply_changes(
    root: str,
    new_bundle_id: str | None = None,
    new_display_name: str | None = None,
    new_bundle_name: str | None = None,
    update_localized: bool = True,
    dry_run: bool = False,
) -> tuple[list[Change], list[str]]:
    """
    修改 Payload 内所有 bundle 的 Bundle ID 与显示名称。
    返回 (变更列表, 警告列表)。
    """
    bundles = discover(root)
    app = main_app(bundles)
    old_id = app.identifier or ""
    old_display = app.display_name or app.bundle_name or ""

    target_id = new_bundle_id or old_id
    changes: list[Change] = []
    warnings: list[str] = []

    for b in bundles:
        if not b.plist_path:
            warnings.append(f"{b.rel}: 无 Info.plist，已跳过")
            continue

        data = plistutil.load_plist(b.plist_path)
        original = copy.deepcopy(data)

        # 1) Bundle Identifier
        mapped = _map_identifier(b.identifier, old_id, target_id)
        if mapped and mapped != b.identifier:
            changes.append(Change(b.rel, "CFBundleIdentifier", b.identifier, mapped))
            data["CFBundleIdentifier"] = mapped
        elif (
            b.identifier
            and old_id
            and target_id != old_id
            and not _map_identifier(b.identifier, old_id, target_id)
        ):
            warnings.append(
                f"{b.rel}: Bundle ID `{b.identifier}` 与主 ID 无前缀关系，未自动改写"
            )

        # 2) 其它引用旧 ID 的字符串（WKAppBundleIdentifier、CFBundleURLName 等）
        if old_id and target_id != old_id:
            counter = [0]
            data = _replace_identifier_refs(data, old_id, target_id, counter)
            if counter[0]:
                changes.append(
                    Change(b.rel, f"引用旧 Bundle ID 的字符串 ×{counter[0]}", old_id, target_id)
                )

        # 3) 显示名称
        if new_display_name:
            if b is app:
                if data.get("CFBundleDisplayName") != new_display_name:
                    changes.append(
                        Change(b.rel, "CFBundleDisplayName", data.get("CFBundleDisplayName"), new_display_name)
                    )
                data["CFBundleDisplayName"] = new_display_name
            elif b.display_name and old_display and b.display_name == old_display:
                changes.append(Change(b.rel, "CFBundleDisplayName", b.display_name, new_display_name))
                data["CFBundleDisplayName"] = new_display_name

        if new_bundle_name and b is app:
            if data.get("CFBundleName") != new_bundle_name:
                changes.append(Change(b.rel, "CFBundleName", data.get("CFBundleName"), new_bundle_name))
            data["CFBundleName"] = new_bundle_name

        if data != original and not dry_run:
            plistutil.dump_plist(b.plist_path, data)

    # 4) 本地化名称（InfoPlist.strings）
    if new_display_name and update_localized:
        # 主 App 自己的 *.lproj/InfoPlist.strings 无条件同步；
        # 插件 / WatchApp 里的只在名称原本就相同的情况下跟随修改
        app_lproj_root = os.path.abspath(app.path)
        for path in find_strings_files(os.path.join(root, PAYLOAD)):
            current = plistutil.read_strings_display_name(path)
            if current is None:
                continue
            in_app_root = os.path.abspath(os.path.dirname(os.path.dirname(path))) == app_lproj_root
            if not in_app_root and current != old_display:
                continue
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            changed = True if dry_run else plistutil.set_strings_display_name(path, new_display_name)
            if changed:
                changes.append(Change(rel, "CFBundleDisplayName(本地化)", old_display or None, new_display_name))

    return changes, warnings
