"""
dylib 注入：把动态库放进 App 的 Frameworks/ 并给主可执行文件加 LC_LOAD_DYLIB。

附带「切后台之后还能继续跑」的配置：
  - 后台保活（--keep-alive）：UIBackgroundModes 补 audio（可选 location/fetch/processing）
    + 写入 IPAToolKeepAlive 配置字典 + 定时唤醒任务标识 + 定位权限说明

还有一种和后台保活配套的「文件导入导出」（--files）：
  - 写入 IPAToolFiles 配置字典 + 让 App 的 Documents 在系统「文件」App 里可见
    （UIFileSharingEnabled / LSSupportsOpeningDocumentsInPlace）
  - 用来把游戏热更资源导出到「文件」App，或从「文件」App 导回沙盒

上面这些功能都合编在同一个 IPATool.dylib 里（内含悬浮窗），注入一次即可，
用哪个功能由对应的 Info.plist 配置字典决定（没用到的会写成 Enabled=NO）；
用 --no-panel 可以不带悬浮窗。

需要单独出包时（比如改了某个功能只想重编它）可以用 --keep-alive-dylib /
--files-dylib / --panel-dylib 指定单独的 dylib，那时退回一功能一库的注入方式。
"""
from __future__ import annotations

import os
import platform
import shutil
import subprocess

from . import ipa as ipa_mod
from . import macho, plistutil
from .bundle import Bundle, Change

KEEP_ALIVE_DYLIB_NAME = "KeepAlive.dylib"
KEEP_ALIVE_INFO_KEY = "IPAToolKeepAlive"
KEEP_ALIVE_REQUIRED_BACKGROUND_MODE = "audio"
KEEP_ALIVE_AUDIO_STEM = "ipatool_keepalive_audio"
BG_REFRESH_TASK_ID = "com.ipatool.keepalive.refresh"
BG_PROCESSING_TASK_ID = "com.ipatool.keepalive.processing"
LOCATION_USAGE_KEYS = (
    "NSLocationWhenInUseUsageDescription",
    "NSLocationAlwaysAndWhenInUseUsageDescription",
)
LOCATION_USAGE_TEXT = "App 需要在后台继续更新资源"

CONTROL_PANEL_DYLIB_NAME = "ControlPanel.dylib"
CONTROL_PANEL_INFO_KEY = "IPAToolControl"
PANEL_NAME = "ControlPanel"

FILES_DYLIB_NAME = "FileBridge.dylib"
FILES_INFO_KEY = "IPAToolFiles"
FILES_NAME = "FileBridge"
FILES_DEFAULT_IMPORT_DIR = "Documents"

# 三个内置功能默认合编成一个 IPATool.dylib：只注入一次，
# 开哪些功能由 Info.plist 里 IPAToolKeepAlive / IPAToolControl / IPAToolFiles 的 Enabled 决定。
# 单功能 dylib 仍然支持（显式给了某个功能的 dylib 路径时就用老的分离注入）。
MERGED_DYLIB_NAME = "IPATool.dylib"
MERGED_NAME = "IPATool"

# 注入的内置 tweak：名字 -> (dylib 文件名, 环境变量)
TWEAKS = {
    "KeepAlive": (KEEP_ALIVE_DYLIB_NAME, "IPATOOL_KEEPALIVE_DYLIB"),
    PANEL_NAME: (CONTROL_PANEL_DYLIB_NAME, "IPATOOL_CONTROL_DYLIB"),
    FILES_NAME: (FILES_DYLIB_NAME, "IPATOOL_FILES_DYLIB"),
    MERGED_NAME: (MERGED_DYLIB_NAME, "IPATOOL_DYLIB"),
}


class InjectError(RuntimeError):
    pass


# --------------------------------------------------------------------------- #
# 定位 / 编译内置 tweak
# --------------------------------------------------------------------------- #
def _package_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _tweak_candidates(name: str) -> list[str]:
    dylib_name = TWEAKS[name][0]
    root = _package_root()
    return [
        os.path.join(root, "tweak", "build", dylib_name),
        os.path.join(os.path.dirname(os.path.abspath(__file__)), dylib_name),
    ]


