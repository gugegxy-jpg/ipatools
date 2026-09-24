"""
dylib 注入：把动态库放进 App 的 Frameworks/ 并给主可执行文件加 LC_LOAD_DYLIB。

附带「文件导入导出」（--files）：
  - 写入 IPAToolFiles 配置字典 + 让 App 的 Documents 在系统「文件」App 里可见
    （UIFileSharingEnabled / LSSupportsOpeningDocumentsInPlace）
  - 用来把游戏热更资源导出到「文件」App，或从「文件」App 导回沙盒

以及「运行时插件加载」（--plugins）：
  - 写入 IPAToolPlugins 配置字典（Enabled / AutoLoad）
  - 注入一次之后，之后想试的 dylib 放进沙盒就能在 App 里直接 dlopen，
    不用再重新打包签名安装。插件必须用签主 App 的同一把证书签名
    （iOS 的 library validation 看 Team ID），签名用 ipatool signdylib

还有「性能悬浮窗」（--solox，独立 dylib）：
  - 单独出 SoloX.dylib（不走合编），注入后在游戏内悬浮窗里挂「性能悬浮窗」开关，
    屏幕顶部漂浮显示 CPU / 内存 / 网络 / FPS / 电量 / 温度，且点击穿透到游戏
  - 开关在游戏内悬浮窗里控制（需同时注入悬浮窗 --panel 或任一内置功能）

上面这些功能都合编在同一个 IPATool.dylib 里（内含悬浮窗），注入一次即可，
用哪个功能由对应的 Info.plist 配置字典决定（没用到的会写成 Enabled=NO）；
用 --no-panel 可以不带悬浮窗。

需要单独出包时（比如改了某个功能只想重编它）可以用 --files-dylib /
--qnet-dylib / --plugins-dylib / --panel-dylib / --solox-dylib 指定单独的 dylib，
那时退回一功能一库的注入方式。
"""
from __future__ import annotations

import os
import platform
import shutil
import subprocess

from . import ipa as ipa_mod
from . import macho, plistutil
from .bundle import Bundle, Change

CONTROL_PANEL_DYLIB_NAME = "ControlPanel.dylib"
CONTROL_PANEL_INFO_KEY = "IPAToolControl"
PANEL_NAME = "ControlPanel"

FILES_DYLIB_NAME = "FileBridge.dylib"
FILES_INFO_KEY = "IPAToolFiles"
FILES_NAME = "FileBridge"
FILES_DEFAULT_IMPORT_DIR = "Documents"

QNET_DYLIB_NAME = "QNet.dylib"
QNET_INFO_KEY = "IPAToolQNet"
QNET_NAME = "QNet"
# 开了弱网但一项参数都没给时套用的档位（大概 3G 水平），
# 这样 --qnet 一注入就能看出效果，不用再逐个调
QNET_DEFAULT_PROFILE = {
    "DownKbps": 300,
    "UpKbps": 150,
    "DelayMs": 150,
    "JitterMs": 40,
    "LossPct": 2,
}

PLUGINS_DYLIB_NAME = "PluginLoader.dylib"
PLUGINS_INFO_KEY = "IPAToolPlugins"
PLUGINS_NAME = "PluginLoader"

# 性能悬浮窗（SoloX）：独立 dylib，注入后在游戏内悬浮窗里挂开关，
# 自身在屏幕顶部漂浮显示 CPU/内存/网络/FPS/电量/温度，并穿透点击。
SOLOX_DYLIB_NAME = "SoloX.dylib"
SOLOX_INFO_KEY = "IPAToolSoloX"
SOLOX_NAME = "SoloX"

# 四个内置功能默认合编成一个 IPATool.dylib：只注入一次，
# 开哪些功能由 Info.plist 里 IPAToolControl / IPAToolFiles / IPAToolQNet / IPAToolPlugins
# 的 Enabled 决定。
# 单功能 dylib 仍然支持（显式给了某个功能的 dylib 路径时就用老的分离注入）。
MERGED_DYLIB_NAME = "IPATool.dylib"
MERGED_NAME = "IPATool"

