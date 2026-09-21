"""连接 iOS 设备、把签好名的 IPA 装上去。

只做两件事：列出设备、安装 IPA。底层调现成的命令行工具，不 import 它们的 API，
所以本模块只用标准库。

两个后端，按可用性自动选：

| 后端 | 怎么来的 | 说明 |
| --- | --- | --- |
| `pymobiledevice3` | `pip install pymobiledevice3` | 纯 Python，Windows / macOS / Linux 通用，推荐 |
| `ideviceinstaller` | libimobiledevice 那套 | 列设备用 `idevice_id`，装包用 `ideviceinstaller` |

两个后端在 Windows 上都靠 Apple 的 usbmuxd 驱动认设备：装了 iTunes 或
「Apple Mobile Device Support」才能识别 iPhone；设备还要在弹窗里点过「信任」。
"""
from __future__ import annotations

import json
import locale
import os
import platform
import plistlib
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
import zipfile
from dataclasses import dataclass
from typing import Callable, Optional

BACKENDS = ("auto", "pymobiledevice3", "ideviceinstaller")

PMD3_ENV = "IPATOOL_PYMOBILEDEVICE3"          # 直接指到 pymobiledevice3 可执行文件
IDEVICE_ENV = "IPATOOL_IDEVICEINSTALLER"      # 直接指到 ideviceinstaller 可执行文件
DEVICE_ENV = "IPATOOL_DEVICE_UDID"            # 默认设备，省得每次都写 --udid
API_ENV = "IPATOOL_INSTALL_CLI"               # =1 就不用 Python API，改回命令行装（进度只有心跳）

PMD3_HINT = "pip install pymobiledevice3"
IDEVICE_HINT = ("Windows / macOS 装 libimobiledevice 的 ideviceinstaller"
                "（macOS: brew install libimobiledevice ideviceinstaller）")

LIST_TIMEOUT = 120.0        # 列设备：卡住就早点报错，别让界面干等
INSTALL_TIMEOUT = 1800.0    # 装包：几个 GB 的游戏慢慢传也要等，30 分钟够用
INSTALL_STALL = 600.0       # 装包：installation_proxy 报过进度后，超过 10 分钟没新进度就判定卡住

# 探到过的「--udid 放哪」，按工具路径缓存（省掉每次安装都白跑一次失败尝试）
_PMD3_UDID_POSITION: dict[str, str] = {}


class DeviceError(RuntimeError):
    """设备相关操作失败（找不到工具、认不到设备、安装被拒……）。"""


class InstallCancelled(Exception):
    """用户在「要不要卸载重装」那一步选了取消（不是失败）。"""


# 「设备上已有同一个 App」时的询问钩子：图形界面把它接到自己的弹窗上
_confirm_hook: Optional[Callable[[str], Optional[bool]]] = None


def set_confirm_hook(fn: Optional[Callable[[str], Optional[bool]]]) -> None:
    """给图形界面用：装之前那句「要不要先卸载」交给它来问。

    返回值：True = 先卸载再装，False = 不卸载直接装，None = 用户取消。
    """
    global _confirm_hook
    _confirm_hook = fn


@dataclass
class Device:
    """一台连着的设备。除 udid 外都可能为空（不同后端的字段不一样）。"""

    udid: str
    name: str = ""
    model: str = ""
    version: str = ""
    connection: str = ""

    @property
    def label(self) -> str:
        """给下拉框 / 命令行看的一行，末尾带上 UDID 尾巴便于区分同型号。"""
        bits = [self.name or "(未命名设备)"]
        if self.model:
            bits.append(self.model)
        if self.version:
            bits.append(f"iOS {self.version}")
        if self.connection:
            bits.append(self.connection)
        tail = self.udid[-6:] if len(self.udid) > 6 else self.udid
        return f"{' · '.join(bits)}（{tail}）"

    def as_dict(self) -> dict:
        return {
            "udid": self.udid,
            "name": self.name,
            "model": self.model,
            "version": self.version,
            "connection": self.connection,
            "label": self.label,
        }


@dataclass
class Backend:
    """选中的后端：主工具的启动命令 + （ideviceinstaller 系）配套工具路径。"""

    name: str
    argv: list[str]
    detail: str = ""
    idevice_id: str | None = None
    idevice_info: str | None = None


# --------------------------------------------------------------------------- #
# 小工具
# --------------------------------------------------------------------------- #
def _text(result: subprocess.CompletedProcess) -> str:
    """把 stdout + stderr 拼成一段文本（这些工具的报错经常写在 stdout 里）。"""
    raw = (result.stdout or b"") + (result.stderr or b"")
    for enc in ("utf-8", locale.getpreferredencoding(False)):
        try:
            return _clean(raw.decode(enc))
        except (UnicodeDecodeError, LookupError):
            continue
    return _clean(raw.decode("utf-8", "replace"))