def build_tweak_dylib(name: str, log=print) -> str:
    """在 macOS 上调 tweak/build.sh 编译指定的内置 tweak。"""
    script = os.path.join(_package_root(), "tweak", "build.sh")
    env_var = TWEAKS[name][1]
    if platform.system() != "Darwin":
        raise InjectError(
            f"找不到 {name} 的 dylib，而编译 iOS dylib 需要 macOS + Xcode。"
            f"当前系统是 {platform.system()}，请在 macOS 上执行 tweak/build.sh 编译，"
            f"或用环境变量 {env_var} 指定已编译好的 dylib 路径"
        )
    if not os.path.isfile(script):
        raise InjectError(f"找不到编译脚本: {script}")
    log(f"未找到已编译的 dylib，正在编译：{script}（目标 {name}）")
    env = dict(os.environ, IPATOOL_TARGETS=name)
    r = subprocess.run(["bash", script], capture_output=True, check=False, env=env)
    out = (r.stdout + r.stderr).decode("utf-8", "replace").strip()
    if r.returncode != 0:
        raise InjectError(f"编译失败：\n{out}")
    if out:
        log(out)
    for candidate in _tweak_candidates(name):
        if os.path.isfile(candidate):
            return candidate
    raise InjectError("编译脚本执行完毕但没找到产物，请手动指定 dylib 路径")


def locate_tweak_dylib(
    name: str,
    explicit: str | None = None,
    auto_build: bool = True,
    log=print,
) -> str:
    """按「显式指定 -> 环境变量 -> 已编译产物 -> 现场编译」的顺序查找内置 tweak。"""
    if name not in TWEAKS:
        raise InjectError(f"未知的内置 tweak: {name}")
    env_var = TWEAKS[name][1]

    if explicit:
        if not os.path.isfile(explicit):
            raise InjectError(f"找不到 dylib: {explicit}")
        return explicit

    env = os.environ.get(env_var)
    if env:
        if not os.path.isfile(env):
            raise InjectError(f"环境变量 {env_var} 指向的文件不存在: {env}")
        return env

    for candidate in _tweak_candidates(name):
        if os.path.isfile(candidate):
            return candidate

    if auto_build:
        return build_tweak_dylib(name, log=log)

    raise InjectError(
        f"找不到 {name} 的 dylib。请在 macOS 上执行 tweak/build.sh 编译，"
        f"或指定已编译好的 dylib 路径，也可用环境变量 {env_var} 指定"
    )


def locate_keep_alive_dylib(explicit: str | None = None, auto_build: bool = True, log=print) -> str:
    return locate_tweak_dylib("KeepAlive", explicit=explicit, auto_build=auto_build, log=log)


def locate_control_panel_dylib(explicit: str | None = None, auto_build: bool = True, log=print) -> str:
    return locate_tweak_dylib(PANEL_NAME, explicit=explicit, auto_build=auto_build, log=log)


def locate_files_dylib(explicit: str | None = None, auto_build: bool = True, log=print) -> str:
    return locate_tweak_dylib(FILES_NAME, explicit=explicit, auto_build=auto_build, log=log)


def locate_merged_dylib(explicit: str | None = None, auto_build: bool = True, log=print) -> str:
    """定位合编了三个功能的 IPATool.dylib。"""
    return locate_tweak_dylib(MERGED_NAME, explicit=explicit, auto_build=auto_build, log=log)


# --------------------------------------------------------------------------- #
# 主可执行文件
# --------------------------------------------------------------------------- #
def find_main_executable(app: Bundle) -> str:
    if app.executable:
        path = os.path.join(app.path, app.executable)
        if os.path.isfile(path):
            return path
    for name in sorted(os.listdir(app.path)):
        full = os.path.join(app.path, name)
        if os.path.isfile(full) and ipa_mod.is_macho(full):
            return full
    raise InjectError(f"{app.rel} 里找不到主可执行文件（CFBundleExecutable）")


# --------------------------------------------------------------------------- #
# 注入 dylib
# --------------------------------------------------------------------------- #
def inject_dylib(
    app: Bundle,
    dylib_path: str,
    name: str | None = None,
    dry_run: bool = False,
) -> list[str]:
    """把 dylib 复制进 Frameworks/ 并写入 LC_LOAD_DYLIB，返回日志行。"""
    dylib_name = name or os.path.basename(dylib_path)
    if not dylib_name.endswith(".dylib"):
        dylib_name += ".dylib"

    frameworks = os.path.join(app.path, "Frameworks")
    dest = os.path.join(frameworks, dylib_name)
    load_path = f"@executable_path/Frameworks/{dylib_name}"
    executable = find_main_executable(app)

    logs: list[str] = []
    if not dry_run:
        os.makedirs(frameworks, exist_ok=True)
        if os.path.abspath(dylib_path) != os.path.abspath(dest):
            shutil.copyfile(dylib_path, dest)
            try:
                shutil.copymode(dylib_path, dest)
            except OSError:
                pass
        logs.append(f"dylib 已放入 {os.path.relpath(dest, os.path.dirname(app.path))}")

    try:
        added, lines = macho.add_dylib(executable, load_path, dry_run=dry_run)
    except macho.MachOError as e:
        raise InjectError(str(e)) from e

    logs.extend(lines)
    if not added:
        logs.append(f"{os.path.basename(executable)} 中已存在 {load_path}，未重复添加")
    return logs


