"""ipatool 的图形界面（tkinter，纯标准库）。

启动（在项目根目录执行，三种都行）：
    python -m ipatool gui      # 推荐
    python -m ipatool.gui
    python ipatool/gui.py

界面本身不重复实现任何业务逻辑：它只把控件上的值拼成一份 argv，
再调用 cli.main()。因此图形界面与命令行的行为、提示、退出码完全一致。
耗时任务跑在后台线程里，print 输出通过队列实时回传到日志区。
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import queue
import sys
import threading
import traceback
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

if __package__ in (None, ""):  # 直接运行本文件：python ipatool/gui.py
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from ipatool import cli as cli_mod
    from ipatool import signer
else:
    from . import cli as cli_mod
    from . import signer

OPT_DEFAULT = "(默认)"
PASSWORD_MASK = "********"
APP_TITLE = "ipatool · IPA 注入与重签名"
CAPTURE_TASKS = ("info", "certs")


# --------------------------------------------------------------------------- #
# 小工具
# --------------------------------------------------------------------------- #
def _opt(var: tk.StringVar) -> str | None:
    """控件里的“未填写 / (默认)”一律视为不传该参数。"""
    text = var.get().strip()
    return None if text in ("", OPT_DEFAULT) else text


def _add(argv: list[str], flag: str, value) -> None:
    """值非空时才追加 `flag value`。"""
    if value is None:
        return
    text = str(value).strip()
    if text:
        argv += [flag, text]


def _flag(argv: list[str], flag: str, enabled: bool) -> None:
    if enabled:
        argv.append(flag)


def _txt(value) -> str:
    """None 显示成空串，避免界面上出现 "None"。"""
    return "" if value is None else str(value)


def _format_argv(argv: list[str]) -> str:
    """拼出可读的命令行，证书密码打码。"""
    parts: list[str] = []
    hide_next = False
    for item in argv:
        if hide_next:
            parts.append(PASSWORD_MASK)
            hide_next = False
            continue
        parts.append(f'"{item}"' if " " in item else item)
        if item == "--p12-password":
            hide_next = True
    return "python -m ipatool " + " ".join(parts)


class _Stream(io.TextIOBase):
    """把 print 的内容投递到界面线程的队列里。"""

    def __init__(self, q: "queue.Queue") -> None:
        self._q = q

    @property
    def encoding(self) -> str:
        return "utf-8"

    def write(self, s: str) -> int:  # type: ignore[override]
        if s:
            self._q.put(("log", s))
        return len(s)

    def flush(self) -> None:
        pass

    def isatty(self) -> bool:
        return False


def _enable_dpi_awareness() -> None:
    """Windows 高分屏下让字体不发虚。"""
    if sys.platform != "win32":
        return
    try:
        import ctypes

        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        pass


# --------------------------------------------------------------------------- #
# 主窗口
# --------------------------------------------------------------------------- #
class IpatoolGui:
    def __init__(self) -> None:
        self.root = tk.Tk()
        self.root.title(APP_TITLE)
        self.root.geometry("1000x860")
        self.root.minsize(900, 640)
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(1, weight=1)

        self.q: "queue.Queue[tuple[str, object]]" = queue.Queue()
        self.busy = False
        self.custom_dylibs: list[str] = []
        self.action_buttons: list[ttk.Button] = []

        self._make_vars()
        self._build_inputs()
        self._build_tabs()
        self._build_bottom()

        self.root.after(80, self._poll)

    # ------------------------------------------------------------------ #
    # 变量
    # ------------------------------------------------------------------ #
    def _make_vars(self) -> None:
        # 输入 / 输出
        self.v_input = tk.StringVar()
        self.v_output = tk.StringVar()
        self.v_inplace = tk.BooleanVar(value=False)

        # 修改
        self.v_bundle_id = tk.StringVar()
        self.v_name = tk.StringVar()
        self.v_bundle_name = tk.StringVar()
        self.v_no_localized = tk.BooleanVar(value=False)

        # 签名
        self.v_sign = tk.StringVar(value="auto")
        self.v_identity = tk.StringVar()
        self.v_p12 = tk.StringVar()
        self.v_p12_password = tk.StringVar()
        self.v_provision = tk.StringVar()
        self.v_entitlements = tk.StringVar()
        self.v_hardened = tk.BooleanVar(value=False)
        self.v_dry_run = tk.BooleanVar(value=False)
        self.v_verbose = tk.BooleanVar(value=False)

        # 画中画
        self.v_pip = tk.BooleanVar(value=False)
        self.v_pip_dylib = tk.StringVar()
        self.v_pip_video = tk.StringVar()
        self.v_pip_mode = tk.StringVar(value=OPT_DEFAULT)
        self.v_pip_start_on = tk.StringVar(value=OPT_DEFAULT)
        self.v_pip_frame_rate = tk.StringVar()
        self.v_pip_keep_foreground = tk.BooleanVar(value=False)
        self.v_pip_no_keep_alive = tk.BooleanVar(value=False)

        # 后台保活
        self.v_keep_alive = tk.BooleanVar(value=False)
        self.v_ka_dylib = tk.StringVar()
        self.v_ka_start_on = tk.StringVar(value=OPT_DEFAULT)
        self.v_ka_no_audio = tk.BooleanVar(value=False)
        self.v_ka_audio_file = tk.StringVar()
        self.v_ka_no_task_renew = tk.BooleanVar(value=False)
        self.v_ka_renew_lead_time = tk.StringVar()
        self.v_ka_location = tk.BooleanVar(value=False)
        self.v_ka_location_indicator = tk.BooleanVar(value=False)
        self.v_ka_fetch = tk.BooleanVar(value=False)
        self.v_ka_processing = tk.BooleanVar(value=False)
        self.v_ka_refresh_interval = tk.StringVar()

        # 文件导入导出
        self.v_files = tk.BooleanVar(value=False)
        self.v_files_dylib = tk.StringVar()
        self.v_files_root = tk.StringVar()
        self.v_files_import_dir = tk.StringVar()
        self.v_no_files_sharing = tk.BooleanVar(value=False)

        # 悬浮窗
        self.v_panel = tk.BooleanVar(value=False)
        self.v_no_panel = tk.BooleanVar(value=False)
        self.v_panel_dylib = tk.StringVar()
        self.v_panel_title = tk.StringVar()

        # 其它
        self.v_dylib_entry = tk.StringVar()
        self.v_background_mode = tk.StringVar()
        self.v_allow_arbitrary_loads = tk.BooleanVar(value=False)

        # 状态
        self.v_status = tk.StringVar(value="就绪")

    # ------------------------------------------------------------------ #
    # 顶部：输入 / 输出
    # ------------------------------------------------------------------ #
    def _build_inputs(self) -> None:
        box = ttk.LabelFrame(self.root, text="IPA 文件", padding=(10, 6))
        box.grid(row=0, column=0, sticky="ew", padx=10, pady=(10, 6))
        box.columnconfigure(1, weight=1)
        box.columnconfigure(4, weight=1)

        ttk.Label(box, text="输入").grid(row=0, column=0, sticky="w", padx=(0, 6))
        ttk.Entry(box, textvariable=self.v_input).grid(row=0, column=1, sticky="ew")
        ttk.Button(box, text="打开…", width=8, command=self._pick_input).grid(row=0, column=2, padx=6)

        ttk.Label(box, text="输出").grid(row=0, column=3, sticky="w", padx=(12, 6))
        self.ent_output = ttk.Entry(box, textvariable=self.v_output)
        self.ent_output.grid(row=0, column=4, sticky="ew")
        ttk.Button(box, text="另存为…", width=8, command=self._pick_output).grid(row=0, column=5, padx=6)

        hint = ttk.Label(
            box,
            text="输入可以是 .ipa，也可以是已解包且含 Payload 的目录；输出留空则按默认名字生成（覆盖原文件时忽略此项）。",
            foreground="#666666",
        )
        hint.grid(row=1, column=0, columnspan=6, sticky="w", pady=(6, 0))

        ttk.Checkbutton(
            box, text="直接覆盖输入文件（--in-place）", variable=self.v_inplace, command=self._sync_inplace,
        ).grid(row=2, column=0, columnspan=3, sticky="w", pady=(4, 0))

        self.msg_io = ttk.Label(box, text="", foreground="#b00020")
        self.msg_io.grid(row=2, column=3, columnspan=3, sticky="w")

    def _sync_inplace(self) -> None:
        self.ent_output.configure(state="disabled" if self.v_inplace.get() else "normal")

    def _pick_input(self) -> None:
        path = filedialog.askopenfilename(
            title="选择 IPA 或已解包目录（目录请用“选择目录”按钮）",
            filetypes=[("iOS 应用包", "*.ipa"), ("所有文件", "*.*")],
        )
        if not path:
            return
        self.v_input.set(path)
        self._load_info()

    def _pick_input_dir(self) -> None:
        path = filedialog.askdirectory(title="选择已解包的目录（内含 Payload）")
        if path:
            self.v_input.set(path)
            self._load_info()

    def _pick_output(self) -> None:
        current = self.v_output.get().strip()
        path = filedialog.asksaveasfilename(
            title="输出 IPA",
            defaultextension=".ipa",
            initialfile=os.path.basename(current) if current else "",
            filetypes=[("iOS 应用包", "*.ipa"), ("所有文件", "*.*")],
        )
        if path:
            self.v_output.set(path)

    # ------------------------------------------------------------------ #
    # 页签
    # ------------------------------------------------------------------ #
    def _build_tabs(self) -> None:
        self.nb = ttk.Notebook(self.root)
        self.nb.grid(row=1, column=0, sticky="nsew", padx=10)
        self._build_info_tab()
        self._build_modify_tab()
        self._build_inject_tab()
        self._build_sign_tab()

    # ---- 信息 --------------------------------------------------------- #
    def _build_info_tab(self) -> None:
        page = ttk.Frame(self.nb, padding=10)
        self.nb.add(page, text="  信息  ")
        page.columnconfigure(0, weight=1)
        page.rowconfigure(1, weight=1)
        page.rowconfigure(3, weight=1)

        bar = ttk.Frame(page)
        bar.grid(row=0, column=0, sticky="ew")
        ttk.Button(bar, text="读取信息", command=self._load_info).pack(side="left")
        ttk.Button(bar, text="选择目录…", command=self._pick_input_dir).pack(side="left", padx=6)
        ttk.Label(
            bar, text="  解析包内的 Bundle ID / 名称 / 内嵌 bundle / 已注入 dylib",
            foreground="#666666",
        ).pack(side="left")

        self.info_tree = ttk.Treeview(page, columns=("k", "v"), show="headings", height=9)
        self.info_tree.heading("k", text="属性")
        self.info_tree.heading("v", text="值")
        self.info_tree.column("k", width=140, stretch=False)
        self.info_tree.column("v", width=700)
        self.info_tree.grid(row=1, column=0, sticky="nsew", pady=(8, 8))

        ttk.Label(page, text="内嵌 bundle / 已注入 dylib").grid(row=2, column=0, sticky="w")
        detail_box = ttk.Frame(page)
        detail_box.grid(row=3, column=0, sticky="nsew", pady=(4, 0))
        detail_box.columnconfigure(0, weight=1)
        detail_box.rowconfigure(0, weight=1)
        self.info_detail = tk.Text(detail_box, height=8, wrap="none", state="disabled", font=("Consolas", 9))
        self.info_detail.grid(row=0, column=0, sticky="nsew")
        bar_y = ttk.Scrollbar(detail_box, orient="vertical", command=self.info_detail.yview)
        bar_y.grid(row=0, column=1, sticky="ns")
        self.info_detail.configure(yscrollcommand=bar_y.set)

    # ---- 修改 --------------------------------------------------------- #
    def _build_modify_tab(self) -> None:
        page = ttk.Frame(self.nb, padding=10)
        self.nb.add(page, text="  改 ID / 名称  ")
        page.columnconfigure(0, weight=1)

        box = self._group(page, "新的标识", 0)
        self._entry(box, 0, "Bundle Identifier", self.v_bundle_id, "如 com.company.newapp（留空表示不改）")
        self._entry(box, 1, "显示名称", self.v_name, "CFBundleDisplayName（桌面图标下的名字）")
        self._entry(box, 2, "CFBundleName", self.v_bundle_name, "留空则跟随上一条（与原 CFBundleName 一致时）")
        ttk.Checkbutton(
            box, text="不同步修改本地化名称（InfoPlist.strings / --no-localized）",
            variable=self.v_no_localized,
        ).grid(row=3, column=0, columnspan=3, sticky="w", pady=(6, 0))

        tips = self._group(page, "说明", 1)
        ttk.Label(
            tips,
            justify="left",
            foreground="#444444",
            text=(
                "· 内嵌的 Extension / WatchApp / Framework 的 Bundle ID 会按前缀联动修改，\n"
                "  plist 里引用旧 ID 的字符串也会被递归替换（WKAppBundleIdentifier、CFBundleURLName 等）。\n"
                "· 改完必须重新签名才能安装；签名信息在「签名」页配置。\n"
                "· 想先看看会改什么，勾上「只预览不写文件」再执行。"
            ),
        ).grid(row=0, column=0, columnspan=3, sticky="w")

    # ---- 注入 --------------------------------------------------------- #
    def _build_inject_tab(self) -> None:
        outer = ttk.Frame(self.nb, padding=10)
        self.nb.add(outer, text="  注入功能  ")
        outer.columnconfigure(0, weight=1)
        outer.rowconfigure(0, weight=1)

        canvas = tk.Canvas(outer, highlightthickness=0)
        canvas.grid(row=0, column=0, sticky="nsew")
        bar = ttk.Scrollbar(outer, orient="vertical", command=canvas.yview)
        bar.grid(row=0, column=1, sticky="ns")
        canvas.configure(yscrollcommand=bar.set)

        page = ttk.Frame(canvas)
        canvas.create_window((0, 0), window=page, anchor="nw")
        page.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))

        def on_wheel(event) -> None:
            canvas.yview_scroll(-1 if event.delta > 0 else 1, "units")

        canvas.bind("<MouseWheel>", on_wheel)
        page.bind("<MouseWheel>", on_wheel)

        page.columnconfigure(0, weight=1, uniform="col")
        page.columnconfigure(1, weight=1, uniform="col")

        self._build_pip_group(page).grid(row=0, column=0, sticky="new", padx=(0, 6), pady=(0, 8))
        self._build_files_group(page).grid(row=0, column=1, sticky="new", padx=(6, 0), pady=(0, 8))
        self._build_keepalive_group(page).grid(row=1, column=0, sticky="new", padx=(0, 6), pady=(0, 8))
        self._build_panel_group(page).grid(row=1, column=1, sticky="new", padx=(6, 0), pady=(0, 8))
        self._build_misc_group(page).grid(row=2, column=0, columnspan=2, sticky="new", pady=(0, 4))

    def _build_pip_group(self, parent) -> ttk.LabelFrame:
        box = ttk.LabelFrame(parent, text=" 画中画 ", padding=(10, 6))
        box.columnconfigure(0, weight=1)

        ttk.Checkbutton(
            box, text="注入画中画 tweak（切后台自动进入画中画，从而继续运行）",
            variable=self.v_pip,
        ).grid(row=0, column=0, columnspan=3, sticky="w")
        self._entry(box, 1, "tweak 路径", self.v_pip_dylib, "留空自动查找 tweak/build/（macOS 上会自动编译）", browse=self._pick_pip_dylib, width=30)
        self._entry(box, 2, "循环视频", self.v_pip_video, "mp4，不给则显示黑屏/镜像", browse=lambda: self._pick_file(self.v_pip_video, [("视频", "*.mp4"), ("所有文件", "*.*")]), width=30)
        self._combo(box, 3, "画面", self.v_pip_mode, ["black", "mirror"])
        self._combo(box, 4, "启动时机", self.v_pip_start_on, ["background", "resignActive", "launch"])
        self._entry(box, 5, "帧率", self.v_pip_frame_rate, "默认 10", width=12)
        ttk.Checkbutton(
            box, text="回到前台也保持画中画（--pip-keep-foreground）",
            variable=self.v_pip_keep_foreground,
        ).grid(row=6, column=0, columnspan=3, sticky="w", pady=(4, 0))
        ttk.Checkbutton(
            box, text="不播放静音音频保活（--pip-no-keep-alive）",
            variable=self.v_pip_no_keep_alive,
        ).grid(row=7, column=0, columnspan=3, sticky="w")
        return box

    def _build_keepalive_group(self, parent) -> ttk.LabelFrame:
        box = ttk.LabelFrame(parent, text=" 后台保活 ", padding=(10, 6))
        box.columnconfigure(0, weight=1)

        ttk.Checkbutton(
            box, text="注入后台保活 tweak（默认靠静音音频，最稳定）",
            variable=self.v_keep_alive,
        ).grid(row=0, column=0, columnspan=3, sticky="w")
        self._entry(box, 1, "tweak 路径", self.v_ka_dylib, "留空自动查找 tweak/build/", browse=self._pick_ka_dylib, width=30)
        self._combo(box, 2, "音频启动", self.v_ka_start_on, ["launch", "background"])
        self._entry(box, 3, "音频文件", self.v_ka_audio_file, "改用近乎无声的底噪（可选）", browse=lambda: self._pick_file(self.v_ka_audio_file), width=30)
        self._entry(box, 4, "续期提前量", self.v_ka_renew_lead_time, "秒，默认 10", width=12)
        self._entry(box, 5, "唤醒间隔", self.v_ka_refresh_interval, "秒，默认 900", width=12)

        ttk.Checkbutton(box, text="不播放静音音频（只靠后台任务续期，撑不久）", variable=self.v_ka_no_audio).grid(row=6, column=0, columnspan=3, sticky="w", pady=(4, 0))
        ttk.Checkbutton(box, text="不续期 beginBackgroundTask", variable=self.v_ka_no_task_renew).grid(row=7, column=0, columnspan=3, sticky="w")
        ttk.Checkbutton(box, text="后台定位保活（耗电、需授权、App Store 会拒）", variable=self.v_ka_location).grid(row=8, column=0, columnspan=3, sticky="w")
        ttk.Checkbutton(box, text="显示定位蓝条", variable=self.v_ka_location_indicator).grid(row=9, column=0, columnspan=3, sticky="w")
        ttk.Checkbutton(box, text="注册定时唤醒 BGAppRefreshTask（开启后需重启 App 生效）", variable=self.v_ka_fetch).grid(row=10, column=0, columnspan=3, sticky="w")
        ttk.Checkbutton(box, text="注册长任务 BGProcessingTask", variable=self.v_ka_processing).grid(row=11, column=0, columnspan=3, sticky="w")
        return box

    def _build_files_group(self, parent) -> ttk.LabelFrame:
        box = ttk.LabelFrame(parent, text=" 文件导入导出 ", padding=(10, 6))
        box.columnconfigure(0, weight=1)

        ttk.Checkbutton(
            box, text="注入文件桥（在悬浮面板里浏览沙盒 / 导出 / 导入）",
            variable=self.v_files,
        ).grid(row=0, column=0, columnspan=3, sticky="w")
        self._entry(box, 1, "tweak 路径", self.v_files_dylib, "留空自动查找 tweak/build/", browse=self._pick_files_dylib, width=30)
        self._entry(box, 2, "浏览根目录", self.v_files_root, "相对沙盒，留空 = 沙盒根", width=30)
        self._entry(box, 3, "导入到", self.v_files_import_dir, "相对沙盒，默认 Documents", width=30)
        ttk.Checkbutton(
            box, text="不打开 UIFileSharingEnabled（Documents 不出现在「文件」App）",
            variable=self.v_no_files_sharing,
        ).grid(row=4, column=0, columnspan=3, sticky="w", pady=(4, 0))
        ttk.Label(
            box, foreground="#666666", justify="left",
            text="导出时悬浮窗会自动躲开系统文件选择器；导入同名文件不覆盖，自动加 -2/-3 后缀。",
        ).grid(row=5, column=0, columnspan=3, sticky="w", pady=(6, 0))
        return box

    def _build_panel_group(self, parent) -> ttk.LabelFrame:
        box = ttk.LabelFrame(parent, text=" 应用内悬浮窗 ", padding=(10, 6))
        box.columnconfigure(0, weight=1)

        ttk.Checkbutton(
            box, text="强制注入悬浮窗（上面功能默认已带，用于单独只要面板）",
            variable=self.v_panel, command=lambda: self._sync_panel(True),
        ).grid(row=0, column=0, columnspan=3, sticky="w")
        ttk.Checkbutton(
            box, text="不要悬浮窗（--no-panel：只改配置，不加界面）",
            variable=self.v_no_panel, command=lambda: self._sync_panel(False),
        ).grid(row=1, column=0, columnspan=3, sticky="w")
        self._entry(box, 2, "tweak 路径", self.v_panel_dylib, "留空自动查找 tweak/build/", browse=self._pick_panel_dylib, width=30)
        self._entry(box, 3, "按钮文字", self.v_panel_title, "默认 IPAT", width=30)
        ttk.Label(
            box, foreground="#666666", justify="left",
            text="面板里的开关立即生效并记住；命令行参数只决定“用户还没在面板改过时”的默认值。",
        ).grid(row=4, column=0, columnspan=3, sticky="w", pady=(6, 0))
        return box

    def _build_misc_group(self, parent) -> ttk.LabelFrame:
        box = ttk.LabelFrame(parent, text=" 其它 ", padding=(10, 6))
        box.columnconfigure(0, weight=0)
        box.columnconfigure(1, weight=1)

        ttk.Label(box, text="自定义 dylib").grid(row=0, column=0, sticky="nw", padx=(0, 8))
        list_box = tk.Listbox(box, height=3, selectmode="extended", font=("Consolas", 9))
        list_box.grid(row=0, column=1, sticky="ew")
        self.list_dylibs = list_box
        btns = ttk.Frame(box)
        btns.grid(row=0, column=2, sticky="nw", padx=(8, 0))
        ttk.Button(btns, text="添加…", width=9, command=self._add_dylib).pack()
        ttk.Button(btns, text="移除", width=9, command=self._remove_dylib).pack(pady=4)

        ttk.Label(box, text="后台模式").grid(row=1, column=0, sticky="w", padx=(0, 8), pady=(8, 0))
        ttk.Entry(box, textvariable=self.v_background_mode).grid(row=1, column=1, sticky="ew", pady=(8, 0))
        ttk.Label(box, text="逗号分隔，追加到 UIBackgroundModes，如 fetch,processing", foreground="#666666").grid(
            row=1, column=2, sticky="w", padx=(8, 0), pady=(8, 0),
        )

        bottom = ttk.Frame(box)
        bottom.grid(row=2, column=0, columnspan=3, sticky="w", pady=(8, 0))
        ttk.Checkbutton(
            bottom, text="允许明文 HTTP（NSAllowsArbitraryLoads，热更服务器常用）",
            variable=self.v_allow_arbitrary_loads,
        ).pack(side="left")
        ttk.Button(bottom, text="查看已注入的 dylib", command=self._list_injected).pack(side="left", padx=10)
        return box

    # ---- 签名 --------------------------------------------------------- #
    def _build_sign_tab(self) -> None:
        page = ttk.Frame(self.nb, padding=10)
        self.nb.add(page, text="  签名  ")
        page.columnconfigure(0, weight=1)

        box = self._group(page, "签名方式（二选一，都不给则 ad-hoc 签名，真机装不上）", 0)
        ttk.Label(box, text="后端").grid(row=0, column=0, sticky="w", padx=(0, 8), pady=3)
        ttk.Combobox(
            box, textvariable=self.v_sign, values=list(signer.BACKENDS),
            state="readonly", width=14,
        ).grid(row=0, column=1, sticky="w", pady=3)
        ttk.Label(
            box, foreground="#666666",
            text="auto：macOS 用 codesign，否则用 zsign；none 只重打包不签名",
        ).grid(row=0, column=2, sticky="w", padx=(10, 0), pady=3)

        ttk.Label(box, text="ID 签名").grid(row=1, column=0, sticky="w", padx=(0, 8), pady=3)
        self.cb_identity = ttk.Combobox(box, textvariable=self.v_identity, values=[], width=46)
        self.cb_identity.grid(row=1, column=1, columnspan=2, sticky="ew", pady=3)
        ttk.Button(box, text="读取系统证书", command=self._load_certs).grid(row=1, column=3, sticky="w", padx=(10, 0), pady=3)

        self._entry(box, 2, "证书文件", self.v_p12, "p12 / pfx（证书签名）", browse=lambda: self._pick_file(self.v_p12, [("证书", "*.p12 *.pfx"), ("所有文件", "*.*")]))
        ttk.Label(box, text="证书密码").grid(row=3, column=0, sticky="w", padx=(0, 8), pady=3)
        ttk.Entry(box, textvariable=self.v_p12_password, show="*", width=30).grid(row=3, column=1, sticky="w", pady=3)
        ttk.Label(box, text="也可留空，用环境变量 IPATOOL_P12_PASSWORD", foreground="#666666").grid(
            row=3, column=2, columnspan=2, sticky="w", padx=(10, 0), pady=3,
        )

        self._entry(box, 4, "描述文件", self.v_provision, "embedded.mobileprovision，改过 Bundle ID 时必须匹配", browse=lambda: self._pick_file(self.v_provision, [("描述文件", "*.mobileprovision"), ("所有文件", "*.*")]))
        self._entry(box, 5, "Entitlements", self.v_entitlements, "entitlements.plist（可选）", browse=lambda: self._pick_file(self.v_entitlements, [("plist", "*.plist"), ("所有文件", "*.*")]))

        opt = self._group(page, "运行选项", 1)
        ttk.Checkbutton(opt, text="只预览不写文件（--dry-run）", variable=self.v_dry_run).grid(row=0, column=0, sticky="w")
        ttk.Checkbutton(opt, text="输出详细日志（-v）", variable=self.v_verbose).grid(row=1, column=0, sticky="w")
        ttk.Checkbutton(opt, text="codesign 启用 hardened runtime", variable=self.v_hardened).grid(row=2, column=0, sticky="w")

    # ------------------------------------------------------------------ #
    # 底部：日志 + 操作
    # ------------------------------------------------------------------ #
    def _build_bottom(self) -> None:
        area = ttk.Frame(self.root)
        area.grid(row=2, column=0, sticky="nsew", padx=10, pady=(6, 10))
        area.columnconfigure(0, weight=1)
        area.rowconfigure(1, weight=1)

        bar = ttk.Frame(area)
        bar.grid(row=0, column=0, sticky="ew")
        b_info = ttk.Button(bar, text="读取信息", command=self._load_info)
        b_dry = ttk.Button(bar, text="预览（dry-run）", command=lambda: self._run_current(dry_run=True))
        b_go = ttk.Button(bar, text="开始执行", command=lambda: self._run_current(dry_run=False))
        for btn in (b_info, b_dry, b_go):
            btn.pack(side="left", padx=(0, 6))
        self.action_buttons = [b_info, b_dry, b_go]
        ttk.Button(bar, text="清空日志", command=lambda: self._set_text(self.log, "")).pack(side="left")
        ttk.Label(bar, textvariable=self.v_status, foreground="#00695c").pack(side="right")

        log_box = ttk.LabelFrame(area, text=" 输出 ", padding=(6, 4))
        log_box.grid(row=1, column=0, sticky="nsew", pady=(6, 0))
        log_box.columnconfigure(0, weight=1)
        log_box.rowconfigure(0, weight=1)
        self.log = tk.Text(log_box, height=12, wrap="word", state="disabled", font=("Consolas", 9))
        self.log.grid(row=0, column=0, sticky="nsew")
        bar_y = ttk.Scrollbar(log_box, orient="vertical", command=self.log.yview)
        bar_y.grid(row=0, column=1, sticky="ns")
        self.log.configure(yscrollcommand=bar_y.set)
        self.log.tag_configure("err", foreground="#b00020")

    # ------------------------------------------------------------------ #
    # 布局小助手
    # ------------------------------------------------------------------ #
    def _group(self, parent, title: str, row: int) -> ttk.LabelFrame:
        box = ttk.LabelFrame(parent, text=f" {title} ", padding=(10, 6))
        box.grid(row=row, column=0, sticky="new", pady=(0, 8))
        box.columnconfigure(1, weight=1)
        parent.columnconfigure(0, weight=1)
        return box

    def _entry(self, box, row, label, var, hint=None, browse=None, width=36):
        ttk.Label(box, text=label).grid(row=row, column=0, sticky="w", padx=(0, 8), pady=3)
        ttk.Entry(box, textvariable=var, width=width).grid(row=row, column=1, sticky="ew", pady=3)
        box.columnconfigure(1, weight=1)
        col = 2
        if browse:
            ttk.Button(box, text="浏览…", width=8, command=browse).grid(row=row, column=col, padx=(6, 0), pady=3)
            col += 1
        if hint:
            ttk.Label(box, text=hint, foreground="#666666").grid(row=row, column=col, sticky="w", padx=(8, 0), pady=3)

    def _combo(self, box, row, label, var, values):
        ttk.Label(box, text=label).grid(row=row, column=0, sticky="w", padx=(0, 8), pady=3)
        ttk.Combobox(box, textvariable=var, values=[OPT_DEFAULT] + values, state="readonly", width=16).grid(
            row=row, column=1, sticky="w", pady=3,
        )

    def _pick_file(self, var: tk.StringVar, filetypes=None) -> None:
        path = filedialog.askopenfilename(title="选择文件", filetypes=filetypes or [("所有文件", "*.*")])
        if path:
            var.set(path)

    def _pick_pip_dylib(self) -> None:
        self._pick_file(self.v_pip_dylib, [("动态库", "*.dylib"), ("所有文件", "*.*")])

    def _pick_ka_dylib(self) -> None:
        self._pick_file(self.v_ka_dylib, [("动态库", "*.dylib"), ("所有文件", "*.*")])

    def _pick_files_dylib(self) -> None:
        self._pick_file(self.v_files_dylib, [("动态库", "*.dylib"), ("所有文件", "*.*")])

    def _pick_panel_dylib(self) -> None:
        self._pick_file(self.v_panel_dylib, [("动态库", "*.dylib"), ("所有文件", "*.*")])

    def _sync_panel(self, panel_clicked: bool) -> None:
        # --panel 与 --no-panel 互斥，后点亮的那个赢
        if panel_clicked:
            self.v_no_panel.set(False)
        else:
            self.v_panel.set(False)

    def _add_dylib(self) -> None:
        paths = filedialog.askopenfilenames(title="选择要注入的 dylib", filetypes=[("动态库", "*.dylib"), ("所有文件", "*.*")])
        for path in paths or ():
            if path not in self.custom_dylibs:
                self.custom_dylibs.append(path)
                self.list_dylibs.insert("end", path)

    def _remove_dylib(self) -> None:
        for index in sorted(self.list_dylibs.curselection(), reverse=True):
            self.list_dylibs.delete(index)
            del self.custom_dylibs[index]

    # ------------------------------------------------------------------ #
    # 日志
    # ------------------------------------------------------------------ #
    def _append(self, text: str, tag: str | None = None) -> None:
        if not text:
            return
        self.log.configure(state="normal")
        self.log.insert("end", text, tag or ())
        self.log.see("end")
        self.log.configure(state="disabled")

    def _set_text(self, widget: tk.Text, content: str) -> None:
        widget.configure(state="normal")
        widget.delete("1.0", "end")
        if content:
            widget.insert("1.0", content)
        widget.configure(state="disabled")

    # ------------------------------------------------------------------ #
    # 任务调度
    # ------------------------------------------------------------------ #
    def _poll(self) -> None:
        try:
            while True:
                kind, payload = self.q.get_nowait()
                if kind == "log":
                    self._append(str(payload))
                elif kind == "info" or kind == "certs":
                    self._render(kind, str(payload))
                elif kind == "done":
                    task, code = payload  # type: ignore[misc]
                    self._finish(str(task), int(code))
        except queue.Empty:
            pass
        except Exception:
            self._append(traceback.format_exc(), "err")
        self.root.after(80, self._poll)

    def _start(self, argv: list[str], task: str) -> None:
        if self.busy:
            messagebox.showinfo("请稍候", "已有任务在运行，请等它结束。")
            return
        self.busy = True
        for btn in self.action_buttons:
            btn.configure(state="disabled")
        self.v_status.set("运行中…")
        self._append(f"\n$ {_format_argv(argv)}\n")
        threading.Thread(target=self._work, args=(argv, task), daemon=True).start()

    def _work(self, argv: list[str], task: str) -> None:
        code, text = 0, ""
        try:
            if task in CAPTURE_TASKS:
                buf = io.StringIO()
                with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
                    code = cli_mod.main(argv)
                text = buf.getvalue()
            else:
                stream = _Stream(self.q)
                with contextlib.redirect_stdout(stream), contextlib.redirect_stderr(stream):
                    code = cli_mod.main(argv)
        except SystemExit as exc:  # cli 里用 SystemExit 报输入错误
            code = exc.code if isinstance(exc.code, int) else (1 if exc.code else 0)
        except BaseException:
            code = 1
            text += "\n" + traceback.format_exc()
        if text:
            self.q.put((task, text))
        self.q.put(("done", (task, code)))

    def _finish(self, task: str, code: int) -> None:
        self.busy = False
        for btn in self.action_buttons:
            btn.configure(state="normal")
        if code == 0:
            self.v_status.set("完成")
            if task in ("inject", "modify"):
                messagebox.showinfo("完成", "处理完成，输出文件已生成。")
            return
        self.v_status.set(f"失败（退出码 {code}）")
        self._append(f"任务失败，退出码 {code}\n", "err")
        if task not in CAPTURE_TASKS:
            messagebox.showerror("执行失败", f"任务未能完成，退出码 {code}。\n详情见下方日志。")

    def _render(self, kind: str, text: str) -> None:
        try:
            data = json.loads(text)
        except Exception:
            self._append(text)
            return
        if kind == "info":
            self._render_info(data)
        else:
            self._render_certs(data)

    def _render_info(self, data: dict) -> None:
        for item in self.info_tree.get_children():
            self.info_tree.delete(item)
        rows = [
            ("文件", _txt(data.get("file"))),
            ("主程序", _txt(data.get("app_path"))),
            ("可执行文件", _txt(data.get("executable"))),
            ("Bundle ID", _txt(data.get("bundle_id"))),
            ("显示名称", _txt(data.get("display_name"))),
            ("CFBundleName", _txt(data.get("bundle_name"))),
            ("版本", f'{_txt(data.get("version"))} (build {_txt(data.get("build"))})'),
            ("最低系统", _txt(data.get("min_os"))),
            ("后台模式", ", ".join(data.get("background_modes") or [])),
        ]
        for key, value in rows:
            self.info_tree.insert("", "end", values=(key, value))

        lines: list[str] = []
        nested = data.get("nested") or []
        lines.append(f"内嵌 bundle（{len(nested)}）")
        for item in nested:
            lines.append(
                f"  · {_txt(item.get('path'))}  [{_txt(item.get('kind'))}]  "
                f"{_txt(item.get('bundle_id'))}  {_txt(item.get('name'))}"
            )
        injected = data.get("injected") or []
        lines.append("")
        lines.append(f"已注入 dylib（{len(injected)}）")
        lines.extend(f"  · {d}" for d in injected)
        if not injected:
            lines.append("  （无）")
        self._set_text(self.info_detail, "\n".join(lines))
        self._append(
            f"\n已读取：{_txt(data.get('bundle_id'))} / {_txt(data.get('display_name'))}，"
            f"内嵌 bundle {len(nested)} 个，已注入 dylib {len(injected)} 个"
            f"（读的是「输入」框里的包，不是产物）\n"
        )

        # 顺手把当前值填进「改 ID / 名称」页，少打一次字
        if data.get("bundle_id") and not self.v_bundle_id.get().strip():
            self.v_bundle_id.set(data["bundle_id"])
        if data.get("display_name") and not self.v_name.get().strip():
            self.v_name.set(data["display_name"])

    def _render_certs(self, data: dict) -> None:
        identities = data.get("identities") or []
        values = [f"{i.get('name', '')} | {i.get('id', '')}".strip(" |") for i in identities]
        self.cb_identity.configure(values=values)
        self._append(f"证书来源: {data.get('source', '')}\n")
        if not values:
            self._append("未找到可用身份。可改用证书文件（p12），或在 macOS 上把证书装进钥匙串。\n")
        for value in values:
            self._append(f"  · {value}\n")

    # ------------------------------------------------------------------ #
    # 组装 argv
    # ------------------------------------------------------------------ #
    def _common_args(self) -> list[str]:
        argv: list[str] = []
        if self.v_inplace.get():
            argv.append("--in-place")
        else:
            _add(argv, "-o", self.v_output.get())
        _add(argv, "--sign", self.v_sign.get())
        _add(argv, "--identity", self.v_identity.get())
        _add(argv, "--p12", self.v_p12.get())
        _add(argv, "--p12-password", self.v_p12_password.get())
        _add(argv, "--provision", self.v_provision.get())
        _add(argv, "--entitlements", self.v_entitlements.get())
        _flag(argv, "--hardened-runtime", self.v_hardened.get())
        _flag(argv, "--dry-run", self.v_dry_run.get())
        _flag(argv, "-v", self.v_verbose.get())
        return argv

    def _info_argv(self) -> list[str]:
        return ["info", self.v_input.get().strip(), "--json"]

    def _modify_argv(self) -> list[str] | None:
        src = self.v_input.get().strip()
        if not src:
            messagebox.showwarning("缺少输入", "请先选择要处理的 IPA 文件或已解包目录。")
            return None
        if not self.v_bundle_id.get().strip() and not self.v_name.get().strip():
            messagebox.showwarning("缺少参数", "至少要填写「Bundle Identifier」或「显示名称」中的一项。")
            return None
        argv = ["modify", src]
        _add(argv, "-i", self.v_bundle_id.get())
        _add(argv, "-n", self.v_name.get())
        _add(argv, "--bundle-name", self.v_bundle_name.get())
        _flag(argv, "--no-localized", self.v_no_localized.get())
        return argv + self._common_args()

    def _inject_argv(self) -> list[str] | None:
        src = self.v_input.get().strip()
        if not src:
            messagebox.showwarning("缺少输入", "请先选择要处理的 IPA 文件或已解包目录。")
            return None
        argv = ["inject", src]

        if self.v_pip.get():
            argv.append("--pip")
            _add(argv, "--pip-dylib", self.v_pip_dylib.get())
            _add(argv, "--pip-video", self.v_pip_video.get())
            _add(argv, "--pip-mode", _opt(self.v_pip_mode))
            _add(argv, "--pip-start-on", _opt(self.v_pip_start_on))
            _add(argv, "--pip-frame-rate", self.v_pip_frame_rate.get())
            _flag(argv, "--pip-keep-foreground", self.v_pip_keep_foreground.get())
            _flag(argv, "--pip-no-keep-alive", self.v_pip_no_keep_alive.get())

        if self.v_keep_alive.get():
            argv.append("--keep-alive")
            _add(argv, "--keep-alive-dylib", self.v_ka_dylib.get())
            _add(argv, "--keep-alive-start-on", _opt(self.v_ka_start_on))
            _add(argv, "--keep-alive-audio-file", self.v_ka_audio_file.get())
            _add(argv, "--keep-alive-renew-lead-time", self.v_ka_renew_lead_time.get())
            _add(argv, "--keep-alive-refresh-interval", self.v_ka_refresh_interval.get())
            _flag(argv, "--keep-alive-no-audio", self.v_ka_no_audio.get())
            _flag(argv, "--keep-alive-no-task-renew", self.v_ka_no_task_renew.get())
            _flag(argv, "--keep-alive-location", self.v_ka_location.get())
            _flag(argv, "--keep-alive-location-indicator", self.v_ka_location_indicator.get())
            _flag(argv, "--keep-alive-fetch", self.v_ka_fetch.get())
            _flag(argv, "--keep-alive-processing", self.v_ka_processing.get())

        if self.v_files.get():
            argv.append("--files")
            _add(argv, "--files-dylib", self.v_files_dylib.get())
            _add(argv, "--files-root", self.v_files_root.get())
            _add(argv, "--files-import-dir", self.v_files_import_dir.get())
            _flag(argv, "--no-files-sharing", self.v_no_files_sharing.get())

        if self.v_no_panel.get():
            argv.append("--no-panel")
        elif self.v_panel.get():
            argv.append("--panel")
        _add(argv, "--panel-dylib", self.v_panel_dylib.get())
        _add(argv, "--panel-title", self.v_panel_title.get())

        for path in self.custom_dylibs:
            argv += ["--dylib", path]

        for mode in self.v_background_mode.get().replace("，", ",").split(","):
            _add(argv, "--background-mode", mode)
        _flag(argv, "--allow-arbitrary-loads", self.v_allow_arbitrary_loads.get())

        argv += self._common_args()

        if not self.custom_dylibs and not any(
            (self.v_pip.get(), self.v_keep_alive.get(), self.v_files.get(),
             self.v_panel.get(), self.v_background_mode.get().strip(), self.v_allow_arbitrary_loads.get())
        ):
            messagebox.showwarning(
                "没有要注入的东西",
                "请勾选画中画 / 后台保活 / 文件导入导出 / 悬浮窗，或添加自定义 dylib。",
            )
            return None
        return argv

    # ------------------------------------------------------------------ #
    # 动作
    # ------------------------------------------------------------------ #
    def _load_info(self) -> None:
        src = self.v_input.get().strip()
        if not src:
            return
        self._start(self._info_argv(), "info")

    def _load_certs(self) -> None:
        self._start(["certs", "--json"], "certs")

    def _list_injected(self) -> None:
        """核对产物：优先读输出文件，没有产物时才回退到输入包（就地修改时两者相同）。"""
        src = self.v_input.get().strip() if self.v_inplace.get() else self.v_output.get().strip()
        if not src or not os.path.isfile(src):
            src = self.v_input.get().strip()
        if not src:
            messagebox.showwarning("缺少输入", "请先选择要处理的 IPA 文件或已解包目录。")
            return
        self._append(f"[核对] {src}\n")
        self._start(["inject", src, "--list"], "inject-list")

    def _run_current(self, dry_run: bool) -> None:
        index = self.nb.index(self.nb.select())
        if index == 0:  # 信息页
            self._load_info()
            return
        if index == 3:  # 签名页：只放配置，没有可执行的动作
            messagebox.showinfo("提示", "签名参数是「改 ID / 名称」和「注入功能」两个页签共用的，请切到对应页签执行。")
            return
        task = "modify" if index == 1 else "inject"
        argv = self._modify_argv() if index == 1 else self._inject_argv()
        if argv is None:
            return
        if dry_run and "--dry-run" not in argv:
            argv.append("--dry-run")
        self._set_text(self.log, "")
        self._start(argv, task)

    # ------------------------------------------------------------------ #
    def run(self) -> None:
        self.root.mainloop()


def main(argv: list[str] | None = None) -> int:
    _enable_dpi_awareness()
    try:
        app = IpatoolGui()
    except tk.TclError as exc:
        print(f"无法启动图形界面（当前环境可能没有可用的显示）：{exc}", file=sys.stderr)
        return 1
    app.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