def _run(argv: list[str], timeout: float = LIST_TIMEOUT) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(argv, capture_output=True, timeout=timeout, check=False)
    except FileNotFoundError:
        raise DeviceError(f"找不到可执行文件：{argv[0]}\n{backend_report()}")
    except subprocess.TimeoutExpired:
        raise DeviceError(f"命令超时（{timeout:.0f}s）：{' '.join(argv)}")
    except OSError as exc:
        raise DeviceError(f"执行失败：{exc}")


_PERCENT_RE = re.compile(r"(\d{1,3})\s*%|percentcomplete['\"]?\s*[:=]\s*(\d{1,3})", re.I)
# ANSI 颜色 / 光标控制符：工具和库的日志里常带这些，落到我们的日志里就是乱码
_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def _clean(text: str) -> str:
    """去掉 ANSI 转义，日志里只留能读的文字。"""
    return _ANSI_RE.sub("", text) if "\x1b" in text else text


def _human(size: float) -> str:
    """字节数说人话：1536 -> 1.5 KB。"""
    for unit, scale in (("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10)):
        if size >= scale:
            return f"{size / scale:.1f} {unit}"
    return f"{size:.0f} B"


def _parse_percent(text: str) -> int | None:
    """从工具输出里认进度：`45%`、`Install: 45%`、`'PercentComplete': 45` 都认。"""
    match = _PERCENT_RE.search(text)
    if not match:
        return None
    value = int(match.group(1) or match.group(2))
    return value if 0 <= value <= 100 else None


def _exists(path: str) -> str:
    if os.path.isfile(path):
        return os.path.abspath(path)
    raise DeviceError(f"指定的可执行文件不存在：{path}")


def _argv_for(path: str) -> list[str]:
    """顺手支持 .py 脚本（用当前解释器跑），方便自己接一个后端进来。"""
    return [sys.executable, path] if path.lower().endswith(".py") else [path]


def _sibling(binary: str, name: str) -> str | None:
    """找与 binary 同目录的同套工具（ideviceinstaller 旁边就是 idevice_id）。"""
    directory = os.path.dirname(os.path.abspath(binary))
    for candidate in (name, f"{name}.exe"):
        path = os.path.join(directory, candidate)
        if os.path.isfile(path):
            return path
    return shutil.which(name)


def _usable(result: subprocess.CompletedProcess, argv: list[str]) -> bool:
    """命令能不能跑：能跑起来（不是「没有这个命令/选项」）就算可用。"""
    if result.returncode == 0:
        return True
    text = _text(result).lower()
    for bad in ("no such command", "no such option", "unrecognized argument",
                "unexpected extra argument", "unknown command", "invalid value",
                "is not a recognized", "无法将", "不是内部或外部命令"):
        if bad in text:
            return False
    return True


def _usage_error(result: subprocess.CompletedProcess) -> bool:
    """看起来是「命令写法不对」（而不是设备/签名问题）。"""
    text = _text(result).lower()
    return ("usage:" in text or "no such option" in text
            or "unexpected extra argument" in text or "no such command" in text)


# --------------------------------------------------------------------------- #
# 后端解析
# --------------------------------------------------------------------------- #
def _pmd3_argv() -> list[str] | None:
    explicit = os.environ.get(PMD3_ENV, "").strip().strip('"')
    if explicit:
        return _argv_for(_exists(explicit))
    try:
        import importlib.util

        if importlib.util.find_spec("pymobiledevice3") is not None:
            return [sys.executable, "-m", "pymobiledevice3"]
    except Exception:
        pass
    found = shutil.which("pymobiledevice3")
    return _argv_for(found) if found else None


def _ideviceinstaller_path() -> str | None:
    explicit = os.environ.get(IDEVICE_ENV, "").strip().strip('"')
    if explicit:
        return _exists(explicit)
    return shutil.which("ideviceinstaller")


def resolve_backend(prefer: str = "auto", tool: str | None = None) -> Backend:
    """挑一个能用的后端；都没有就把装法写清楚报出来。"""
    if tool:
        path = _exists(tool)
        if "idevice" in os.path.basename(path).lower():
            return Backend("ideviceinstaller", _argv_for(path), detail=path,
                           idevice_id=_sibling(path, "idevice_id"),
                           idevice_info=_sibling(path, "ideviceinfo"))
        return Backend("pymobiledevice3", _argv_for(path), detail=path)

    wanted = (prefer,) if prefer != "auto" else ("pymobiledevice3", "ideviceinstaller")
    for name in wanted:
        if name == "pymobiledevice3":
            argv = _pmd3_argv()
            if argv:
                return Backend("pymobiledevice3", argv, detail=" ".join(argv))
            if prefer == name:
                raise DeviceError(
                    f"找不到 pymobiledevice3。\n装法: {PMD3_HINT}\n"
                    f"或用 {PMD3_ENV}=/路径/pymobiledevice3 指定可执行文件"
                )
        else:
            path = _ideviceinstaller_path()
            if path:
                return Backend("ideviceinstaller", [path], detail=path,
                               idevice_id=_sibling(path, "idevice_id"),
                               idevice_info=_sibling(path, "ideviceinfo"))
            if prefer == name:
                raise DeviceError(
                    f"找不到 ideviceinstaller。\n装法: {IDEVICE_HINT}\n"
                    f"或用 {IDEVICE_ENV}=/路径/ideviceinstaller 指定可执行文件"
                )
    raise DeviceError(
        "没找到连设备的命令行工具 —— 这不是「设备没连上」："
        "爱思 / iTunes 能连说明驱动是好的，装一个工具即可。\n" + backend_report()
    )


def backend_report() -> str:
    """两个后端各自缺什么，一次说清（只在报错和 --help 里出现）。"""
    pmd3 = _pmd3_argv()
    idevice = _ideviceinstaller_path()
    lines = [f"pymobiledevice3: {pmd3[0] if pmd3 else '没找到（' + PMD3_HINT + '）'}",
             f"ideviceinstaller: {idevice or '没找到（' + IDEVICE_HINT + '）'}"]
    if platform.system() == "Windows":
        lines.append("Windows 提示: 设备能被识别还需要 Apple 的 usbmuxd 驱动"
                     "（装 iTunes 或 Apple Mobile Device Support），并在手机上点「信任」")
    return "\n".join(lines)


# --------------------------------------------------------------------------- #
# 列设备
# --------------------------------------------------------------------------- #
def _pick(merged: dict, *keys: str) -> str:
    for key in keys:
        value = merged.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
        if isinstance(value, int):
            return str(value)
    return ""


def _device_from_dict(item: dict) -> Device:
    """pymobiledevice3 的两种形态都吃：lockdownd 的 short_info、usbmuxd 原始条目。"""
    props = item.get("Properties")
    merged = {**(props if isinstance(props, dict) else {}), **item}
    return Device(
        udid=_pick(merged, "UniqueDeviceID", "Identifier", "SerialNumber", "UDID", "udid"),
        name=_pick(merged, "DeviceName", "DeviceNameString", "name"),
        model=_pick(merged, "ProductType", "HardwareModel", "DeviceClass"),
        version=_pick(merged, "ProductVersion", "version"),
        connection=_pick(merged, "ConnectionType", "connection"),
    )


def _pmd3_devices(backend: Backend) -> list[Device]:
    result = _run([*backend.argv, "usbmux", "list"])
    if result.returncode != 0 and not _usage_error(result):
        raise DeviceError("列出设备失败：\n" + _text(result).strip())
    devices: list[Device] = []
    try:
        data = json.loads(_text(result) or "[]")
    except ValueError:
        # 版本差异导致输出不是 JSON：退回「只列 UDID」那档，至少能用
        simple = _run([*backend.argv, "usbmux", "list", "--simple"])
        data = [line.strip() for line in _text(simple).splitlines() if line.strip()]
    if isinstance(data, list):
        for item in data:
            if isinstance(item, str) and item.strip():
                devices.append(Device(udid=item.strip()))
            elif isinstance(item, dict):
                device = _device_from_dict(item)
                if device.udid:
                    devices.append(device)
    return devices


def _idevice_devices(backend: Backend) -> list[Device]:
    if not backend.idevice_id:
        raise DeviceError(
            "找不到 idevice_id（列设备要用它）。\n"
            f"装法: {IDEVICE_HINT}\n"
            f"或用 {IDEVICE_ENV} 指向 ideviceinstaller，同目录下的 idevice_id 会被自动带上"
        )
    result = _run([backend.idevice_id, "-l"])
    if result.returncode != 0:
        raise DeviceError("列出设备失败：\n" + _text(result).strip())
    devices: list[Device] = []
    for line in _text(result).splitlines():
        udid = line.strip()
        if not udid:
            continue
        devices.append(_idevice_info(backend, udid))
    return devices


def _idevice_info(backend: Backend, udid: str) -> Device:
    """拿设备名 / 型号 / 系统版本；查不到就只留 UDID，不影响安装。"""
    device = Device(udid=udid)
    if not backend.idevice_info:
        return device
    result = _run([backend.idevice_info, "-u", udid])
    if result.returncode != 0:
        return device
    values: dict[str, str] = {}
    for line in _text(result).splitlines():
        key, sep, value = line.partition(":")
        if sep and value.strip() not in ("", "None"):
            values[key.strip()] = value.strip()
    device.name = values.get("DeviceName", "")
    device.model = values.get("ProductType", "")
    device.version = values.get("ProductVersion", "")
    return device


def list_devices(backend: Backend) -> list[Device]:
    devices = _pmd3_devices(backend) if backend.name == "pymobiledevice3" else _idevice_devices(backend)
    devices.sort(key=lambda d: d.udid)
    return devices


def no_device_hint() -> str:
    system = platform.system()
    lines = ["  1) 数据线接好，手机解锁后在弹窗点「信任此电脑」",
             "  2) 手机上「设置 → 隐私与安全性 → 开发者模式」打开（iOS 16+ 装自签应用需要）",
             "  3) 换个 USB 口 / 换根线（充电线可能没有数据线芯）"]
    if system == "Windows":
        lines.append("  4) 装 Apple 的 usbmuxd 驱动：iTunes 或 Apple Mobile Device Support；"
                     "装完重启一次「Apple Mobile Device Service」")
    elif system == "Darwin":
        lines.append("  4) macOS 上首次连接要在 Finder 里点过「信任」")
    lines.append(f"  5) 也可以用 --backend / --tool 指定工具，环境变量: {PMD3_ENV} / {IDEVICE_ENV}")
    return "\n".join(lines)


# --------------------------------------------------------------------------- #
# 已装同 ID 的 App：查一下、问一句、必要时先卸载
# --------------------------------------------------------------------------- #
def ipa_identity(ipa: str) -> tuple[str, str]:
    """从 IPA 里读 (bundle id, 显示名)：只解出 Info.plist，不整包解压。"""
    try:
        with zipfile.ZipFile(ipa) as zf:
            name = next((n for n in zf.namelist()
                         if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)), "")
            if not name:
                return "", ""
            with zf.open(name) as fh:
                info = plistlib.load(fh)
    except (OSError, zipfile.BadZipFile, plistlib.InvalidFileException, ValueError):
        return "", ""
    if not isinstance(info, dict):
        return "", ""
    bundle_id = str(info.get("CFBundleIdentifier") or "")
    display = str(info.get("CFBundleDisplayName") or info.get("CFBundleName") or "")
    return bundle_id, display


def _app_name(info: object) -> str:
    """从 installation_proxy 给的字典里挑一个能显示的名字。"""
    if not isinstance(info, dict):
        return ""
    for key in ("CFBundleDisplayName", "CFBundleName", "CFBundleShortVersionString"):
        value = info.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def _pmd3_with_udid(backend: Backend, udid: str | None, args: list[str]) -> list[str]:
    """按这个版本的参数位置，把 --udid 放到对的位置。"""
    if not udid:
        return [*backend.argv, *args]
    if _pmd3_udid_position(backend) == "top":
        return [*backend.argv, "--udid", udid, *args]
    return [*backend.argv, *args, "--udid", udid]


def _api_lockdown(udid: str | None):
    """建一个 lockdown 连接（老版本签名只收位置参数）。"""
    from pymobiledevice3.lockdown import create_using_usbmux

    async def _create():
        try:
            return await create_using_usbmux(serial=udid)
        except TypeError:
            return await create_using_usbmux(udid)

    return _create()


def find_installed(backend: Backend, bundle_id: str,
                   udid: str | None = None) -> str | None:
    """设备上有没有装同一个 bundle id？

    装了返回它的**名字**（拿不到名字返回空串），没装返回 None。
    """
    if not bundle_id:
        return None
    if backend.name == "pymobiledevice3" and _api_enabled():
        try:
            import asyncio

            from pymobiledevice3.services.installation_proxy import InstallationProxyService

            async def browse():
                service = InstallationProxyService(lockdown=await _api_lockdown(udid))
                return await service.browse()

            apps = asyncio.run(browse())
            if isinstance(apps, dict):
                if bundle_id not in apps:
                    return None
                return _app_name(apps.get(bundle_id))
        except Exception:
            pass            # API 这条路不通就落到命令行查
    if backend.name == "pymobiledevice3":
        result = _run(_pmd3_with_udid(backend, udid, ["apps", "list"]), timeout=LIST_TIMEOUT)
    else:
        cmd = [*backend.argv] + (["-u", udid] if udid else []) + ["-l"]
        result = _run(cmd, timeout=LIST_TIMEOUT)
    if result.returncode != 0:
        raise DeviceError("查设备上已装的应用失败：\n" + _text(result).strip())
    text = _text(result)
    try:
        data = json.loads(text)
    except ValueError:
        return "" if bundle_id in text else None      # 非 JSON 输出：退化成文本包含
    if isinstance(data, dict):
        if bundle_id not in data:
            return None
        return _app_name(data.get(bundle_id))
    if isinstance(data, list):
        for item in data:
            if isinstance(item, dict) and bundle_id in json.dumps(item, ensure_ascii=False):
                return _app_name(item)
        return None
    return "" if bundle_id in text else None


def uninstall(backend: Backend, bundle_id: str, udid: str | None = None, log=print) -> None:
    """按 bundle id 卸载设备上的 App。"""
    log(f"卸载旧的    : {bundle_id}\n")
    if backend.name == "pymobiledevice3":
        if _api_enabled():
            try:
                import asyncio

                from pymobiledevice3.services.installation_proxy import InstallationProxyService

                async def run():
                    service = InstallationProxyService(lockdown=await _api_lockdown(udid))
                    await service.uninstall(bundle_id)

                asyncio.run(run())
                return
            except Exception as exc:      # API 失败了再用命令行试一次，别直接放弃
                log(f"  提示: API 卸载失败（{exc}），改用命令行\n")
        result = _run(_pmd3_with_udid(backend, udid, ["apps", "uninstall", bundle_id]),
                      timeout=LIST_TIMEOUT)
    else:
        cmd = [*backend.argv] + (["-u", udid] if udid else []) + ["-U", bundle_id]
        result = _run(cmd, timeout=LIST_TIMEOUT)
    if result.returncode != 0:
        raise DeviceError("卸载失败：\n" + (friendly_error(_text(result).strip()) or ""))


def _confirm_default(message: str) -> bool | None:
    """命令行下的默认询问：y=卸载重装，n=不卸载直接装，q=取消。

    非交互环境（脚本 / 管道）不问，按「不卸载直接装」走，保持老行为。
    """
    if not sys.stdin.isatty():
        print(f"{message}；非交互环境按「不卸载直接装」继续（要自动卸载请加 --reinstall）")
        return False
    answer = input(f"{message}？[y=卸载重装 / n=不卸载直接装 / q=取消] ").strip().lower()
    if answer.startswith("y"):
        return True
    if answer.startswith("q"):
        return None
    return False


# --------------------------------------------------------------------------- #
# 安装
# --------------------------------------------------------------------------- #
# 活体指示用的转圈字符：百分比可能几十秒不动（设备端在解压/校验），
# 靠这个转圈 + 计时证明安装进程还活着，别让人误以为卡死。
_SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"


class _Progress:
    """把「百分比 + IPA 大小 + 时间」换算成进度行；工具不报百分比时给心跳。

    工具只报百分比、不报字节数，所以速度用「IPA 大小 × 百分比增量 ÷ 时间」估。
    """

    def __init__(self, total: int, log) -> None:
        self.total = total
        self.log = log
        now = time.monotonic()
        self.started = self.last_report = self.last_beat = now
        self.last_done = 0
        self.last_percent = -1
        self.seen = False
        self.last_update = now     # 最后一次真正收到进度的时间（卡死检测用）
        self._spin = 0             # 活体转圈计数，证明进程没卡死

    def update(self, percent: int, *args) -> None:
        # pymobiledevice3 以 handler(percent_complete, *args) 形式调用，即使没额外
        # 参数也会多传一个空元组，所以这里吃掉 *args，避免「takes 2 but 3 given」。
        now = time.monotonic()
        self.seen = True
        self.last_update = now
        if percent <= 0:
            return              # 「0% / 0 B」这行没信息量
        if percent == self.last_percent and now - self.last_report < 1.0:
            return              # 同一百分比 1 秒内不重复刷
        done = int(self.total * percent / 100)
        # 第一条真实百分比：之前是上传期（installation_proxy 没回报任何拷贝进度），
        # 用「上传 + 安装起始」整段去估速度会严重偏低，所以只打基线、不估速度。
        first = self.last_percent < 0
        span = now - self.last_report
        # 跨度太小（installation_proxy 常把 5%、15% 几乎同时回报）算出的速度没意义，
        # 这种只显示百分比与大小；跨度足够才估速度。
        speed = (done - self.last_done) / span if (not first and span >= 0.5 and done > self.last_done) else 0.0
        line = f"进度        : {percent}%  {_human(done)}/{_human(self.total)}"
        if speed >= 1:
            line += f"  {_human(speed)}/s"
            eta = (self.total - done) / speed
            if 0 < eta < 3600:
                line += f"  剩约 {eta:.0f}s"
        self.log(line + "\n")
        self.last_percent, self.last_report, self.last_done = percent, now, done
        self.last_beat = now    # 刚有真实进度：心跳计时重置，别紧接着又刷一行「等待」

    def tick(self) -> None:
        """空闲时定期调用：百分比可能几十秒不动，靠转圈 + 计时证明还活着，别让人以为死了。"""
        now = time.monotonic()
        if now - self.last_beat < 3.0:
            return
        self.last_beat = now
        elapsed = now - self.started
        glyph = _SPINNER[self._spin % len(_SPINNER)]
        self._spin += 1
        if self.seen:
            # 安装阶段：百分比是设备端零星回报的，两次之间可能要等几十秒（设备在
            # 校验 / 解压）。转圈 + 计时一直动，就不会误以为卡死。
            last = max(self.last_percent, 0)
            self.log(f"{glyph} 传输中    : 已用 {elapsed:.0f}s"
                     f"（设备端解压/校验中）\n")
        else:
            # AFC 上传阶段：pymobiledevice3 这时不回任何百分比（百分比只在设备端
            # 安装阶段才有），所以不是「工具没报」，而是这阶段本来就没有进度可报。
            self.log(f"{glyph} 上传中    : 已用 {elapsed:.0f}s"
                     f"（包 {_human(self.total)}，正在发往设备）\n")

    def stall_exceeded(self, limit: float) -> bool:
        """报过进度后，超过 limit 秒没新进度就视为卡死。上传阶段（还没 seen）不算。"""
        return self.seen and (time.monotonic() - self.last_update) > limit

    def finish(self, ok: bool) -> None:
        elapsed = time.monotonic() - self.started
        if ok and elapsed >= 1.0:
            self.log(f"传输完成    : {_human(self.total)} / {elapsed:.1f}s"
                     f"（平均 {_human(self.total / elapsed)}/s）\n")


class _ApiUnavailable(Exception):
    """Python API 这条路走不通（版本不匹配之类），应该退回命令行。"""


def _api_enabled() -> bool:
    """能不能用 pymobiledevice3 的 Python API 装（能拿到真实进度）。"""
    if os.environ.get(API_ENV, "").strip() not in ("", "0", "false", "no"):
        return False
    try:
        import importlib.util

        return importlib.util.find_spec("pymobiledevice3") is not None
    except Exception:
        return False


def _quiet_lib_logs() -> dict[str, int]:
    """把 pymobiledevice3* 这些 logger 的级别临时压到 WARNING，返回原级别以便还原。

    库自己会 INFO「15% Complete」（带 ANSI 颜色码），和我们算出来的进度行是同一件事，
    落到日志里既重复又乱码。子 logger 可能自带级别，所以逐个压。
    """
    import logging

    saved: dict[str, int] = {}
    for name, obj in list(logging.Logger.manager.loggerDict.items()):
        if name.startswith("pymobiledevice3") and isinstance(obj, logging.Logger):
            saved[name] = obj.level
            obj.setLevel(logging.WARNING)
    return saved


def _restore_lib_logs(saved: dict[str, int]) -> None:
    import logging

    for name, level in saved.items():
        logging.getLogger(name).setLevel(level)


def _install_via_api(ipa: str, udid: str | None, developer: bool, log, total: int) -> None:
    """用 pymobiledevice3 的 Python API 装。

    命令行那条路（`apps install`）**不接进度回调**，所以只有心跳；
    API 的 `handler` 能拿到真实的 PercentComplete，这里自己接上。
    """
    import asyncio

    try:
        from pymobiledevice3.services.installation_proxy import InstallationProxyService
    except ImportError as exc:
        raise _ApiUnavailable(f"导入 pymobiledevice3 失败（{exc}）")

    progress = _Progress(total, log)
    log(f"进度来源    : pymobiledevice3 Python API\n")

    async def run() -> None:
        service = InstallationProxyService(lockdown=await _api_lockdown(udid))
        try:
            install_task = asyncio.ensure_future(
                service.install_from_local(ipa, handler=progress.update, developer=developer))
        except TypeError as exc:
            raise _ApiUnavailable(f"install_from_local 参数不匹配（{exc}）")
        try:
            # 看门狗：边等安装边定期心跳；上传阶段（还没 seen）不算卡死，
            # 一旦报过进度后长时间没新进度，或整体超时，就主动取消并报错。
            while not install_task.done():
                await asyncio.sleep(5)
                if install_task.done():      # 睡醒时发现装完了，直接退出，别再误判卡死
                    break
                if time.monotonic() - progress.started > INSTALL_TIMEOUT:
                    install_task.cancel()
                    raise DeviceError(f"安装超时（{INSTALL_TIMEOUT / 60:.0f} 分钟），已中断")
                if progress.stall_exceeded(INSTALL_STALL):
                    install_task.cancel()
                    raise DeviceError(
                        f"安装疑似卡住（超过 {INSTALL_STALL / 60:.0f} 分钟没有新进度），已中断")
                progress.tick()
            await install_task
        except asyncio.CancelledError:
            raise DeviceError("安装被中断（卡住或超时）")

    saved_levels = _quiet_lib_logs()
    try:
        try:
            asyncio.run(run())
        except (_ApiUnavailable, DeviceError):
            raise
        except Exception as exc:      # 安装本身失败：原样带出来，别退回命令行重装一遍
            progress.finish(False)
            raise DeviceError("安装失败：\n" + (friendly_error(str(exc)) or str(exc)))
    finally:
        _restore_lib_logs(saved_levels)
    progress.finish(True)


def _run_streaming(argv: list[str], log, total: int) -> tuple[int, str]:
    """跑安装命令，边跑边把进度转出来。

    进度来自工具自己报的百分比（`45%` 或 installation_proxy 的 `PercentComplete`），
    工具要是不报（pymobiledevice3 的命令行就不报）就退回心跳提示。
    """
    env = dict(os.environ)
    tool_name = os.path.basename(argv[0]).lower()
    if "-m" in argv or "python" in tool_name or "pymobiledevice3" in tool_name:
        # python 系工具往管道里写会攒缓冲，不设这个进度要等跑完才一次性出现
        env["PYTHONUNBUFFERED"] = "1"
    try:
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    except FileNotFoundError:
        raise DeviceError(f"找不到可执行文件：{argv[0]}\n{backend_report()}")
    except OSError as exc:
        raise DeviceError(f"启动失败：{exc}")

    eof = object()
    lines: "queue.Queue[object]" = queue.Queue()

    def reader() -> None:
        assert proc.stdout is not None
        for raw in proc.stdout:
            lines.put(raw.decode("utf-8", "replace").rstrip("\r\n"))
        lines.put(eof)

    threading.Thread(target=reader, daemon=True).start()

    collected: list[str] = []
    progress = _Progress(total, log)
    try:
        while True:
            try:
                item = lines.get(timeout=1.0)
            except queue.Empty:
                if time.monotonic() - progress.started > INSTALL_TIMEOUT:
                    proc.kill()
                    raise DeviceError(f"安装超时（{INSTALL_TIMEOUT / 60:.0f} 分钟），已中断")
                progress.tick()
                continue
            if item is eof:
                break
            text = _clean(str(item))
            collected.append(text)
            log(text + "\n")
            percent = _parse_percent(text)
            if percent is not None:
                progress.update(percent)
    finally:
        try:
            if proc.stdout:
                proc.stdout.close()
        except OSError:
            pass
    code = proc.wait()
    progress.finish(code == 0)
    return code, "\n".join(collected)


def _install_attempts(backend: Backend, ipa: str, udid: str | None,
                      developer: bool, position: str = "sub") -> list[list[str]]:
    """不同版本的参数位置不一样，给出依次尝试的命令（第一个是探测出来的）。"""
    if backend.name == "ideviceinstaller":
        cmd = [*backend.argv]
        if udid:
            cmd += ["-u", udid]
        cmd += ["-i", ipa]
        return [cmd]
    tail = ["apps", "install", *(["--developer"] if developer else [])]
    if not udid:
        return [[*backend.argv, *tail, ipa]]
    top_form = [*backend.argv, "--udid", udid, *tail, ipa]
    sub_form = [*backend.argv, *tail, "--udid", udid, ipa]
    return [top_form, sub_form] if position == "top" else [sub_form, top_form]


def _pmd3_udid_position(backend: Backend) -> str:
    """`--udid` 该放哪：新版把它注入在子命令上（放后面），老版本是顶层参数（放前面）。

    看顶层 `--help` 里有没有 `--udid` 就能判断，结果按工具路径缓存——
    否则每次安装都会先白跑一次失败的尝试（日志里就会出现两行一样的「正在安装」）。
    """
    key = " ".join(backend.argv)
    cached = _PMD3_UDID_POSITION.get(key)
    if cached:
        return cached
    position = "sub"
    try:
        if "--udid" in _text(_run([*backend.argv, "--help"], timeout=30)):
            position = "top"
    except DeviceError:
        pass
    _PMD3_UDID_POSITION[key] = position
    return position


def _handle_existing(backend: Backend, ipa: str, udid: str | None, force: bool,
                     confirm, log) -> None:
    """设备上已有同一个 bundle id 时：卸载重装 / 不卸载直接装 / 取消。

    提示里用的是**设备上那个 App 的名字**（用户看到的才是它），读不到才退回包里的名字。
    """
    bundle_id, ipa_name = ipa_identity(ipa)
    if not bundle_id:
        return                          # 读不出 bundle id 就不猜，按直接安装走
    try:
        installed = find_installed(backend, bundle_id, udid)
    except DeviceError as exc:
        log(f"提示        : 查设备上已装的应用失败（{exc}），按直接安装继续\n")
        return
    if installed is None:
        return

    shown = installed or ipa_name or bundle_id
    message = f"设备上已经装了「{shown}」（Bundle ID {bundle_id}）"
    if force:
        log(f"提示        : {message}，--reinstall：先卸载再装\n")
        uninstall(backend, bundle_id, udid, log)
        return

    answer = confirm(message)
    if answer is None:
        raise InstallCancelled(message)
    if answer:
        uninstall(backend, bundle_id, udid, log)
    else:
        log(f"提示        : {message}，选择不卸载直接装（同名 App 可能被系统拒绝）\n")


def install(ipa: str, udid: str | None = None, backend: Backend | None = None,
            prefer: str = "auto", tool: str | None = None, developer: bool = False,
            force: bool = False, check_existing: bool = True,
            confirm: Optional[Callable[[str], Optional[bool]]] = None,
            log=print) -> str:
    """把 IPA 装到设备上，返回实际用的设备 UDID（没指定时由工具挑）。

    设备上已经装了同一个 bundle id 时：先问一句要不要卸载重装
    （`force=True` 或 `--reinstall` 就直接卸；`confirm` 返回 None 表示用户取消）。
    """
    ipa = os.path.abspath(ipa)
    if not os.path.isfile(ipa):
        raise DeviceError(f"找不到要安装的文件：{ipa}")
    backend = backend or resolve_backend(prefer, tool)
    log(f"安装后端    : {backend.name}（{backend.detail}）")

    if check_existing:
        _handle_existing(backend, ipa, udid, force, confirm or _confirm_hook or _confirm_default, log)

    position = _pmd3_udid_position(backend) if backend.name == "pymobiledevice3" else "sub"
    attempts = _install_attempts(backend, ipa, udid, developer, position)
    total = os.path.getsize(ipa)

    # 优先走 Python API：命令行那条路不接进度回调，看不到百分比与速度
    if backend.name == "pymobiledevice3" and _api_enabled():
        try:
            _install_via_api(ipa, udid, developer, log, total)
            return udid or ""
        except _ApiUnavailable as exc:
            log(f"  提示: 走不了 Python API（{exc}），改用命令行装\n")

    code = 1
    text = ""
    for index, argv in enumerate(attempts):
        if index:
            log("  这个版本的参数位置不一样，换一种写法再试一次…")
        log(f"正在安装    : {os.path.basename(ipa)}（{_human(total)}）"
            f"{' -> …' + udid[-6:] if udid else '（由工具选设备）'}")
        code, text = _run_streaming(argv, log, total)
        if code == 0:
            return udid or ""
        # 只有「写法不对」才换下一种参数顺序；设备/签名问题换写法也没用
        if index + 1 < len(attempts) and _usage_error(text):
            continue
        break
    raise DeviceError("安装失败：\n" + (friendly_error(text.strip()) or text.strip()))


def friendly_error(text: str) -> str:
    """把 installation_proxy 的原始报错翻译成「下一步做什么」。"""
    low = text.lower()
    hints: list[str] = []
    if "applicationverificationfailed" in low or "invalid signature" in low or "0xe8008015" in low:
        hints.append("签名和这台设备对不上：确认 IPA 用的是本机证书签的，"
                     "且描述文件包含这台设备的 UDID（或用通配符描述文件）")
    if "0xe8008016" in low or "provision" in low and ("expir" in low or "invalid" in low):
        hints.append("描述文件有问题：可能已过期、或 bundle id 与描述文件不匹配")
    if "0xe8008018" in low or "already installed" in low or "same version" in low:
        hints.append("设备上已有同一 bundle id 的应用：先在设备上删掉旧版，或改 bundle id 再装")
    if "lock" in low:
        hints.append("设备在锁屏：解锁后重试")
    if "trust" in low or "pair" in low or "not paired" in low:
        hints.append("设备没信任这台电脑：解锁后在弹窗点「信任」，再重试")
    if "developer mode" in low or "developer_mode" in low:
        hints.append("设备没开开发者模式：「设置 → 隐私与安全性 → 开发者模式」打开并重启")
    if "no device" in low or "not connected" in low or "usbmux" in low:
        hints.append("认不到设备：检查数据线 / 信任 / Apple usbmuxd 驱动（见 --help 末尾的排查）")
    if "0xe800007f" in low or "timeout" in low:
        hints.append("传输超时：换 USB 口（优先直连）、别用劣质线，重试一次")
    if not hints:
        return text
    return text + "\n" + "\n".join(f"提示: {h}" for h in hints)


def ipa_signature_note(ipa: str) -> str:
    """看一眼包里有没有签名目录，给个提示（不是硬性判断）。"""
    try:
        with zipfile.ZipFile(ipa) as zf:
            names = zf.namelist()
    except (OSError, zipfile.BadZipFile) as exc:
        return f"读不了包内结构（{exc}），仍会尝试安装"
    apps = sorted({n.split("/", 2)[1] for n in names
                   if n.startswith("Payload/") and n.count("/") >= 2})
    if not apps:
        return "包里没看到 .app，这可能不是 IPA"
    signed = [a for a in apps if any(n.startswith(f"Payload/{a}/_CodeSignature/") for n in names)]
    if not signed:
        return "没看到 _CodeSignature（像是未签名/只重打包的包），装到真机上通常会被拒"
    return ""