def build_keep_alive_options(
    silent_audio: bool | None = None,
    enabled: bool | None = None,
    start_on: str | None = None,
    task_renew: bool | None = None,
    renew_lead_time: float | None = None,
    audio_file: str | None = None,
    location: bool | None = None,
    location_indicator: bool | None = None,
    fetch: bool | None = None,
    processing: bool | None = None,
    refresh_interval: int | None = None,
) -> dict:
    """只写入显式指定的项，其余交给 dylib 里的默认值。"""
    options: dict = {}
    if enabled is not None:
        options["Enabled"] = enabled
    if silent_audio is not None:
        options["SilentAudio"] = silent_audio
    if start_on:
        options["StartAtLaunch"] = start_on == "launch"
    if task_renew is not None:
        options["RenewBackgroundTask"] = task_renew
    if renew_lead_time:
        options["RenewLeadTime"] = float(renew_lead_time)
    if audio_file:
        options["AudioFile"] = audio_file
    if location is not None:
        options["Location"] = location
    if location_indicator is not None:
        options["LocationIndicator"] = location_indicator
    if fetch is not None:
        options["Fetch"] = fetch
    if processing is not None:
        options["Processing"] = processing
    if refresh_interval:
        options["RefreshInterval"] = int(refresh_interval)
    return options


def keep_alive_background_modes(
    silent_audio: bool = True,
    location: bool = False,
    fetch: bool = False,
    processing: bool = False,
) -> list[str]:
    modes: list[str] = []
    if silent_audio:
        modes.append(KEEP_ALIVE_REQUIRED_BACKGROUND_MODE)
    if location:
        modes.append("location")
    if fetch:
        modes.append("fetch")
    if processing:
        modes.append("processing")
    return modes


def keep_alive_scheduler_ids(fetch: bool = False, processing: bool = False) -> list[str]:
    ids: list[str] = []
    if fetch:
        ids.append(BG_REFRESH_TASK_ID)
    if processing:
        ids.append(BG_PROCESSING_TASK_ID)
    return ids


def keep_alive_audio_name(audio_path: str) -> str:
    return KEEP_ALIVE_AUDIO_STEM + os.path.splitext(audio_path)[1].lower()


# --------------------------------------------------------------------------- #
# 悬浮控制面板配置
# --------------------------------------------------------------------------- #
def build_panel_options(title: str | None = None, enabled: bool | None = None) -> dict:
    """只写入显式指定的项，其余交给 dylib 里的默认值。"""
    options: dict = {}
    if title:
        options["Title"] = title
    if enabled is not None:
        options["Enabled"] = enabled
    return options


# --------------------------------------------------------------------------- #
# 文件导入导出配置
# --------------------------------------------------------------------------- #
def build_files_options(
    root: str | None = None,
    import_dir: str | None = None,
    enabled: bool | None = None,
) -> dict:
    """只写入显式指定的项，其余交给 dylib 里的默认值。"""
    options: dict = {}
    if root:
        options["Root"] = root
    if import_dir:
        options["ImportDir"] = import_dir
    if enabled is not None:
        options["Enabled"] = enabled
    return options


# --------------------------------------------------------------------------- #
# Info.plist 配置
# --------------------------------------------------------------------------- #
def _fmt(value) -> str:
    if isinstance(value, bool):
        return "YES" if value else "NO"
    return str(value)