# 注入的内置 tweak：名字 -> (dylib 文件名, 环境变量)
TWEAKS = {
    PANEL_NAME: (CONTROL_PANEL_DYLIB_NAME, "IPATOOL_CONTROL_DYLIB"),
    FILES_NAME: (FILES_DYLIB_NAME, "IPATOOL_FILES_DYLIB"),
    QNET_NAME: (QNET_DYLIB_NAME, "IPATOOL_QNET_DYLIB"),
    PLUGINS_NAME: (PLUGINS_DYLIB_NAME, "IPATOOL_PLUGINS_DYLIB"),
    MERGED_NAME: (MERGED_DYLIB_NAME, "IPATOOL_DYLIB"),
    SOLOX_NAME: (SOLOX_DYLIB_NAME, "IPATOOL_SOLOX_DYLIB"),
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


def locate_control_panel_dylib(explicit: str | None = None, auto_build: bool = True, log=print) -> str:
    return locate_tweak_dylib(PANEL_NAME, explicit=explicit, auto_build=auto_build, log=log)


def locate_files_dylib(explicit: str | None = None, auto_build: bool = True, log=print) -> str:
    return locate_tweak_dylib(FILES_NAME, explicit=explicit, auto_build=auto_build, log=log)


def locate_qnet_dylib(explicit: str | None = None, auto_build: bool = True, log=print) -> str:
    return locate_tweak_dylib(QNET_NAME, explicit=explicit, auto_build=auto_build, log=log)


def locate_plugins_dylib(explicit: str | None = None, auto_build: bool = True, log=print) -> str:
    return locate_tweak_dylib(PLUGINS_NAME, explicit=explicit, auto_build=auto_build, log=log)


def locate_merged_dylib(explicit: str | None = None, auto_build: bool = True, log=print) -> str:
    """定位合编了三个功能的 IPATool.dylib。"""
    return locate_tweak_dylib(MERGED_NAME, explicit=explicit, auto_build=auto_build, log=log)


def locate_solox_dylib(explicit: str | None = None, auto_build: bool = True, log=print) -> str:
    """定位性能悬浮窗 SoloX.dylib（独立 tweak）。"""
    return locate_tweak_dylib(SOLOX_NAME, explicit=explicit, auto_build=auto_build, log=log)


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
    # 同名 dylib 已存在就是「覆盖注入」：文件会被换成新的，加载命令不用再动，
    # 日志要说清是覆盖，别让人以为没注入
    replaced = os.path.isfile(dest)
    if not dry_run:
        os.makedirs(frameworks, exist_ok=True)
        if os.path.abspath(dylib_path) != os.path.abspath(dest):
            shutil.copyfile(dylib_path, dest)
            try:
                shutil.copymode(dylib_path, dest)
            except OSError:
                pass
    rel = os.path.relpath(dest, os.path.dirname(app.path))
    if dry_run:
        logs.append(f"{'将覆盖' if replaced else '将放入'} {rel}"
                    + ("（该位置已有同名 dylib，会被换成新版本）" if replaced else ""))
    elif replaced:
        logs.append(f"dylib 已覆盖（旧文件换成新版本）：{rel}")
    else:
        logs.append(f"dylib 已放入 {rel}")

    try:
        added, lines = macho.add_dylib(executable, load_path, dry_run=dry_run)
    except macho.MachOError as e:
        raise InjectError(str(e)) from e

    logs.extend(lines)
    if not added:
        logs.append(f"{os.path.basename(executable)} 里已有指向 {load_path} 的加载命令，"
                    "不需要重复添加——这次只是把同一个位置的 dylib 文件换成了新版本")
    return logs


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
# 弱网测试（QNet）配置
# --------------------------------------------------------------------------- #
def build_qnet_options(
    enabled: bool | None = None,
    down: int | None = None,
    up: int | None = None,
    delay: int | None = None,
    jitter: int | None = None,
    loss: int | None = None,
    use_defaults: bool = False,
) -> dict:
    """
    只写入显式指定的项，其余交给 dylib 里的默认值（0 = 不限制）。

    use_defaults=True 且一项参数都没指定时，套一份 3G 档的默认值（QNET_DEFAULT_PROFILE），
    免得「开了弱网但什么都不设」看起来跟没开一样。
    """
    options: dict = {}
    if enabled is not None:
        options["Enabled"] = enabled
    if down is not None:
        options["DownKbps"] = int(down)
    if up is not None:
        options["UpKbps"] = int(up)
    if delay is not None:
        options["DelayMs"] = int(delay)
    if jitter is not None:
        options["JitterMs"] = int(jitter)
    if loss is not None:
        options["LossPct"] = max(0, min(100, int(loss)))
    detail_keys = ("DownKbps", "UpKbps", "DelayMs", "JitterMs", "LossPct")
    if use_defaults and not any(k in options for k in detail_keys):
        options.update(QNET_DEFAULT_PROFILE)
    return options


# --------------------------------------------------------------------------- #
# 运行时插件加载（PluginLoader）配置
# --------------------------------------------------------------------------- #
def build_plugins_options(
    enabled: bool | None = None,
    auto_load: bool | None = None,
) -> dict:
    """
    Enabled 控制能不能用（关掉后不再自动加载，面板入口也不可用）；
    AutoLoad 控制下次启动是否自动 dlopen 上次加载过的插件。

    插件文件本身不在这里配置：它是运行时从沙盒里挑的，见 tweak/PluginLoader.m。
    """
    options: dict = {}
    if enabled is not None:
        options["Enabled"] = enabled
    if auto_load is not None:
        options["AutoLoad"] = auto_load
    return options


def build_solox_options(
    enabled: bool | None = None,
) -> dict:
    """性能悬浮窗（SoloX）配置：仅写显式指定的项，其余交给 dylib 默认值。

    enabled 控制注入后是否默认显示（总开关）；各指标子开关在游戏内悬浮窗里调，
    不在这里配。
    """
    options: dict = {}
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
    ats_arbitrary_loads: bool = False,
    file_sharing: bool = False,
    dry_run: bool = False,
) -> tuple[list[Change], list[str]]:
    """
    统一写 Info.plist（幂等，重复注入不会叠加）：

      - background_modes：追加到 UIBackgroundModes
      - settings：[(Info.plist 键, 配置字典, 说明)]，与已有字典合并
      - ats_arbitrary_loads：NSAllowsArbitraryLoads=YES（热更服务器常用明文 HTTP）
      - file_sharing：让 App 的 Documents 出现在系统「文件」App 里（导出/导入热更资源要用）
    """
    if not app.plist_path:
        raise InjectError(f"{app.rel} 没有 Info.plist，无法写入注入配置")

    data = plistutil.load_plist(app.plist_path)
    original = dict(data)
    changes: list[Change] = []
    warnings: list[str] = []

    # 1) 后台模式（去重）
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

    # 3) ATS：热更服务器常用明文 HTTP
    if ats_arbitrary_loads:
        ats = data.get("NSAppTransportSecurity")
        ats = dict(ats) if isinstance(ats, dict) else {}
        if not ats.get("NSAllowsArbitraryLoads"):
            ats["NSAllowsArbitraryLoads"] = True
            data["NSAppTransportSecurity"] = ats
            changes.append(Change(app.rel, "NSAllowsArbitraryLoads", None, "YES", note="允许明文 HTTP"))

    # 4) 让 Documents 出现在「文件」App 的「我的 iPhone」里，方便导出/导入热更资源
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


def list_injected(app: Bundle) -> list[str]:
    """列出主可执行文件里所有 @executable_path 形式的依赖（即注入进来的库）。"""
    executable = find_main_executable(app)
    try:
        deps = macho.read_dylibs(executable)
    except (macho.MachOError, OSError) as e:
        raise InjectError(f"解析 {os.path.basename(executable)} 失败: {e}") from e
    return [d for d in deps if d.startswith("@executable_path/")]