def configure_plist(
    app: Bundle,
    background_modes: list[str] | None = None,
    settings: list[tuple[str, dict, str]] | None = None,
    location: bool = False,
    scheduler_ids: list[str] | None = None,
    strip_exit_on_suspend: bool = False,
    ats_arbitrary_loads: bool = False,
    file_sharing: bool = False,
    dry_run: bool = False,
) -> tuple[list[Change], list[str]]:
    """
    统一写 Info.plist（幂等，重复注入不会叠加）：

      - background_modes：追加到 UIBackgroundModes
      - settings：[(Info.plist 键, 配置字典, 说明)]，与已有字典合并
      - location：补定位权限说明（缺这两项时 allowsBackgroundLocationUpdates 不生效）
      - scheduler_ids：补 BGTaskSchedulerPermittedIdentifiers（BGTaskScheduler 要求提前声明）
      - strip_exit_on_suspend：移除 UIApplicationExitsOnSuspend（切后台即退出，会让保活失效）
      - ats_arbitrary_loads：NSAllowsArbitraryLoads=YES（热更服务器常用明文 HTTP）
      - file_sharing：让 App 的 Documents 出现在系统「文件」App 里（导出/导入热更资源要用）
    """
    if not app.plist_path:
        raise InjectError(f"{app.rel} 没有 Info.plist，无法写入注入配置")

    data = plistutil.load_plist(app.plist_path)
    original = dict(data)
    changes: list[Change] = []
    warnings: list[str] = []

    # 1) 后台模式（保活要 audio，这里去重）
    modes = data.get("UIBackgroundModes")
    modes = list(modes) if isinstance(modes, list) else []
    wanted: list[str] = []
    for mode in background_modes or []:
        if mode not in modes and mode not in wanted:
            wanted.append(mode)
    if wanted:
        modes.extend(wanted)
        data["UIBackgroundModes"] = modes
        changes.append(Change(app.rel, "UIBackgroundModes", None, ", ".join(modes), note="后台模式"))

    # 2) 配置字典（dylib 从这里读参数）
    for key, options, note in settings or []:
        if not options:
            continue
        existing = data.get(key)
        merged = dict(existing) if isinstance(existing, dict) else {}
        merged.update(options)
        if merged == existing:
            continue
        data[key] = merged
        changes.append(
            Change(app.rel, key, None, ", ".join(f"{k}={_fmt(v)}" for k, v in merged.items()), note=note)
        )

    # 3) 定位权限说明
    if location:
        for key in LOCATION_USAGE_KEYS:
            if not data.get(key):
                data[key] = LOCATION_USAGE_TEXT
                changes.append(Change(app.rel, key, None, LOCATION_USAGE_TEXT, note="定位权限说明"))

    # 4) 定时唤醒任务标识
    if scheduler_ids:
        declared = data.get("BGTaskSchedulerPermittedIdentifiers")
        declared = list(declared) if isinstance(declared, list) else []
        missing = [i for i in scheduler_ids if i not in declared]
        if missing:
            declared.extend(missing)
            data["BGTaskSchedulerPermittedIdentifiers"] = declared
            changes.append(
                Change(app.rel, "BGTaskSchedulerPermittedIdentifiers", None, ", ".join(declared),
                       note="定时唤醒")
            )

    # 5) 切后台即退出会直接让保活失效
    if strip_exit_on_suspend:
        for key in ("UIApplicationExitsOnSuspend", "UIApplicationExitOnSuspend"):
            value = data.get(key)
            if value:
                data.pop(key)
                changes.append(Change(app.rel, key, _fmt(value), "已移除", note="切后台即退出，会阻止保活"))

    # 6) ATS：热更服务器常用明文 HTTP
    if ats_arbitrary_loads:
        ats = data.get("NSAppTransportSecurity")
        ats = dict(ats) if isinstance(ats, dict) else {}
        if not ats.get("NSAllowsArbitraryLoads"):
            ats["NSAllowsArbitraryLoads"] = True
            data["NSAppTransportSecurity"] = ats
            changes.append(Change(app.rel, "NSAllowsArbitraryLoads", None, "YES", note="允许明文 HTTP"))

    # 7) 让 Documents 出现在「文件」App 的「我的 iPhone」里，方便导出/导入热更资源
    if file_sharing:
        for key, note in (
            ("UIFileSharingEnabled", "「文件」App 可浏览 Documents"),
            ("LSSupportsOpeningDocumentsInPlace", "「文件」App 可就地打开"),
        ):
            if not data.get(key):
                data[key] = True
                changes.append(Change(app.rel, key, None, "YES", note=note))

    if data != original and not dry_run:
        plistutil.dump_plist(app.plist_path, data)
    return changes, warnings


def place_bundle_file(
    app: Bundle,
    src: str,
    dest_name: str,
    note: str,
    dry_run: bool = False,
) -> list[Change]:
    """把素材文件放进 App 包根目录（Info.plist 里只写文件名即可被 mainBundle 找到）。"""
    if not os.path.isfile(src):
        raise InjectError(f"找不到文件: {src}")
    dest = os.path.join(app.path, dest_name)
    if not dry_run:
        shutil.copyfile(src, dest)
        try:
            shutil.copymode(src, dest)
        except OSError:
            pass
    return [Change(app.rel, dest_name, None, "已放入包内", note=note)]


def place_keep_alive_audio(app: Bundle, audio: str, dry_run: bool = False) -> tuple[list[Change], list[str]]:
    changes = place_bundle_file(app, audio, keep_alive_audio_name(audio), "保活音频", dry_run=dry_run)
    return changes, []


def list_injected(app: Bundle) -> list[str]:
    """列出主可执行文件里所有 @executable_path 形式的依赖（即注入进来的库）。"""
    executable = find_main_executable(app)
    try:
        deps = macho.read_dylibs(executable)
    except (macho.MachOError, OSError) as e:
        raise InjectError(f"解析 {os.path.basename(executable)} 失败: {e}") from e
    return [d for d in deps if d.startswith("@executable_path/")]
