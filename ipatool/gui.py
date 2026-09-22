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

import base64
import contextlib
import io
import json
import os
import platform
import queue
import subprocess
import sys
import threading
import time
import traceback
import uuid
import webbrowser
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

if __package__ in (None, ""):  # 直接运行本文件：python ipatool/gui.py
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from ipatool import cli as cli_mod
    from ipatool import cloud_build as cloud_mod
    from ipatool import device as device_mod
    from ipatool import signer
else:
    from . import cli as cli_mod
    from . import cloud_build as cloud_mod
    from . import device as device_mod
    from . import signer

OPT_DEFAULT = "(默认)"
PASSWORD_MASK = "********"
APP_TITLE = "ipatool"


def _gui_config_path() -> str:
    """
    GUI 设置（含上次选的证书路径与密码）存哪。

    放用户配置目录，不写在工作目录里；密码是**明文**，只为了下次不用重输，
    不想留就在「签名」页取消勾选，或点「清除已保存的证书」。
    路径规则统一在 signer.config_path()，这样命令行也能读到同一份配置。
    """
    return signer.config_path()


CAPTURE_TASKS = ("info", "devices")
DEVICE_POLL_MS = 30_000        # 设备列表静默刷新间隔（插入手机后不用手点「刷新设备」）

# 配色 / 字体：深色 + 青色强调的「科技感」风格。
# 所有控件颜色都从这一块取（ttk 样式在 _configure_style 里统一配），想换肤只改这里。
BG = "#0b0f17"          # 页面底色（近黑蓝）
CARD = "#141a24"        # 卡片底色（卡片里的文字默认按它配）
CARD_ALT = "#1b2431"    # 输入框 / 次级按钮底色
BORDER = "#28313f"      # 边框
BORDER_SOFT = "#1e2632"  # 更淡的分隔线
TEXT = "#e6edf3"        # 正文
MUTED = "#8b98ab"       # 次要说明
BORDER_CONTROL = "#3b4b60"  # 复选框这类小控件的边框（比卡片边框亮一档，不然看不出是个控件）
ACCENT = "#22d3ee"      # 主色（青）
ACCENT_ACTIVE = "#0ea5b7"   # 主色按下 / 悬停
ACCENT_SOFT = "#0f2f3a"     # 主色淡底（选中态）
HOVER = "#243040"       # 次级按钮悬停
OK = "#34d399"          # 成功的提示色
DANGER = "#f87171"      # 出错的提示色

FONT = "Microsoft YaHei UI" if sys.platform == "win32" else "PingFang SC"
MONO = "Consolas" if sys.platform == "win32" else "Menlo"


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


class DarkCheck(tk.Frame):
    """深色界面下的复选框：自己画，两种状态一眼分得清。

    Tk 自带的那两种在这套深色配色下都不能用 ——
      tk.Checkbutton：Windows 上把 selectcolor 当成指示器**两种状态**的填充色，
        未选中就已经是一整块实心主色，跟选中只差「里面有没有对勾」；
      ttk.Checkbutton：clam 主题下是白底黑叉，跟整体配色更不搭。
    所以这里用 Canvas 自己画 15x15 小方块：
      未选中 = 深色底 + 灰边框，选中 = 主色实心 + 深色对勾，
      鼠标移上去描边和文字变主色；点方块或点文字都能切，变量变了自动重画（双向同步）。
    """

    SIZE = 15
    GAP = 7

    def __init__(self, parent, text: str, variable, command=None, **kwargs) -> None:
        super().__init__(parent, background=CARD, cursor="hand2", **kwargs)
        self.var = variable
        self.command = command
        self._hover = False
        self.canvas = tk.Canvas(self, width=self.SIZE, height=self.SIZE, background=CARD,
                                highlightthickness=0, borderwidth=0, takefocus=1)
        self.canvas.pack(side="left")
        self.label = tk.Label(self, text=text, background=CARD, foreground=TEXT,
                              font=(FONT, 10), cursor="hand2", anchor="w", justify="left")
        self.label.pack(side="left", padx=(self.GAP, 0))
        for widget in (self.canvas, self.label):
            widget.bind("<Button-1>", self._toggle)
            widget.bind("<Enter>", self._enter)
            widget.bind("<Leave>", self._leave)
        self.canvas.bind("<space>", self._toggle)
        self._trace = variable.trace_add("write", lambda *_: self._draw())
        self._draw()

    def _enter(self, _event=None) -> None:
        self._hover = True
        self.label.configure(foreground=ACCENT)
        self._draw()

    def _leave(self, _event=None) -> None:
        self._hover = False
        self.label.configure(foreground=TEXT)
        self._draw()

    def _toggle(self, _event=None) -> str:
        self.var.set(not self.var.get())      # 变量一变就重画，不用自己刷新
        if self.command:
            self.command()
        return "break"

    def _draw(self) -> None:
        checked = bool(self.var.get())
        if checked:
            fill, edge = ACCENT, ACCENT
        elif self._hover:
            fill, edge = ACCENT_SOFT, ACCENT
        else:
            fill, edge = CARD_ALT, BORDER_CONTROL
        self.canvas.delete("all")
        self.canvas.create_rectangle(0, 0, self.SIZE - 1, self.SIZE - 1,
                                     fill=fill, outline=edge)
        if checked:
            # 对勾用卡片底色画，压在主色块上，对比度够高
            self.canvas.create_line(3, 8, 6, 11, fill=CARD, width=2,
                                    capstyle="round", joinstyle="round")
            self.canvas.create_line(6, 11, 12, 4, fill=CARD, width=2,
                                    capstyle="round", joinstyle="round")


# --------------------------------------------------------------------------- #
# 主窗口
# --------------------------------------------------------------------------- #
class IpatoolGui:
    def __init__(self) -> None:
        self.root = tk.Tk()
        self.root.title(APP_TITLE)
        self.root.geometry("1020x880")
        self.root.minsize(940, 660)
        self.root.configure(background=BG)
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(2, weight=1)

        self.q: "queue.Queue[tuple[str, object]]" = queue.Queue()
        self._running_tasks: set[str] = set()   # 正在跑的任务（支持签名 / 安装并发）
        self.install_button = None               # 安装到设备按钮，运行时单独禁用
        self.custom_dylibs: list[str] = []
        self.action_buttons: list[ttk.Button] = []

        self._configure_style()
        self._make_vars()
        self._restore_gh_config()
        self._build_inputs()
        self._build_tabs()
        self._build_bottom()

        self.root.after(80, self._poll)
        # 开机就读一次设备，之后空闲时定时静默刷新（插上手机不用手点「刷新设备」）
        self.root.after(1200, self._auto_refresh_devices)
        # 工作线程里那句「已有同名 App，要不要卸载重装」接到界面弹窗上
        device_mod.set_confirm_hook(self._ask_confirm)

    # ------------------------------------------------------------------ #
    # 界面风格
    # ------------------------------------------------------------------ #
    def _configure_style(self) -> None:
        """统一一套深色「科技感」外观：颜色取自上面的配色常量，字体取 FONT / MONO。

        约定：卡片里的控件默认按 CARD 底配（TLabel 就是 CARD 底），
        页面底色上直接放的少量控件用 Page*.TLabel。
        """
        style = ttk.Style(self.root)
        if "clam" in style.theme_names():
            style.theme_use("clam")

        self.root.option_add("*Font", (FONT, 10))
        # 下拉框弹出列表是 Tk 原生 Listbox，样式得单独喂
        self.root.option_add("*TCombobox*Listbox.background", CARD_ALT)
        self.root.option_add("*TCombobox*Listbox.foreground", TEXT)
        self.root.option_add("*TCombobox*Listbox.selectBackground", ACCENT_SOFT)
        self.root.option_add("*TCombobox*Listbox.selectForeground", TEXT)
        self.root.option_add("*TCombobox*Listbox.borderWidth", 0)

        style.configure(".", background=BG, foreground=TEXT, fieldbackground=CARD_ALT,
                        bordercolor=BORDER, lightcolor=BORDER, darkcolor=BORDER,
                        troughcolor=BG, focuscolor=ACCENT, font=(FONT, 10))

        style.configure("TFrame", background=BG)
        style.configure("Card.TFrame", background=CARD)
        style.configure("CardRow.TFrame", background=CARD)

        style.configure("TLabel", background=CARD, foreground=TEXT)
        style.configure("Page.TLabel", background=BG, foreground=TEXT)
        style.configure("Muted.TLabel", background=CARD, foreground=MUTED)
        style.configure("PageMuted.TLabel", background=BG, foreground=MUTED)
        style.configure("Section.TLabel", background=CARD, foreground=TEXT,
                        font=(FONT, 10, "bold"))
        style.configure("Status.TLabel", background=BG, foreground=OK)

        style.configure("TButton", background=CARD_ALT, foreground=TEXT, bordercolor=BORDER,
                        padding=(14, 7), relief="flat", focuscolor=ACCENT, font=(FONT, 10))
        style.map("TButton",
                  background=[("active", HOVER), ("pressed", HOVER), ("disabled", "#161d27")],
                  foreground=[("disabled", "#5b6675")],
                  bordercolor=[("focus", ACCENT), ("active", ACCENT)])
        # 底部日志栏的折叠 / 清空按钮：紧凑样式，少占地方
        style.configure("Mini.TButton", background=CARD_ALT, foreground=TEXT, bordercolor=BORDER,
                        padding=(6, 2), relief="flat", focuscolor=ACCENT, font=(FONT, 9))
        style.map("Mini.TButton",
                  background=[("active", HOVER), ("pressed", HOVER), ("disabled", "#161d27")],
                  foreground=[("disabled", "#5b6675")],
                  bordercolor=[("focus", ACCENT), ("active", ACCENT)])
        style.configure("Accent.TButton", background=ACCENT, foreground="#04212a",
                        bordercolor=ACCENT, padding=(20, 8), font=(FONT, 10, "bold"))
        style.map("Accent.TButton",
                  background=[("active", ACCENT_ACTIVE), ("pressed", ACCENT_ACTIVE),
                              ("disabled", "#14424d")],
                  foreground=[("disabled", "#6d8087")],
                  bordercolor=[("disabled", "#14424d")])

        style.configure("TEntry", fieldbackground=CARD_ALT, foreground=TEXT, bordercolor=BORDER,
                        padding=(8, 6), insertcolor=ACCENT, lightcolor=BORDER, darkcolor=BORDER)
        style.map("TEntry",
                  bordercolor=[("focus", ACCENT)],
                  lightcolor=[("focus", ACCENT)], darkcolor=[("focus", ACCENT)],
                  fieldbackground=[("disabled", "#12181f")],
                  foreground=[("disabled", MUTED)])
        style.configure("TCombobox", fieldbackground=CARD_ALT, background=CARD_ALT, foreground=TEXT,
                        bordercolor=BORDER, arrowcolor=MUTED, padding=(8, 6),
                        lightcolor=BORDER, darkcolor=BORDER)
        style.map("TCombobox",
                  fieldbackground=[("readonly", CARD_ALT), ("disabled", "#12181f")],
                  foreground=[("readonly", TEXT)],
                  arrowcolor=[("active", ACCENT)],
                  bordercolor=[("focus", ACCENT), ("active", ACCENT)],
                  lightcolor=[("focus", ACCENT)], darkcolor=[("focus", ACCENT)])

        style.configure("Treeview", background=CARD, fieldbackground=CARD, foreground=TEXT,
                        bordercolor=BORDER, rowheight=28, font=(FONT, 10))
        style.configure("Treeview.Heading", background=CARD_ALT, foreground=MUTED,
                        relief="flat", font=(FONT, 10, "bold"))
        style.map("Treeview",
                  background=[("selected", ACCENT_SOFT)],
                  foreground=[("selected", TEXT)])
        style.map("Treeview.Heading", background=[("active", HOVER)])

        style.configure("Vertical.TScrollbar", background=CARD_ALT, bordercolor=BG,
                        troughcolor=BG, arrowcolor=MUTED, relief="flat", width=12)
        style.map("Vertical.TScrollbar", background=[("active", HOVER)])
        style.configure("TSeparator", background=BORDER_SOFT)

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


        # 签名
        self.v_sign = tk.StringVar(value="auto")
        self.v_identity = tk.StringVar()
        self.v_p12 = tk.StringVar()
        self.v_p12_password = tk.StringVar()
        self.v_provision = tk.StringVar()

        self.v_zip_level = tk.StringVar(value="auto")
        self.v_remember = tk.BooleanVar(value=True)

        # 证书列表「选择」用（像爱思那样：存下来 → 下拉里选一个，不用每次填路径密码）
        self.v_cert = tk.StringVar()            # 「使用证书」下拉里显示的文本
        self.v_cert_summary = tk.StringVar()    # 下拉下面那行：到底会用哪个
        self.certs: list[dict] = []             # 保存的证书：{id, name, p12, password, provision}
        self._cert_keys: list[str] = []         # 下拉文本 → 键（'' / 'p12:id'）
        self._cert_texts: list[str] = []

        # 安装到设备：装哪个包（留空 = 自动用「输出」）+ 下拉里选一台连着的设备
        self.v_install_ipa = tk.StringVar()
        self.v_device = tk.StringVar()
        self.v_device_summary = tk.StringVar()
        self._device_keys: list[str] = []       # 下拉文本 → UDID（'' = 交给后端自己挑）
        self._device_texts: list[str] = ["（未读取）"]

        # 设备自动刷新用：上次读到的设备集合（没变就不刷日志）、上次的报错（同一段只贴一次）
        self._device_sig: tuple[str, ...] | None = None
        self._device_err = ""

        self.answer_q: "queue.Queue[str]" = queue.Queue()   # 工作线程 ← 界面线程 的答案

        self.v_hardened = tk.BooleanVar(value=False)
        self.v_dry_run = tk.BooleanVar(value=False)
        self.v_verbose = tk.BooleanVar(value=False)

        # 状态
        self.v_status = tk.StringVar(value="就绪")

        # —— GitHub 导入 / Codemagic 构建 / GitHub Actions 编译（B 项本地注入签名本工具自带，不整合）——
        self.v_gh_token = tk.StringVar()
        self.v_owner = tk.StringVar(value=cloud_mod.OWNER)
        self.v_repo = tk.StringVar(value=cloud_mod.REPO)
        self.v_branch = tk.StringVar(value="main")
        self.v_local = tk.StringVar(value=r"d:\Microsoft VS Code\qnet\ios_demo")
        self.v_target = tk.StringVar(value="")
        self.v_visibility = tk.StringVar(value="公开")
        self.v_auto_create = tk.BooleanVar(value=False)
        self.v_cm_token = tk.StringVar()
        self.v_cm_app = tk.StringVar()
        self.v_sign_mode = tk.StringVar(value="ad-hoc(付费账号)")
        self.v_apple_team_id = tk.StringVar()
        self.v_workflow_file = tk.StringVar(value="build-tweak.yml")

        # —— GitHub 仓库导出（下载源码到本地）——
        self.v_export_repo = tk.StringVar()
        self.v_export_branch = tk.StringVar(value="main")
        self.v_export_out = tk.StringVar()
        self.v_export_token = tk.StringVar()
        self.v_dylib_path = tk.StringVar()
        self.v_ipa_path = tk.StringVar()
        # 页面内部状态（下拉选项 / 最近运行等）
        self._repo_full: dict[str, str] = {}
        self.repo_cb = None
        self.repo_cb2 = None
        self.wf_cb = None
        self.cm_app_cb = None
        self._repo_info = tk.StringVar(value="")
        self.app_map: dict[str, str] = {}
        self.last_run_id = None
        self.last_build_id = None
        self.last_artifacts: list = []
        self._restore_gh_config()
        # GitHub 配置：改动即自动保存（token / 仓库等），避免只靠「导入」才落盘
        for var in (self.v_gh_token, self.v_cm_token, self.v_owner, self.v_repo,
                    self.v_branch, self.v_local, self.v_target, self.v_sign_mode,
                    self.v_apple_team_id, self.v_auto_create, self.v_visibility,
                    self.v_workflow_file, self.v_dylib_path, self.v_ipa_path):
            var.trace_add("write", self._schedule_save_gh)

        # 上次的签名设置（证书 / 密码）：启动时恢复，之后改动自动保存
        self._save_job: str | None = None
        self._gh_save_job: str | None = None
        self._restore_settings()
        for var in (self.v_sign, self.v_identity, self.v_p12, self.v_p12_password,
                    self.v_provision,
                    self.v_zip_level, self.v_remember):
            var.trace_add("write", self._schedule_save)
        # 「安装包 / 输出 / 输入 / 就地覆盖」任一变化，都把那行摘要刷新一下
        for var in (self.v_install_ipa, self.v_output, self.v_input, self.v_inplace):
            var.trace_add("write", lambda *_a: self._refresh_install_summary())

    # ------------------------------------------------------------------ #
    # 顶部：输入 / 输出
    # ------------------------------------------------------------------ #
    def _build_inputs(self) -> None:
        card, box = self._card(self.root, "IPA 文件")
        card.grid(row=0, column=0, sticky="ew", padx=12, pady=(12, 8))
        box.columnconfigure(1, weight=1)

        ttk.Label(box, text="输入").grid(row=0, column=0, sticky="w", padx=(0, 6))
        ttk.Entry(box, textvariable=self.v_input).grid(row=0, column=1, sticky="ew")
        ttk.Button(box, text="打开…", width=8, command=self._pick_input).grid(row=0, column=2, padx=6)

        ttk.Label(box, text="输出").grid(row=1, column=0, sticky="w", padx=(0, 6), pady=(6, 0))
        self.ent_output = ttk.Entry(box, textvariable=self.v_output)
        self.ent_output.grid(row=1, column=1, sticky="ew", pady=(6, 0))
        ttk.Button(box, text="另存为…", width=8, command=self._pick_output).grid(row=1, column=2, padx=6, pady=(6, 0))

        hint = ttk.Label(
            box,
            text="输入支持 .ipa 或含 Payload 的目录；输出留空则自动命名。"
                 "选中后不解析，要看包内信息点「读取信息」。",
            style="Muted.TLabel", justify="left", wraplength=940,
        )
        hint.grid(row=2, column=0, columnspan=3, sticky="w", pady=(6, 0))

        self._check(box, "直接覆盖输入文件（--in-place）", self.v_inplace,
                    command=self._sync_inplace).grid(
            row=3, column=0, columnspan=2, sticky="w", pady=(6, 0))

        self.msg_io = ttk.Label(box, text="", foreground=DANGER)
        self.msg_io.grid(row=3, column=2, sticky="w")

    def _sync_inplace(self) -> None:
        self.ent_output.configure(state="disabled" if self.v_inplace.get() else "normal")

    def _pick_input(self) -> None:
        path = filedialog.askopenfilename(
            title="选择 IPA 或已解包目录（目录请用“选择目录”按钮）",
            filetypes=[("iOS 应用包", "*.ipa"), ("所有文件", "*.*")],
        )
        if not path:
            return
        self._set_input_path(path)

    def _pick_input_dir(self) -> None:
        path = filedialog.askdirectory(title="选择已解包的目录（内含 Payload）")
        if path:
            self._set_input_path(path)

    def _set_input_path(self, path: str) -> None:
        """
        选中输入包后**不自动解析**：解析要解包 / 遍历整个包，只想注入和签名的人
        根本不需要这一步。要看 Bundle ID / 名称时，点「读取信息」再读。
        """
        self.v_input.set(path)
        self._append(f"[输入] {path}（未解析，可直接执行）\n")
        self._set_status("已选择输入（未解析）")

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
        # 自定义页签栏：用固定 padx/pady 的标签当按钮，选中只换颜色，
        # 不会被 ttk 主题把选中态画小。
        self.tabbar = tk.Frame(self.root, bg=BG)
        self.tabbar.grid(row=1, column=0, sticky="ew", padx=12)

        self.page_area = tk.Frame(self.root, bg=BG)
        self.page_area.grid(row=2, column=0, sticky="nsew", padx=12, pady=(0, 6))
        self.page_area.columnconfigure(0, weight=1)
        self.page_area.rowconfigure(0, weight=1)

        self._tab_buttons: dict[str, tk.Label] = {}
        self._pages: dict[str, ttk.Frame] = {}
        self._active_tab: str | None = None

        self._build_pack_tab()
        self.info_page = self._build_info_tab()
        self.github_page = self._build_github_tab()
        self.codemagic_page = self._build_codemagic_tab()
        self.compile_page = self._build_compile_tab()
        self.export_page = self._build_export_tab()

        self._add_tab("pack", "  改 ID · 注入 · 签名  ", self.pack_page)
        self._add_tab("info", "  IPA信息  ", self.info_page)
        self._add_tab("github", "  GitHub 导入  ", self.github_page)
        self._add_tab("codemagic", "  Codemagic 构建  ", self.codemagic_page)
        self._add_tab("compile", "  编译打包  ", self.compile_page)
        self._add_tab("export", "  GitHub 导出  ", self.export_page)

        # 页签栏底下的分隔线，铺满整行
        sep = tk.Frame(self.tabbar, bg=BORDER, height=1)
        sep.pack(side="bottom", fill="x")

        # 全局滚轮：悬浮在输入框等单行控件上 → 整页滚动；多行文本/列表/树自己滚
        self.root.bind_all("<MouseWheel>", self._on_page_wheel)
        # Combobox 在 Windows 上滚轮会直接改选项值（还会误触发保存），改成「滚页面」并吞掉
        self.root.bind_class("TCombobox", "<MouseWheel>", self._on_combo_wheel)
        self.root.bind_class("TCombobox", "<Button-4>", self._on_combo_wheel)
        self.root.bind_class("TCombobox", "<Button-5>", self._on_combo_wheel)

        self._select_tab("pack")

    def _add_tab(self, key: str, label: str, page: ttk.Frame) -> None:
        btn = tk.Label(
            self.tabbar, text=label, bg=BG, fg=MUTED,
            font=(FONT, 10, "bold"), padx=20, pady=9, cursor="hand2",
        )
        btn.pack(side="left")
        btn.bind("<Button-1>", lambda _e, k=key: self._select_tab(k))
        btn.bind("<Enter>", lambda _e, k=key: (
            btn.config(fg=TEXT if self._active_tab != k else ACCENT)))
        btn.bind("<Leave>", lambda _e, k=key: (
            btn.config(fg=ACCENT if self._active_tab == k else MUTED)))
        self._tab_buttons[key] = btn
        self._pages[key] = page

    def _select_tab(self, key: str) -> None:
        if self._active_tab == key:
            return
        self._active_tab = key
        for k, btn in self._tab_buttons.items():
            active = (k == key)
            btn.config(bg=(CARD if active else BG), fg=(ACCENT if active else MUTED))
        for k, page in self._pages.items():
            if k == key:
                page.grid(row=0, column=0, sticky="nsew")
                page.lift()
            else:
                page.grid_remove()

    # ---- 改 ID · 注入 · 签名（合并页） -------------------------------- #
    def _build_pack_tab(self) -> None:
        page = self._scroll_page()
        # 改 ID / 名称 与 注入 dylib 左右并排放在同一行
        top = ttk.Frame(page)
        top.grid(row=0, column=0, sticky="ew", pady=(0, 10))
        top.columnconfigure(0, weight=1)
        top.columnconfigure(1, weight=1)
        self._build_pack_identity(top, 0, column=0, sticky="nsew")
        self._build_pack_dylib(top, 0, column=1, sticky="nsew")
        self._build_pack_sign(page, 1)
        self._build_pack_install(page, 2)

    # ---- 信息 --------------------------------------------------------- #
    def _build_info_tab(self) -> None:
        # 也用可滚动页：内容高时整页滚，底部不会被裁掉
        outer, page = self._make_scroll(self.page_area)
        self.info_page = outer
        page.columnconfigure(0, weight=1)

        bar = ttk.Frame(page)
        bar.grid(row=0, column=0, sticky="ew")
        ttk.Button(bar, text="读取信息", command=self._load_info).pack(side="left")
        ttk.Button(bar, text="选择目录…", command=self._pick_input_dir).pack(side="left", padx=8)
        ttk.Label(
            bar, text="解包后读取，包大时稍慢",
            style="PageMuted.TLabel",
        ).pack(side="left")

        self.info_tree = ttk.Treeview(page, columns=("k", "v"), show="headings", height=9)
        self.info_tree.heading("k", text="属性")
        self.info_tree.heading("v", text="值")
        self.info_tree.column("k", width=150, stretch=False)
        self.info_tree.column("v", width=700)
        self.info_tree.grid(row=1, column=0, sticky="ew", pady=(10, 10))

        card, detail_box = self._card(page, "内嵌 bundle / 已注入 dylib")
        card.grid(row=2, column=0, sticky="ew")
        detail_box.columnconfigure(0, weight=1, minsize=0)
        detail_box.columnconfigure(1, weight=0)   # 同上：滚动条列别抢宽度
        detail_box.rowconfigure(0, weight=1)
        self.info_detail = tk.Text(
            detail_box, height=8, wrap="none", state="disabled", font=(MONO, 9),
            background=CARD_ALT, foreground=TEXT, relief="flat", borderwidth=0,
            highlightthickness=1, highlightcolor=ACCENT, highlightbackground=BORDER,
            padx=8, pady=6,
        )
        self.info_detail.grid(row=0, column=0, sticky="nsew")
        bar_y = ttk.Scrollbar(detail_box, orient="vertical", command=self.info_detail.yview)
        bar_y.grid(row=0, column=1, sticky="ns", padx=(2, 0))
        self.info_detail.configure(yscrollcommand=self._fade_scrollbar(bar_y))
        return outer

    def _make_scroll(self, parent) -> tuple[ttk.Frame, ttk.Frame]:
        """造一个可竖向滚动的页：返回（外层页框, 内层内容 Frame）。

        外层用 grid 放进页面区，内层像普通 Frame 一样往里加控件。
        内容比窗口高时整页滚动，绝不裁掉底部。
        """
        outer = ttk.Frame(parent)
        outer.columnconfigure(0, weight=1)
        outer.rowconfigure(0, weight=1)

        canvas = tk.Canvas(outer, background=BG, highlightthickness=0, borderwidth=0)
        canvas.grid(row=0, column=0, sticky="nsew")
        canvas._page_scroll = True
        vbar = ttk.Scrollbar(outer, orient="vertical", command=canvas.yview)
        vbar.grid(row=0, column=1, sticky="ns")
        canvas.configure(yscrollcommand=self._fade_scrollbar(vbar))

        inner = ttk.Frame(canvas, padding=(10, 8, 10, 8))
        inner.columnconfigure(0, weight=1)
        window = canvas.create_window((0, 0), window=inner, anchor="nw")

        # 重算滚动区：内容/窗口尺寸一变就更新。
        # 关键：滚动区下界钳到可视区——内容比屏幕矮时 scrollregion 正好等于可视区，
        # 于是「不满一屏」时上下都滚不动；内容超高时保持内容高度，正常可滚。
        # bbox 可能为 None（还没布局好），先判空再设，避免把 scrollregion 写坏。
        def _sync_region(_e=None):
            bbox = canvas.bbox("all")
            if not bbox:
                return
            x0, y0, x1, y1 = bbox
            cw, ch = canvas.winfo_width(), canvas.winfo_height()
            if cw:
                x1 = max(x1, cw)
            if ch:
                y1 = max(y1, ch)
            canvas.configure(scrollregion=(x0, y0, x1, y1))

        inner.bind("<Configure>", _sync_region)
        canvas.bind("<Configure>",
                    lambda e: (canvas.itemconfigure(window, width=e.width),
                               _sync_region()))
        # 切到该页（显示）时再算一次：隐藏页的尺寸是 0，inner 不一定重触发，
        # 否则 scrollregion 停在旧值——看起来没满屏却滚不动 / 底部被裁。
        outer.bind("<Map>", lambda _e: _sync_region())
        return outer, inner

    def _on_page_wheel(self, event):
        """鼠标在页面上滚：只要悬停在某个可滚页面里（输入框 / 信息框 / 列表 /
        树都算），就滚动整页；只有不在页面里的自带滚动控件（如底部日志）才自己滚。"""
        w = event.widget
        cv = self._find_page_canvas(w)
        if cv is not None:
            delta = getattr(event, "delta", 0)
            if delta:
                step = int(-delta / 120) if abs(delta) >= 120 else (-1 if delta > 0 else 1)
                cv.yview_scroll(step or 1, "units")
            return "break"
        # 不在可滚页面里（如底部日志框）：交给自带滚动条的控件自己滚
        if isinstance(w, (tk.Text, tk.Listbox, ttk.Treeview)) and self._can_self_scroll(w):
            delta = getattr(event, "delta", 0)
            if delta:
                step = int(-delta / 120) if abs(delta) >= 120 else (-1 if delta > 0 else 1)
                w.yview_scroll(step or 1, "units")
            return "break"
        return None

    def _on_combo_wheel(self, event):
        """Combobox 滚轮：改为整页滚动并吞掉事件，避免 Windows 上滚轮误改选项值
        （误改 v_sign 等还会触发「已保存证书设置」刷屏）。下拉打开时目标是 Listbox，
        不会走到这里，下拉内滚动不受影响。"""
        cv = self._find_page_canvas(event.widget)
        if cv is not None:
            delta = getattr(event, "delta", 0)
            if event.num in (4, 5):          # Linux 触控板上下
                step = -1 if event.num == 4 else 1
            else:
                step = int(-delta / 120) if abs(delta) >= 120 else (-1 if delta > 0 else 1)
            cv.yview_scroll(step or 1, "units")
        return "break"

    @staticmethod
    def _can_self_scroll(w) -> bool:
        """控件自己能不能滚：有竖向滚动条、且内容确实超出可视区才自己滚。"""
        try:
            if not w.cget("yscrollcommand"):
                return False
            first, last = w.yview()
        except Exception:
            return False
        return not (first <= 0.0 and last >= 1.0)

    @staticmethod
    def _find_page_canvas(w):
        while w is not None and not isinstance(w, tk.Tk):
            if getattr(w, "_page_scroll", False):
                return w
            w = w.master
        return None

    def _scroll_page(self) -> ttk.Frame:
        """
        一个可以滚动的页面：内容比窗口高时出现竖向滚动条，而不是被裁掉。
        返回内层 Frame，往里加控件即可（用法和普通页面一样）。
        """
        outer, inner = self._make_scroll(self.page_area)
        self.pack_page = outer
        return inner

    # ---- 改 ID / 名称 -------------------------------------------------- #
    def _build_pack_identity(self, parent, row: int, column: int = 0,
                              sticky: str = "new") -> None:
        box = self._group(parent, "改 ID / 名称（留空不改）", row, column, sticky)
        self._entry(box, 0, "Bundle Identifier", self.v_bundle_id)
        self._entry(box, 1, "显示名称", self.v_name)

    # ---- 注入 dylib ---------------------------------------------------- #
    def _build_pack_dylib(self, parent, row: int, column: int = 0,
                           sticky: str = "new") -> None:
        box = self._group(parent, "注入 dylib", row, column, sticky)
        wrap = ttk.Frame(box, style="Card.TFrame")
        wrap.grid(row=0, column=0, columnspan=4, sticky="ew")
        wrap.columnconfigure(0, weight=1)
        self.list_dylibs = tk.Listbox(
            wrap, height=5, selectmode="extended", font=(MONO, 9),
            background=CARD_ALT, foreground=TEXT, activestyle="none",
            relief="flat", borderwidth=0, highlightthickness=1,
            highlightcolor=ACCENT, highlightbackground=BORDER,
            selectbackground=ACCENT_SOFT, selectforeground=TEXT,
        )
        self.list_dylibs.grid(row=0, column=0, sticky="ew")
        bar_y = ttk.Scrollbar(wrap, orient="vertical", command=self.list_dylibs.yview)
        bar_y.grid(row=0, column=1, sticky="ns", padx=(2, 0))
        self.list_dylibs.configure(yscrollcommand=self._fade_scrollbar(bar_y))

        btns = ttk.Frame(box, style="Card.TFrame")
        btns.grid(row=1, column=0, columnspan=4, sticky="ew", pady=(10, 0))
        btns.columnconfigure(0, weight=1)
        btns.columnconfigure(1, weight=1)
        for index, (label, command) in enumerate((
            ("添加 dylib…", self._add_dylib),
            ("移除所选", self._remove_dylib),
            ("清空", self._clear_dylib),
            ("核对产物", self._list_injected),
        )):
            r, c = divmod(index, 2)
            ttk.Button(btns, text=label, command=command).grid(
                row=r, column=c, sticky="ew",
                padx=(0, 4) if c == 0 else (4, 0),
                pady=(0, 4) if r == 0 else 0)

        ttk.Label(
            box, style="Muted.TLabel", justify="left",
            text="放进 Frameworks/ 并写入 LC_LOAD_DYLIB；列表顺序>>加载顺序。",
        ).grid(row=2, column=0, columnspan=4, sticky="w", pady=(8, 0))

    # ---- 签名 ---------------------------------------------------------- #
    def _build_pack_sign(self, page, row: int) -> None:
        box = self._group(page, "签名（不选证书则 ad-hoc，真机装不上）", row)
        ttk.Label(box, text="后端").grid(row=0, column=0, sticky="w", padx=(0, 8), pady=3)
        ttk.Combobox(
            box, textvariable=self.v_sign, values=list(signer.BACKENDS),
            state="readonly", width=14,
        ).grid(row=0, column=1, sticky="w", pady=3)
        ttk.Label(
            box, style="Muted.TLabel", justify="left", wraplength=420,
            text="macOS 用 codesign，其他平台用项目自带的 zsign；none>>只打包不签名",
        ).grid(row=0, column=2, sticky="w", padx=(10, 0), pady=3)

        ttk.Label(box, text="使用证书").grid(row=1, column=0, sticky="w", padx=(0, 8), pady=3)
        self.cb_cert = ttk.Combobox(box, textvariable=self.v_cert, values=[], state="readonly", width=46)
        self.cb_cert.grid(row=1, column=1, columnspan=3, sticky="ew", pady=3)
        self.cb_cert.bind("<<ComboboxSelected>>", self._apply_cert_choice)

        certbtns = ttk.Frame(box)
        certbtns.grid(row=2, column=1, columnspan=3, sticky="w")
        ttk.Button(certbtns, text="添加证书…", command=self._open_cert_dialog).pack(side="left")
        ttk.Button(certbtns, text="编辑…", command=self._edit_cert).pack(side="left", padx=(6, 0))
        ttk.Button(certbtns, text="删除", command=self._delete_cert).pack(side="left", padx=(6, 0))

        ttk.Label(
            box, style="Muted.TLabel", justify="left", wraplength=680,
            textvariable=self.v_cert_summary,
        ).grid(row=3, column=0, columnspan=4, sticky="w", pady=(2, 3))

        self._entry(box, 4, "描述文件", self.v_provision, "改过 Bundle ID 需匹配", browse=lambda: self._pick_file(self.v_provision, [("描述文件", "*.mobileprovision"), ("所有文件", "*.*")]))

        # 记住证书（勾选则下次自动填好）+ 清除已保存
        self._check(box, "记住证书 / 密码", self.v_remember).grid(
            row=6, column=0, columnspan=3, sticky="w", pady=(10, 0))
        ttk.Label(
            box, style="Muted.TLabel", justify="left", wraplength=620,
            text=f"保存在 {_gui_config_path()}",
        ).grid(row=7, column=0, columnspan=2, sticky="w", pady=(4, 0))
        ttk.Button(
            box, text="清除已保存的证书", command=self._clear_settings,
        ).grid(row=7, column=3, sticky="e", padx=(10, 0))

        # 开始执行（直接放在签名这一栏）：按当前页填写内容自动决定做什么
        b = ttk.Button(box, text="执行签名+注入", style="Accent.TButton",
                       command=lambda: self._run_current(dry_run=False))
        b.grid(row=8, column=0, sticky="w", padx=(0, 8), pady=(12, 0))
        self.action_buttons.append(b)
        ttk.Label(
            box, style="Muted.TLabel", justify="left", wraplength=520,
            text="按当前页填写内容自动执行：填了 dylib 就注入+签名，填了 ID/名称就改掉，"
                 "都没填就只重新打包+签名。",
        ).grid(row=8, column=1, columnspan=3, sticky="w", pady=(12, 0))

    # ---- 安装到设备 ---------------------------------------------------- #
    def _build_pack_install(self, page, row: int) -> None:
        box = self._group(page, "安装到设备", row)
        # 装哪个包：留空 = 自动用「输出」（就地覆盖时用「输入」），也可以自己挑一个
        ttk.Label(box, text="安装包").grid(row=0, column=0, sticky="w", padx=(0, 8), pady=3)
        ttk.Entry(box, textvariable=self.v_install_ipa).grid(
            row=0, column=1, columnspan=2, sticky="ew", pady=3)
        ipabtns = ttk.Frame(box)
        ipabtns.grid(row=0, column=3, sticky="w", padx=(10, 0))
        ttk.Button(ipabtns, text="选择…", width=8, command=self._pick_install_ipa).pack(side="left")
        ttk.Button(ipabtns, text="清除", width=6, command=self._clear_install_ipa).pack(
            side="left", padx=(6, 0))

        ttk.Label(box, text="设备").grid(row=1, column=0, sticky="w", padx=(0, 8), pady=3)
        self.cb_device = ttk.Combobox(box, textvariable=self.v_device, values=[],
                                      state="readonly", width=46)
        self.cb_device.grid(row=1, column=1, columnspan=2, sticky="ew", pady=3)
        ttk.Button(box, text="刷新设备", command=self._load_devices).grid(
            row=1, column=3, sticky="w", padx=(10, 0), pady=3)
        self.cb_device.bind("<<ComboboxSelected>>", lambda _e: self._refresh_install_summary())

        acts = ttk.Frame(box)
        acts.grid(row=2, column=1, columnspan=3, sticky="w", pady=(6, 0))
        self.install_button = ttk.Button(acts, text="安装到设备", style="Accent.TButton",
                                         command=self._install_to_device)
        self.install_button.pack(side="left")
        ttk.Button(acts, text="打开产物文件夹", command=self._reveal_output).pack(
            side="left", padx=(6, 0))
        ttk.Button(acts, text="复制路径", command=self._copy_output_path).pack(
            side="left", padx=(6, 0))
        ttk.Label(
            box, style="Muted.TLabel", justify="left", wraplength=680,
            textvariable=self.v_device_summary,
        ).grid(row=3, column=0, columnspan=4, sticky="w", pady=(6, 0))
        ttk.Label(
            box, style="Muted.TLabel", justify="left", wraplength=680,
            )
        self._refresh_install_summary()

    # ------------------------------------------------------------------ #
    # 底部：日志 + 操作
    # ------------------------------------------------------------------ #
    def _build_bottom(self) -> None:
        area = ttk.Frame(self.root)
        area.grid(row=3, column=0, sticky="nsew", padx=10, pady=(2, 6))
        area.columnconfigure(0, weight=1)
        area.rowconfigure(1, weight=1)

        self._bottom_area = area
        bar = ttk.Frame(area)
        bar.grid(row=0, column=0, sticky="ew")
        self.lbl_status = ttk.Label(bar, textvariable=self.v_status, style="Status.TLabel")
        self.lbl_status.pack(side="right")
        # 折叠 / 展开运行日志：点一下把整张卡片收起，省出下方空间（默认收起）
        self._log_toggle_btn = ttk.Button(bar, text="日志 ▲", style="Mini.TButton",
                                          command=self._toggle_log)
        self._log_toggle_btn.pack(side="left", padx=(0, 4))
        ttk.Button(bar, text="清空日志", style="Mini.TButton",
                   command=lambda: self._set_text(self.log, "")).pack(side="left", padx=(4, 6))

        card, log_box = self._card(area, "运行日志")
        self.log_card = card
        # 运行日志默认收起：卡片不 grid，_toggle_log 展开时再加回
        self._log_collapsed = True
        card.rowconfigure(1, weight=1)
        log_box.grid_configure(sticky="nsew")    # 卡片拉高了，日志就跟着长（不再空在底部）
        log_box.columnconfigure(0, weight=1, minsize=0)
        log_box.columnconfigure(1, weight=0)     # 滚动条那列不参与分宽度，否则被推得老远
        log_box.rowconfigure(0, weight=1)
        self.log = tk.Text(
            log_box, height=9, wrap="word", state="disabled", font=(MONO, 9),
            background=CARD_ALT, foreground=TEXT, relief="flat", borderwidth=0,
            highlightthickness=1, highlightcolor=ACCENT, highlightbackground=BORDER,
            insertbackground=ACCENT, padx=8, pady=6,
        )
        self.log.grid(row=0, column=0, sticky="nsew")
        bar_y = ttk.Scrollbar(log_box, orient="vertical", command=self.log.yview)
        bar_y.grid(row=0, column=1, sticky="ns", padx=(2, 0))
        self.log.configure(yscrollcommand=self._fade_scrollbar(bar_y))
        self.log.tag_configure("err", foreground=DANGER)

        # 一开机就把「zsign 用的哪一份」写在日志里，省得回头猜它到底找没找到
        zsign = signer.zsign_binary()
        if zsign:
            self._append(f"[签名] zsign  : {zsign}\n")

    def _toggle_log(self) -> None:
        """折叠 / 展开运行日志卡片。

        折叠时把整张卡片 grid_remove，并把底部区域的第 1 行权重收回，
        日志区就不占高度了（状态栏、清空/折叠按钮仍在）。展开时还原。
        折叠期间日志仍在后台累加，只是不可见，展开后即可看到。
        """
        if self._log_collapsed:
            self.log_card.grid(row=1, column=0, sticky="nsew", pady=(10, 0))
            self._bottom_area.rowconfigure(1, weight=1)
            self._log_toggle_btn.configure(text="收起 ▼")
            self._log_collapsed = False
        else:
            self.log_card.grid_remove()
            self._bottom_area.rowconfigure(1, weight=0)
            self._log_toggle_btn.configure(text="日志 ▲")
            self._log_collapsed = True

    # ------------------------------------------------------------------ #
    # 布局小助手
    # ------------------------------------------------------------------ #
    def _fade_scrollbar(self, bar: ttk.Scrollbar):
        """没东西可滚的时候把滚动条收起来（否则它只是一条动不了的灰块）。

        返回的闭包直接当 yscrollcommand 用：内容或窗口一变，Tk 就会调它，
        看到范围是整段（0.0 ~ 1.0）就藏，能滚了再放回来。
        """
        def _sync(first, last):
            if float(first) <= 0.0 and float(last) >= 1.0:
                bar.grid_remove()
            else:
                bar.grid()
            bar.set(first, last)
        return _sync

    def _card(self, parent, title: str) -> tuple[tk.Frame, ttk.Frame]:
        """画一张卡片（左侧主色竖条 + 标题 + 内容区），返回 (卡片, 内容区)。

        内容区的第 0 列有最小宽度，各行的字段名能对齐；往里加控件和普通 Frame 一样。
        """
        card = tk.Frame(parent, background=CARD, highlightthickness=1,
                        highlightbackground=BORDER, highlightcolor=BORDER)
        card.columnconfigure(0, weight=1)
        head = tk.Frame(card, background=CARD)
        head.grid(row=0, column=0, sticky="ew", padx=14, pady=(11, 0))
        tk.Frame(head, background=ACCENT, width=3, height=15).pack(side="left", padx=(0, 9))
        tk.Label(head, text=title, background=CARD, foreground=TEXT,
                 font=(FONT, 10, "bold")).pack(side="left")

        body = ttk.Frame(card, style="Card.TFrame", padding=(14, 10, 14, 12))
        body.grid(row=1, column=0, sticky="ew")
        body.columnconfigure(1, weight=1)
        body.columnconfigure(0, minsize=88)
        return card, body

    def _group(self, parent, title: str, row: int, column: int = 0,
               sticky: str = "new") -> ttk.Frame:
        """页签里的一块卡片（自动占一行 / 某一列）。返回内容区。"""
        card, body = self._card(parent, title)
        card.grid(row=row, column=column, sticky=sticky, pady=(0, 10))
        parent.columnconfigure(column, weight=1)
        return body

    # ------------------------------------------------------------------ #
    # 记住上次的签名设置（证书 / 密码）
    # ------------------------------------------------------------------ #
    def _read_settings(self) -> dict:
        try:
            with open(_gui_config_path(), "r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def _restore_settings(self) -> None:
        """启动时把上次选的证书 / 密码填回去（没有文件就当第一次用）。"""
        data = self._read_settings()
        if not data:
            return
        self.v_sign.set(str(data.get("sign") or "auto"))
        self.v_identity.set(str(data.get("identity") or ""))
        self.v_p12.set(str(data.get("p12") or ""))
        self.v_provision.set(str(data.get("provision") or ""))
        self.v_zip_level.set(str(data.get("zip_level") or "auto"))
        self.v_remember.set(bool(data.get("remember", True)))
        if self.v_remember.get():
            self.v_p12_password.set(str(data.get("p12_password") or ""))

        # 证书列表：存下来的 p12 证书 + 上次选的是哪一个
        raw_certs = data.get("certs")
        self.certs = ([c for c in raw_certs if isinstance(c, dict) and c.get("p12")]
                      if isinstance(raw_certs, list) else [])
        choice = str(data.get("cert_choice") or "")
        legacy_p12 = str(data.get("p12") or "")
        if not self.certs and legacy_p12 and os.path.isfile(legacy_p12):
            # 老配置里只存了一个 p12 路径：自动转成一条证书记录，不用重新填
            entry = {
                "id": uuid.uuid4().hex[:8],
                "name": os.path.basename(legacy_p12),
                "p12": legacy_p12,
                "password": str(data.get("p12_password") or ""),
                "provision": str(data.get("provision") or ""),
            }
            self.certs = [entry]
            choice = f"p12:{entry['id']}"
            notes_prefix = "已把上次的证书收进证书列表"
        else:
            notes_prefix = ""
        self._rebuild_cert_choices(select=choice)

        notes = []
        if notes_prefix:
            notes.append(notes_prefix)
        if self.v_p12.get() or self.v_identity.get():
            notes.append("已载入上次的签名设置")
        if notes:
            self.v_status.set("，".join(notes))

    def _write_settings(self) -> None:
        self._save_job = None
        path = _gui_config_path()
        data = {
            "sign": self.v_sign.get(),
            "identity": self.v_identity.get(),
            "p12": self.v_p12.get(),
            "provision": self.v_provision.get(),
            "certs": self.certs,
            "cert_choice": self._current_cert_key(),
            "zip_level": self.v_zip_level.get(),
            "remember": bool(self.v_remember.get()),
            # 明文保存：图的是下次不用重输。不想留就取消勾选，或点「清除已保存的证书」
            "p12_password": self.v_p12_password.get() if self.v_remember.get() else "",
        }
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
            if os.name == "posix":
                os.chmod(path, 0o600)     # 只有自己能读
        except OSError as exc:
            self._append(f"[设置] 保存失败：{exc}\n", "err")
            return
        self._append(f"[设置] 已保存证书设置（{path}）\n")

    def _schedule_save(self, *_args) -> None:
        """变量一变就排队保存；防抖 500ms，免得每敲一个字符写一次盘。"""
        if self._save_job:
            try:
                self.root.after_cancel(self._save_job)
            except Exception:
                pass
        self._save_job = self.root.after(500, self._write_settings)

    def _schedule_save_gh(self, *_args) -> None:
        """GitHub 配置变量一变就排队保存；防抖 500ms，避免每敲一字写一次盘。"""
        if self._gh_save_job:
            try:
                self.root.after_cancel(self._gh_save_job)
            except Exception:
                pass
        self._gh_save_job = self.root.after(500, self._save_gh_config)

    def _clear_settings(self) -> None:
        if not messagebox.askyesno("清除已保存的证书",
                                   "删掉已保存的证书路径和密码？（证书文件本身不动）"):
            return
        try:
            os.remove(_gui_config_path())
        except OSError:
            pass
        self.v_p12_password.set("")
        self.v_p12.set("")
        self.v_identity.set("")
        self.certs = []                      # 证书列表也一起清掉，否则下次保存又写回去
        self._rebuild_cert_choices(select="")
        self._append("[设置] 已清除保存的证书信息\n")

    # ------------------------------------------------------------------ #
    # 证书列表：存下来 + 下拉里选一个（像爱思的证书管理）
    # ------------------------------------------------------------------ #
    def _cert_choices(self) -> list[tuple[str, str]]:
        """(下拉显示文本, 键)。键：''=不用证书，'p12:<id>'=保存的证书文件。"""
        choices: list[tuple[str, str]] = [("不使用证书（通常 ad-hoc）", "")]
        for cert in self.certs:
            choices.append((f"证书文件：{cert.get('name', '')}", f"p12:{cert.get('id', '')}"))
        return choices

    def _current_cert_key(self) -> str:
        text = self.v_cert.get()
        if text in self._cert_texts:
            return self._cert_keys[self._cert_texts.index(text)]
        # 界面还没建好（启动恢复阶段）时，按已解析出来的值反推
        if self.v_p12.get().strip():
            return "p12:"
        return ""

    def _cert_of_key(self, key: str) -> dict | None:
        cert_id = key[4:] if key.startswith("p12:") else ""
        if not cert_id:
            return None
        return next((c for c in self.certs if c.get("id") == cert_id), None)

    def _rebuild_cert_choices(self, select: str | None = None) -> None:
        """按当前证书列表刷新下拉；select 给定时选中对应项。"""
        choices = self._cert_choices()
        self._cert_keys = [key for _text, key in choices]
        self._cert_texts = [text for text, _key in choices]
        if hasattr(self, "cb_cert"):
            self.cb_cert.configure(values=self._cert_texts)
        if hasattr(self, "cb_cert_dylib"):
            self.cb_cert_dylib.configure(values=self._cert_texts)
        want = self._current_cert_key() if select is None else select
        if want not in self._cert_keys:
            want = ""
        self.v_cert.set(self._cert_texts[self._cert_keys.index(want)])
        self._apply_cert_choice()

    def _apply_cert_choice(self, *_args) -> None:
        """
        把「使用证书」的选择翻译成实际参数：选哪个就只带那一种参数，
        所以不会再出现「ID 签名和证书签名都填了，不知道实际用哪个」。
        """
        key = self._current_cert_key()
        if key.startswith("p12:"):
            cert = self._cert_of_key(key)
            if cert is not None:
                self.v_p12.set(str(cert.get("p12", "")))
                self.v_p12_password.set(str(cert.get("password", "")))
                self.v_identity.set("")
                if cert.get("provision") and not self.v_provision.get().strip():
                    self.v_provision.set(str(cert["provision"]))
                tail = "有密码" if cert.get("password") else "无密码（可用 IPATOOL_P12_PASSWORD）"
                self.v_cert_summary.set(f"→ 证书文件：{cert.get('p12', '')}（{tail}）")
                self._schedule_save()
                return
        self.v_identity.set("")
        self.v_p12.set("")
        self.v_p12_password.set("")
        self.v_cert_summary.set("→ 不带证书，结果是 ad-hoc（真机装不上）")
        self._schedule_save()

    def _pick_into(self, var: tk.StringVar, filetypes) -> None:
        path = filedialog.askopenfilename(filetypes=filetypes)
        if path:
            var.set(path)

    def _upsert_cert(self, entry: dict) -> None:
        self.certs = [c for c in self.certs if c.get("id") != entry.get("id")]
        self.certs.append(entry)
        self.certs.sort(key=lambda c: str(c.get("name", "")))

    def _open_cert_dialog(self, cert: dict | None = None) -> None:
        """
        添加 / 编辑一张证书：p12 路径 + 密码（描述文件可选）存下来，
        以后直接从「使用证书」下拉里选，不用每次重新填。
        """
        editing = bool(cert)
        dlg = tk.Toplevel(self.root)
        dlg.title("编辑证书" if editing else "添加证书")
        dlg.configure(background=CARD)
        dlg.resizable(False, False)
        dlg.transient(self.root)

        name = tk.StringVar(value=str((cert or {}).get("name", "")))
        p12 = tk.StringVar(value=str((cert or {}).get("p12", "")))
        pwd = tk.StringVar(value=str((cert or {}).get("password", "")))
        prov = tk.StringVar(value=str((cert or {}).get("provision", "")))

        frame = ttk.Frame(dlg, style="Card.TFrame", padding=14)
        frame.grid(row=0, column=0, sticky="nsew")
        frame.columnconfigure(1, weight=1)

        ttk.Label(frame, text="名称").grid(row=0, column=0, sticky="w", pady=3)
        ttk.Entry(frame, textvariable=name, width=34).grid(row=0, column=1, columnspan=2, sticky="ew", pady=3)

        ttk.Label(frame, text="证书文件").grid(row=1, column=0, sticky="w", pady=3)
        ttk.Entry(frame, textvariable=p12, width=34).grid(row=1, column=1, sticky="ew", pady=3)
        ttk.Button(
            frame, text="选择…", width=8,
            command=lambda: self._pick_into(p12, [("证书", "*.p12 *.pfx"), ("所有文件", "*.*")]),
        ).grid(row=1, column=2, padx=(6, 0), pady=3)

        ttk.Label(frame, text="证书密码").grid(row=2, column=0, sticky="w", pady=3)
        ttk.Entry(frame, textvariable=pwd, show="*", width=34).grid(
            row=2, column=1, columnspan=2, sticky="ew", pady=3)

        ttk.Label(frame, text="描述文件").grid(row=3, column=0, sticky="w", pady=3)
        ttk.Entry(frame, textvariable=prov, width=34).grid(row=3, column=1, sticky="ew", pady=3)
        ttk.Button(
            frame, text="选择…", width=8,
            command=lambda: self._pick_into(prov, [("描述文件", "*.mobileprovision"), ("所有文件", "*.*")]),
        ).grid(row=3, column=2, padx=(6, 0), pady=3)

        ttk.Label(
            frame, style="Muted.TLabel", justify="left", wraplength=430,
            text="密码明文保存（可留空）；描述文件留空则用「签名」区那一栏",
        ).grid(row=4, column=0, columnspan=3, sticky="w", pady=(8, 0))

        buttons = ttk.Frame(frame)
        buttons.grid(row=5, column=0, columnspan=3, sticky="e", pady=(10, 0))

        def on_ok() -> None:
            cert_p12 = p12.get().strip().strip('"')
            if not cert_p12 or not os.path.isfile(cert_p12):
                messagebox.showwarning("证书文件", "请选择一个存在的 p12 / pfx 文件。", parent=dlg)
                return
            entry = {
                "id": str((cert or {}).get("id") or uuid.uuid4().hex[:8]),
                "name": name.get().strip() or os.path.basename(cert_p12),
                "p12": cert_p12,
                "password": pwd.get(),
                "provision": prov.get().strip(),
            }
            self._upsert_cert(entry)
            self._schedule_save()
            dlg.destroy()
            self._rebuild_cert_choices(select=f"p12:{entry['id']}")
            self._append(f"[证书] 已保存「{entry['name']}」：{entry['p12']}\n")

        ttk.Button(buttons, text="取消", command=dlg.destroy).pack(side="left", padx=(0, 6))
        ttk.Button(buttons, text="确定", style="Accent.TButton", command=on_ok).pack(side="left")

        dlg.bind("<Return>", lambda _e: on_ok())
        dlg.bind("<Escape>", lambda _e: dlg.destroy())
        dlg.grab_set()      # 模态：别让主窗口同时被点
        dlg.focus_force()
        self._center_window(dlg, self.root)

    def _center_window(self, win: tk.Toplevel, parent: tk.Misc) -> None:
        win.update_idletasks()
        px, py = parent.winfo_rootx(), parent.winfo_rooty()
        pw, ph = parent.winfo_width(), parent.winfo_height()
        win.geometry(f"+{px + max(0, (pw - win.winfo_width()) // 2)}"
                     f"+{py + max(0, (ph - win.winfo_height()) // 3)}")

    def _edit_cert(self) -> None:
        cert = self._cert_of_key(self._current_cert_key())
        if cert is None:
            messagebox.showinfo("编辑证书", "先在「使用证书」里选一张，再点编辑。")
            return
        self._open_cert_dialog(cert)

    def _delete_cert(self) -> None:
        cert = self._cert_of_key(self._current_cert_key())
        if cert is None:
            messagebox.showinfo("删除证书", "先在「使用证书」里选一张，再点删除。")
            return
        if not messagebox.askyesno("删除证书",
                                   f"把「{cert.get('name', '')}」从列表里删掉？（证书文件不动）"):
            return
        self.certs = [c for c in self.certs if c.get("id") != cert.get("id")]
        self._schedule_save()
        self._append(f"[证书] 已删除「{cert.get('name', '')}」\n")
        self._rebuild_cert_choices(select="")

    def _check(self, parent, text: str, var: tk.BooleanVar, command=None) -> DarkCheck:
        """页面里加一个复选框（自己画的那种，见 DarkCheck）。"""
        return DarkCheck(parent, text, var, command)

    def _entry(self, box, row, label, var, hint=None, browse=None, width=36):
        """一行「字段名 + 输入框 (+ 浏览按钮 / 提示)」。

        按钮和提示打包在输入框右边紧跟的位置：不然它们会被同一个网格里跨列的控件
        （比如证书下拉框）带歪，提示文字被挤到很右边、看着像没对齐。
        """
        ttk.Label(box, text=label).grid(row=row, column=0, sticky="w", padx=(0, 8), pady=4)
        ttk.Entry(box, textvariable=var, width=width).grid(row=row, column=1, sticky="ew", pady=4)
        box.columnconfigure(1, weight=1)
        if browse or hint:
            tail = ttk.Frame(box, style="Card.TFrame")
            tail.grid(row=row, column=2, sticky="w", padx=(8, 0), pady=4)
            if browse:
                ttk.Button(tail, text="浏览…", width=8, command=browse).pack(side="left")
            if hint:
                ttk.Label(tail, text=hint, style="Muted.TLabel").pack(side="left", padx=(8, 0))

    def _combo(self, box, row, label, var, values):
        ttk.Label(box, text=label).grid(row=row, column=0, sticky="w", padx=(0, 8), pady=3)
        ttk.Combobox(box, textvariable=var, values=[OPT_DEFAULT] + values, state="readonly", width=16).grid(
            row=row, column=1, sticky="w", pady=3,
        )

    def _pick_file(self, var: tk.StringVar, filetypes=None) -> None:
        path = filedialog.askopenfilename(title="选择文件", filetypes=filetypes or [("所有文件", "*.*")])
        if path:
            var.set(path)

    def _pick_dir(self, var: tk.StringVar) -> None:
        path = filedialog.askdirectory(title="选择目录")
        if path:
            var.set(path)

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

    def _clear_dylib(self) -> None:
        self.list_dylibs.delete(0, "end")
        self.custom_dylibs.clear()

    # ------------------------------------------------------------------ #
    # 日志
    # ------------------------------------------------------------------ #
    def _set_status(self, text: str, kind: str = "ok") -> None:
        """状态文字 + 颜色：ok 绿 / run 蓝 / err 红。"""
        self.v_status.set(text)
        self.lbl_status.configure(foreground={"ok": OK, "run": ACCENT, "err": DANGER}.get(kind, OK))

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
                elif kind == "status":
                    text, color = payload  # type: ignore[misc]
                    self._set_status(str(text), str(color))
                elif kind in ("info", "devices"):
                    self._render(kind, str(payload))
                elif kind == "ask":
                    self.answer_q.put(self._prompt_answer(payload))
                elif kind == "done":
                    task, code = payload  # type: ignore[misc]
                    self._finish(str(task), int(code))
        except queue.Empty:
            pass
        except Exception:
            self._append(traceback.format_exc(), "err")
        self.root.after(80, self._poll)

    _SIGN_GROUP = frozenset({"sign", "modify", "inject", "inject-list"})

    def _start(self, argv: list[str], task: str, quiet: bool = False) -> None:
        """quiet=True 用于自动刷新：不弹「请稍候」、也不把命令行回显到日志里。"""
        if task in self._running_tasks:
            if not quiet:
                messagebox.showinfo("请稍候", f"「{task}」任务正在进行，请等它结束。")
            return
        self._running_tasks.add(task)
        self._apply_busy_state()
        self._set_status("运行中…", "run")
        if not quiet:
            self._append(f"\n$ {_format_argv(argv)}\n")
        threading.Thread(target=self._work, args=(argv, task), daemon=True).start()

    def _apply_busy_state(self) -> None:
        """按正在跑的任务只禁用对应按钮：安装只冻安装按钮，签名类只冻开始执行。
        两者可并发——安装跑着时点「开始执行」照样能签。"""
        if self.install_button is not None:
            self.install_button.configure(
                state="disabled" if "install" in self._running_tasks else "normal")
        sign_running = bool(self._running_tasks & self._SIGN_GROUP)
        for btn in self.action_buttons:
            btn.configure(state="disabled" if sign_running else "normal")

    def _work(self, argv: list[str], task: str) -> None:
        code, text = 0, ""
        out = io.StringIO()      # 捕获任务里只拿 stdout 当数据（纯 JSON）
        err = io.StringIO()
        try:
            if task in CAPTURE_TASKS:
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    code = cli_mod.main(argv)
                text = out.getvalue()
            else:
                stream = _Stream(self.q)
                with contextlib.redirect_stdout(stream), contextlib.redirect_stderr(stream):
                    code = cli_mod.main(argv)
        except SystemExit as exc:  # cli 里用 SystemExit 报输入错误
            code = exc.code if isinstance(exc.code, int) else (1 if exc.code else 0)
        except BaseException:
            code = 1
            text += "\n" + traceback.format_exc()
        if err.getvalue().strip():
            self.q.put(("log", err.getvalue()))
        if text:
            self.q.put((task, text))
        self.q.put(("done", (task, code)))

    def _finish(self, task: str, code: int) -> None:
        self._running_tasks.discard(task)
        self._apply_busy_state()
        if task in ("inject", "modify", "sign", "install"):
            self._refresh_devices_silent()   # 跑完顺手静默刷新（可能刚插上手机）
        if code == 0:
            self._set_status("完成")
            if task == "install":
                messagebox.showinfo("完成", "安装完成。")
                return
            if task == "export":
                messagebox.showinfo("完成", "源码已导出到本地（详见日志）。")
                return
            if task in ("inject", "modify", "sign"):
                # 产物刚生成：把路径自动填进「安装到设备」的「安装包」栏，
                # 顺手刷新摘要，签完名下一秒就能直接点「安装到设备」，不用手动选包。
                self.v_install_ipa.set(self._install_target())
                self._refresh_install_summary()
                messagebox.showinfo("完成", "处理完成。")
            return
        if code == 3:          # 用户在「已有同名 App」那步选了取消
            self._set_status("已取消")
            messagebox.showinfo("已取消", "已取消安装")
            return
        self._set_status(f"失败（退出码 {code}）", "err")
        self._append(f"任务失败，退出码 {code}\n", "err")
        if task not in CAPTURE_TASKS:
            messagebox.showerror("执行失败", f"任务未能完成，退出码 {code}。\n详情见下方日志。")

    def _render(self, kind: str, text: str) -> None:
        data = self._parse_json(text)
        if data is None:
            # 失败时 cli 打的是人话不是 JSON：照原样贴到日志里
            if kind == "devices":
                # 自动刷新会反复失败，同一段报错只贴一次，别刷屏
                if getattr(self, "_device_err", None) != text:
                    self._device_err = text
                    self._append(text)
                self.v_device_summary.set("→ 未识别到设备（原因见下方日志）")
                return
            self._append(text)
            return
        if kind == "info":
            self._render_info(data)
        else:
            self._render_devices(data)

    @staticmethod
    def _parse_json(text: str):
        """解析 JSON；容忍前后被状态/清理信息污染（如 `--json` 后跟的
        “清理临时文件…”）。先整体解析，失败再按括号匹配抠出 JSON 对象。"""
        try:
            return json.loads(text)
        except Exception:
            pass
        start = text.find("{")
        if start == -1:
            return None
        depth = 0
        in_str = False
        esc = False
        for i in range(start, len(text)):
            c = text[i]
            if in_str:
                if esc:
                    esc = False
                elif c == "\\":
                    esc = True
                elif c == '"':
                    in_str = False
            else:
                if c == '"':
                    in_str = True
                elif c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        try:
                            return json.loads(text[start:i + 1])
                        except Exception:
                            return None
        return None

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
            f"\n已读取：{_txt(data.get('bundle_id'))} / {_txt(data.get('display_name'))}"
            f"（内嵌 bundle {len(nested)}，已注入 dylib {len(injected)}）\n"
        )

        # 顺手把当前值填进「改 ID / 名称」页，少打一次字
        if data.get("bundle_id") and not self.v_bundle_id.get().strip():
            self.v_bundle_id.set(data["bundle_id"])
        if data.get("display_name") and not self.v_name.get().strip():
            self.v_name.set(data["display_name"])

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
        if self.v_zip_level.get().strip() not in ("", "auto"):
            _add(argv, "--zip-level", self.v_zip_level.get().strip())
        _flag(argv, "--hardened-runtime", self.v_hardened.get())
        _flag(argv, "--dry-run", self.v_dry_run.get())
        _flag(argv, "-v", self.v_verbose.get())
        return argv

    def _info_argv(self) -> list[str]:
        return ["info", self.v_input.get().strip(), "--json"]

    def _modify_argv(self) -> list[str] | None:
        src = self.v_input.get().strip()
        if not src:
            messagebox.showwarning("缺少输入", "请先选择 IPA 文件或已解包目录。")
            return None
        if not self.v_bundle_id.get().strip() and not self.v_name.get().strip():
            messagebox.showwarning("缺少参数", "至少要填 Bundle Identifier 或显示名称。")
            return None
        argv = ["modify", src]
        _add(argv, "-i", self.v_bundle_id.get())
        _add(argv, "-n", self.v_name.get())
        _add(argv, "--bundle-name", self.v_bundle_name.get())
        return argv + self._common_args()

    def _inject_argv(self) -> list[str] | None:
        src = self.v_input.get().strip()
        if not src:
            messagebox.showwarning("缺少输入", "请先选择 IPA 文件或已解包目录。")
            return None
        argv = ["inject", src]
        for path in self.custom_dylibs:
            argv += ["--dylib", path]
        argv += self._common_args()

        if not self.custom_dylibs:
            messagebox.showwarning("没有要注入的东西", "请先点「添加…」选一个 dylib。")
            return None
        return argv

    def _sign_argv(self) -> list[str] | None:
        """只重新打包 + 签名：不改 ID、不注入。"""
        src = self.v_input.get().strip()
        if not src:
            messagebox.showwarning("缺少输入", "请先选择 IPA 文件或已解包目录。")
            return None
        return ["sign", src] + self._common_args()

    # ------------------------------------------------------------------ #
    # 动作
    # ------------------------------------------------------------------ #
    def _load_info(self) -> None:
        src = self.v_input.get().strip()
        if not src:
            return
        self._start(self._info_argv(), "info")

    def _load_devices(self, quiet: bool = False) -> None:
        """读一遍连着的设备填进下拉（走 devices 子命令的 JSON 输出）。"""
        self._start(["devices", "--json"], "devices", quiet=quiet)

    def _auto_refresh_devices(self) -> None:
        """空闲时定时静默刷新：插上 / 拔掉手机都能自动反映，不用手点「刷新设备」。"""
        if not self._running_tasks:
            self._refresh_devices_silent()
        self.root.after(DEVICE_POLL_MS, self._auto_refresh_devices)

    def _refresh_devices_silent(self) -> None:
        """后台静默读设备：只更新下拉，不占 busy、不动按钮、不闪「运行中…」。"""
        def _run():
            try:
                buf = io.StringIO()
                with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
                    cli_mod.main(["devices", "--json"])
                text = buf.getvalue()
            except BaseException:
                text = traceback.format_exc()
            try:
                data = json.loads(text)
            except Exception:
                data = None
            self.root.after(0, self._apply_devices, data, text)
        threading.Thread(target=_run, daemon=True).start()

    def _apply_devices(self, data, text) -> None:
        if data is None:
            if getattr(self, "_device_err", None) != text:   # 同一段报错只贴一次
                self._device_err = text
                self._append(text)
            return
        self._render_devices(data)

    def _render_devices(self, data: dict) -> None:
        devices = data.get("devices") or []
        chosen = self._selected_udid()          # 刷新前用户选的是哪台
        self._device_texts = ["自动选择"]
        self._device_keys = [""]
        for item in devices:
            udid = str(item.get("udid") or "")
            if not udid:
                continue
            self._device_texts.append(str(item.get("label") or udid))
            self._device_keys.append(udid)
        if hasattr(self, "cb_device"):
            self.cb_device.configure(values=self._device_texts)
        # 选中的设备还在就留着；否则只连一台就自动选它
        if chosen not in self._device_keys:
            chosen = self._device_keys[1] if len(self._device_keys) == 2 else ""
        self.v_device.set(self._device_texts[self._device_keys.index(chosen)])
        self._refresh_install_summary()

        signature = tuple(self._device_keys)
        changed = signature != getattr(self, "_device_sig", None)
        self._device_sig = signature
        if not changed:
            return          # 列表没变就别刷日志（每 30 秒一次会刷屏）

        self._device_err = ""
        backend = str(data.get("backend") or "?")
        if devices:
            self._append(f"\n设备后端: {backend}，认到 {len(devices)} 台\n")
            self._set_status(f"已认到 {len(devices)} 台设备")
        else:
            self._append(f"\n无设备连接（后端 {backend}）。手机上解锁后点「信任」；")
            self._set_status("无设备连接", "err")

    def _refresh_install_summary(self) -> None:
        """摘要行：装到哪台 + 装哪个包，点「安装到设备」之前就能看清会发生什么。"""
        udid = self._selected_udid()
        where = f"装到 UDID …{udid[-6:]}" if udid else "设备：自动选择"
        target = self._install_target()
        if not target:
            what = "安装包：空（请选择安装包）"
        else:
            name = os.path.basename(target)
            if not self.v_install_ipa.get().strip():
                if self.v_inplace.get():
                    name += "（就地覆盖输入）"
                elif self.v_output.get().strip():
                    name += "（取「输出」）"
                else:
                    name += "（输出留空：默认生成在输入包旁边）"
            if not os.path.isfile(target):
                name += "  ← 文件不存在"
            what = f"安装包：{name}"
        self.v_device_summary.set(f"→ {where}；{what}")

    def _selected_udid(self) -> str:
        text = self.v_device.get()
        if text in self._device_texts:
            return self._device_keys[self._device_texts.index(text)]
        return ""

    def _default_output_path(self) -> str:
        """「输出」留空时命令行实际会生成的路径（规则和 cli._output_path 保持一致）。"""
        src = self.v_input.get().strip()
        if not src:
            return ""
        src = os.path.abspath(src)
        stem = os.path.splitext(os.path.basename(os.path.normpath(src)))[0]
        if self.custom_dylibs:
            suffix = "-injected.ipa"
        elif self.v_bundle_id.get().strip() or self.v_name.get().strip():
            suffix = "-modified.ipa"
        else:
            suffix = "-signed.ipa"
        return os.path.join(os.path.dirname(src), f"{stem}{suffix}")

    def _install_target(self) -> str:
        """装 / 交付哪个包：填了「安装包」就用它；留空 = 输出（就地覆盖时 = 输入）。"""
        chosen = self.v_install_ipa.get().strip()
        if chosen:
            return chosen
        if self.v_inplace.get():
            return self.v_input.get().strip()
        return self.v_output.get().strip() or self._default_output_path()

    def _reveal_output(self) -> None:
        """在资源管理器 / 访达里定位产物（顺带选中这个文件），方便拖给爱思之类。"""
        target = self._install_target()
        if not target or not os.path.exists(target):
            messagebox.showwarning("找不到文件", "先「开始执行」生成产物，或把「输出」指到已有的 IPA。")
            return
        path = os.path.abspath(target)      # 注意顺序：空串 abspath 出来是当前目录
        if os.name == "nt":
            subprocess.Popen(["explorer", "/select,", path])
        elif sys.platform == "darwin":
            subprocess.Popen(["open", "-R", path])
        else:
            subprocess.Popen(["xdg-open", os.path.dirname(path)])
        self._append(f"[定位] {path}\n")

    def _copy_output_path(self) -> None:
        """把产物路径复制到剪贴板（有的工具只能粘贴路径，不能拖文件）。"""
        path = self._install_target()
        if not path:
            messagebox.showwarning("没有可复制的路径", "先选一个「安装包」，或在上面填好输入 / 输出。")
            return
        self.root.clipboard_clear()
        self.root.clipboard_append(path)
        self._append(f"[复制] 路径已复制：{path}\n")

    def _pick_install_ipa(self) -> None:
        path = filedialog.askopenfilename(
            title="选择要安装到设备的 IPA",
            filetypes=[("iOS 应用包", "*.ipa"), ("所有文件", "*.*")],
        )
        if path:
            self.v_install_ipa.set(path)

    def _clear_install_ipa(self) -> None:
        self.v_install_ipa.set("")      # 清空 = 回到「自动用输出」

    def _ask_confirm(self, message: str) -> bool | None:
        """工作线程用：问「要不要卸载重装」。返回 True/False，None = 用户取消。"""
        self.q.put(("ask", ("confirm", message)))
        try:
            answer = self.answer_q.get(timeout=600)
        except queue.Empty:
            return None
        return {"uninstall": True, "install": False}.get(answer)

    def _prompt_answer(self, payload) -> str:
        """界面线程用：弹「设备上已有同名 App」的三选一，把答案交回工作线程。"""
        message = payload[1] if isinstance(payload, tuple) and len(payload) > 1 else str(payload)
        answer = messagebox.askyesnocancel(
            "设备上已有同名 App",
            f"{message}\n\n是>>卸载重装\n否>>覆盖安装\n",
        )
        return {True: "uninstall", False: "install"}.get(answer, "")

    def _install_to_device(self) -> None:
        target = self._install_target()
        if not target:
            messagebox.showwarning("没有可安装的 IPA", "先选一个「安装包」")
            return
        if not os.path.isfile(target):
            messagebox.showwarning(
                "找不到文件",
                f"没找到 {target}\n",
            )
            return
        argv = ["install", target]
        udid = self._selected_udid()
        if udid:
            argv += ["--udid", udid]
        self._start(argv, "install")

    def _list_injected(self) -> None:
        """核对产物：优先读输出文件，没有产物时才回退到输入包（就地修改时两者相同）。"""
        src = self.v_input.get().strip() if self.v_inplace.get() else self.v_output.get().strip()
        if not src or not os.path.isfile(src):
            src = self.v_input.get().strip()
        if not src:
            messagebox.showwarning("缺少输入", "请先选择 IPA 文件或已解包目录。")
            return
        self._append(f"[核对] {src}\n")
        self._start(["inject", src, "--list"], "inject-list")

    def _run_current(self, dry_run: bool) -> None:
        """
        「开始执行」按钮（第一个页签内）：按上面填的内容自动决定做什么 ——
          列表里有 dylib  → 注入（+ 签名）
          填了 ID / 名称  → 改 ID / 名称（+ 签名）
          什么都没填      → 只重新打包 + 签名
        """
        tag = "[预览]" if dry_run else "[执行]"
        fill_ident = bool(self.v_bundle_id.get().strip() or self.v_name.get().strip())
        if self.custom_dylibs:
            self._append(f"{tag} 注入 {len(self.custom_dylibs)} 个 dylib + 签名\n")
            if fill_ident:
                self._append(f"{tag} ID / 名称已填但本次不改（要改名请先清空 dylib 列表）\n")
            self._run_inject(dry_run)
            return
        if fill_ident:
            self._append(f"{tag} 改 ID / 名称 + 签名\n")
            self._run_modify(dry_run)
            return
        self._append(f"{tag} 不改 ID、不注入，只重新打包 + 签名\n")
        self._run_sign(dry_run)

    def _run_modify(self, dry_run: bool = False) -> None:
        self._start_task(self._modify_argv(), "modify", dry_run)

    def _run_inject(self, dry_run: bool = False) -> None:
        self._start_task(self._inject_argv(), "inject", dry_run)

    def _run_sign(self, dry_run: bool = False) -> None:
        self._start_task(self._sign_argv(), "sign", dry_run)

    def _start_task(self, argv: list[str] | None, task: str, dry_run: bool) -> None:
        if argv is None:
            return
        if dry_run and "--dry-run" not in argv:
            argv.append("--dry-run")
        self._set_text(self.log, "")
        self._start(argv, task)

    # ------------------------------------------------------------------ #
    def run(self) -> None:
        # 关窗时兜底存一次（防抖可能还没触发）
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)
        self.root.mainloop()

    def _on_close(self) -> None:
        if self._save_job:
            try:
                self.root.after_cancel(self._save_job)
            except Exception:
                pass
        self._write_settings()
        self.root.destroy()


    # ================================================================== #
    # GitHub 导入 / Codemagic 构建 / 编译打包（逻辑见 cloud_build.py）
    # ================================================================== #
    def _clog(self, msg: str) -> None:
        """线程安全的日志：后台线程把消息丢进队列，主循环 _poll 再写进日志框。"""
        self.q.put(("log", (msg.rstrip("\n") + "\n")))

    def _popup_geometry(self, win, w, h) -> None:
        """弹窗跟随主窗口位置（居中于主窗口），而不是默认落到屏幕左上角。"""
        self.root.update_idletasks()
        mx, my = self.root.winfo_rootx(), self.root.winfo_rooty()
        mw, mh = self.root.winfo_width(), self.root.winfo_height()
        x = mx + max(0, (mw - w) // 2)
        y = my + max(0, (mh - h) // 2)
        win.geometry(f"{w}x{h}+{x}+{y}")

    def _restore_gh_config(self) -> None:
        cfg = cloud_mod.load_config()
        if not cfg:
            return
        self.v_gh_token.set(cfg.get("github_token", ""))
        self.v_cm_token.set(cfg.get("cm_token", ""))
        self.v_owner.set(cfg.get("owner", cloud_mod.OWNER))
        self.v_repo.set(cfg.get("repo", cloud_mod.REPO))
        self.v_branch.set(cfg.get("branch", "main"))
        self.v_local.set(cfg.get("local", r"d:\Microsoft VS Code\qnet\ios_demo"))
        self.v_target.set(cfg.get("target", ""))
        self.v_sign_mode.set(cfg.get("sign_mode", "ad-hoc(付费账号)"))
        self.v_apple_team_id.set(cfg.get("apple_team_id", ""))
        self.v_auto_create.set(cfg.get("auto_create", False))
        self.v_visibility.set(cfg.get("visibility", "公开"))
        self.v_workflow_file.set(cfg.get("workflow_file", "build-tweak.yml"))
        self.v_dylib_path.set(cfg.get("dylib_path", ""))
        self.v_ipa_path.set(cfg.get("ipa_path", ""))

    def _save_gh_config(self) -> None:
        cloud_mod.save_config({
            "github_token": self.v_gh_token.get(),
            "cm_token": self.v_cm_token.get(),
            "owner": self.v_owner.get(),
            "repo": self.v_repo.get(),
            "branch": self.v_branch.get(),
            "local": self.v_local.get(),
            "target": self.v_target.get(),
            "sign_mode": self.v_sign_mode.get(),
            "apple_team_id": self.v_apple_team_id.get(),
            "auto_create": self.v_auto_create.get(),
            "visibility": self.v_visibility.get(),
            "workflow_file": self.v_workflow_file.get(),
            "dylib_path": self.v_dylib_path.get(),
            "ipa_path": self.v_ipa_path.get(),
        })

    def _build_github_tab(self) -> ttk.Frame:
        outer, page = self._make_scroll(self.page_area)
        f = ttk.Frame(page)
        f.grid(row=0, column=0, sticky="ew")
        f.columnconfigure(1, weight=1)

        def add_row(i, lab, var, secret=False):
            ttk.Label(f, text=lab, style="Page.TLabel").grid(row=i, column=0, sticky="w", pady=3)
            if lab.startswith("仓库名"):
                cb = ttk.Combobox(f, textvariable=var, width=38, state="readonly")
                cb.grid(row=i, column=1, sticky="ew", pady=3, padx=5)
                cb.bind("<<ComboboxSelected>>", lambda _e: self._gh_on_repo_pick())
                self.repo_cb = cb
                ttk.Button(f, text="刷新仓库", command=self._gh_list_repos).grid(row=i, column=2, padx=3)
                if self.v_gh_token.get().strip():
                    self.root.after(500, self._gh_list_repos)
            else:
                ent = ttk.Entry(f, textvariable=var, show=("*" if secret else ""), width=40)
                ent.grid(row=i, column=1, sticky="ew", pady=3, padx=5)
                if lab.startswith("GitHub Token"):
                    ttk.Button(f, text="生成 Token", command=self._gh_show_token_help).grid(
                        row=i, column=2, padx=3)
                    ttk.Button(f, text="预填创建页",
                                command=lambda: webbrowser.open(
                                    "https://github.com/settings/tokens/new"
                                    "?description=IPATool-importer"
                                    "&scopes=repo,workflow&expiration=90")
                                ).grid(row=i, column=3, padx=3)
                elif lab.startswith("本地文件夹"):
                    ttk.Button(f, text="浏览", command=self._gh_browse).grid(row=i, column=2, padx=3)

        rows = [
            ("GitHub Token:", self.v_gh_token, True),
            ("仓库所有者:", self.v_owner, False),
            ("仓库名:", self.v_repo, False),
            ("分支:", self.v_branch, False),
            ("本地文件夹:", self.v_local, False),
            ("仓库内目标路径:", self.v_target, False),
        ]
        for i, (lab, var, secret) in enumerate(rows):
            add_row(i, lab, var, secret)

        vis_row = len(rows)
        ttk.Label(f, text="可见性(仅创建时生效):", style="Page.TLabel").grid(
            row=vis_row, column=0, sticky="w", pady=2)
        ttk.Combobox(f, textvariable=self.v_visibility, width=12, state="readonly",
                     values=["公开", "私有"]).grid(row=vis_row, column=1, sticky="w", padx=5)
        ttk.Checkbutton(f, text="仓库不存在时自动创建", variable=self.v_auto_create).grid(
            row=vis_row, column=1, sticky="w", padx=(150, 0), pady=2)
        note_row = vis_row + 1
        ttk.Label(f, text="注意: codemagic.yaml / project.yml 必须在仓库根目录, 否则云构建找不到",
                  foreground="red").grid(row=note_row, column=0, columnspan=3, sticky="w", pady=(4, 6))

        bf = ttk.Frame(f)
        bf.grid(row=note_row + 1, column=0, columnspan=3, pady=6)
        ttk.Button(bf, text="导入到 GitHub", command=self._gh_do_import).pack(side="left", padx=5)
        ttk.Button(bf, text="导出 ZIP(手动上传)", command=self._gh_export_zip).pack(side="left", padx=5)
        return outer

    def _gh_list_repos(self):
        token = self.v_gh_token.get().strip()
        if not token:
            messagebox.showerror("错误", "请先填写 GitHub Token")
            return
        self._clog("正在拉取仓库列表...")

        def work():
            try:
                _, j = cloud_mod.api_call(
                    "GET", "https://api.github.com/user/repos?per_page=100&affiliation=owner", token)
                repos = j if isinstance(j, list) else j.get("repositories", [])
                names, full = [], {}
                for r in repos:
                    n = r.get("name")
                    if n:
                        names.append(n)
                        full[n] = r.get("full_name", n)
                if not names:
                    self._clog("未获取到任何仓库(确认 Token 有 repo 权限, 且账号下确有仓库)")
                    return
                self.root.after(0, lambda: self._gh_set_repo_options(names, full))
                self._clog(f"已拉取 {len(names)} 个仓库, 可在『仓库名』下拉选择")
            except RuntimeError as e:
                self._clog("❌ 拉取仓库失败: " + str(e))

        threading.Thread(target=work, daemon=True).start()

    def _gh_set_repo_options(self, names, full):
        self._repo_full = full
        if self.repo_cb is not None:
            self.repo_cb["values"] = names
        if self.repo_cb2 is not None:
            self.repo_cb2["values"] = names
        if names and not self.v_repo.get():
            self.v_repo.set(names[0])
            self._gh_on_repo_pick()

    def _gh_on_repo_pick(self):
        name = self.v_repo.get()
        full = self._repo_full.get(name, "")
        if "/" in full:
            self.v_owner.set(full.split("/", 1)[0])
        if self.wf_cb is not None:
            self.root.after(0, self._gh_list_workflows)


    def _gh_list_workflows(self):
        token = self.v_gh_token.get().strip()
        owner, repo = self.v_owner.get().strip(), self.v_repo.get().strip()
        if not (token and owner and repo):
            return
        self._clog(f"拉取 {owner}/{repo} 的 workflow 列表...")

        def work():
            try:
                _, j = cloud_mod.api_call(
                    "GET", f"https://api.github.com/repos/{owner}/{repo}/actions/workflows", token)
                wfs = j.get("workflows", []) if isinstance(j, dict) else j
                files = [w.get("path", "").split("/")[-1]
                         for w in wfs if w.get("path", "").endswith(".yml")]
                if files:
                    self.root.after(0, lambda: self._gh_set_wf_options(files))
                    self._clog(f"发现 {len(files)} 个 workflow: {', '.join(files)}")
                else:
                    self._clog("未找到 workflow 文件(仓库根目录需有 *.yml)")
            except RuntimeError as e:
                self._clog("❌ 拉取 workflow 失败: " + str(e))

        threading.Thread(target=work, daemon=True).start()

    def _gh_set_wf_options(self, files):
        if self.wf_cb is not None:
            self.wf_cb["values"] = files
        if files and not self.v_workflow_file.get():
            self.v_workflow_file.set(
                "build-tweak.yml" if "build-tweak.yml" in files else files[0])

    def _gh_repo_info_text(self, repo):
        token = self.v_gh_token.get().strip()
        owner = self.v_owner.get().strip()
        try:
            _, jb = cloud_mod.api_call(
                "GET", f"https://api.github.com/repos/{owner}/{repo}/branches?per_page=100", token)
            branches = [b.get("name", "") for b in (jb if isinstance(jb, list) else [])]
        except Exception as e:
            branches = [f"(获取失败: {e})"]
        try:
            _, jw = cloud_mod.api_call(
                "GET", f"https://api.github.com/repos/{owner}/{repo}/actions/workflows", token)
            wfs = jw.get("workflows", []) if isinstance(jw, dict) else jw
            wf_names = [w.get("name", "") for w in wfs]
        except Exception as e:
            wf_names = [f"(获取失败: {e})"]
        try:
            _, jc = cloud_mod.api_call(
                "GET", f"https://api.github.com/repos/{owner}/{repo}/contents/", token)
            contents = [c.get("name", "") for c in (jc if isinstance(jc, list) else [])]
        except Exception as e:
            contents = [f"(获取失败: {e})"]
        try:
            _, ja = cloud_mod.api_call(
                "GET", f"https://api.github.com/repos/{owner}/{repo}/actions/runs?per_page=5", token)
            runs = ja.get("workflow_runs", []) if isinstance(ja, dict) else []
            run_lines = [f"{r.get('display_title','')[:30]} - {r.get('status')}/{r.get('conclusion')}"
                         for r in runs]
        except Exception as e:
            run_lines = [f"(获取失败: {e})"]
        return (f"仓库: {owner}/{repo}\n"
                f"分支({len(branches)}): {', '.join(branches) or '无'}\n"
                f"workflow({len(wf_names)}): {', '.join(wf_names) or '无'}\n"
                f"根目录文件: {', '.join(contents) or '无'}\n"
                f"最近 Actions:\n" + ("\n".join(run_lines) or "  无"))

    def _gh_refresh_repo_info(self):
        token = self.v_gh_token.get().strip()
        owner, repo = self.v_owner.get().strip(), self.v_repo.get().strip()
        if not (token and owner and repo):
            messagebox.showerror("错误", "请先填写 Token / 所有者 / 仓库名")
            return
        self._clog(f"刷新仓库信息: {owner}/{repo}...")

        def work():
            text = self._gh_repo_info_text(repo)
            self.root.after(0, lambda: self._gh_show_repo_info_win(text))

        threading.Thread(target=work, daemon=True).start()

    def _gh_show_repo_info_win(self, text):
        win = tk.Toplevel(self.root)
        win.title("仓库信息")
        win.transient(self.root)
        self._popup_geometry(win, 560, 360)
        txt = tk.Text(win, wrap="word", font=(FONT, 10))
        txt.insert("1.0", text)
        txt.pack(fill="both", expand=True, padx=8, pady=8)
        ttk.Button(win, text="关闭", command=win.destroy).pack(pady=(0, 8))

    def _gh_browse(self):
        d = filedialog.askdirectory(initialdir=self.v_local.get() or os.path.expanduser("~"))
        if d:
            self.v_local.set(d)

    def _gh_collect_files(self):
        local = self.v_local.get().strip()
        if not local:
            return None
        if not os.path.isdir(local):
            messagebox.showerror("错误", f"本地文件夹不存在: {local}")
            return None
        out = []
        skipped = []
        skip_dirs = {".git", "__pycache__"}
        skip_dir_prefixes = ("sim_",)   # 仿真测试数据目录，仓库不需要
        skip_file_prefixes = ("sim",)   # 仿真运行日志（如 simrun2.txt），仓库不需要
        skip_files = {"importer_config.json"}   # 含 GitHub / Codemagic Token，禁止上传
        # 构建产物 / 大二进制：GitHub Contents API 单文件上限 ~1MB，且仓库不需要
        # 证书 / 私钥 / 描述文件：严禁上传（防泄露开发证书）
        skip_ext = {".ipa", ".zip", ".exe", ".dylib", ".bin", ".pyc", ".log",
                    ".p12", ".mobileprovision", ".provisionprofile",
                    ".cer", ".crt", ".pem", ".key", ".pfx"}
        MAX_BYTES = 1 * 1024 * 1024
        for root, dirs, fns in os.walk(local):
            dirs[:] = [d for d in dirs
                       if d not in skip_dirs
                       and not d.startswith(skip_dir_prefixes)]
            for fn in fns:
                if fn in skip_files or fn.lower().endswith(tuple(skip_ext)) \
                        or fn.lower().startswith(skip_file_prefixes):
                    skipped.append((fn, "忽略类型"))
                    continue
                full = os.path.join(root, fn)
                try:
                    if os.path.getsize(full) > MAX_BYTES:
                        skipped.append((fn, "超 1MB"))
                        continue
                except OSError:
                    continue
                rel = os.path.relpath(full, local).replace(os.sep, "/")
                out.append((rel, full))
        for fn, why in skipped:
            self._clog(f"跳过 {fn}（{why}，不上传）")
        if not out:
            messagebox.showerror("错误", f"本地文件夹没有任何文件: {local}")
            return None
        return out

    def _gh_do_import(self):
        self._save_gh_config()
        files = self._gh_collect_files()
        if files is None:
            return
        token = self.v_gh_token.get().strip()
        owner, repo = self.v_owner.get().strip(), self.v_repo.get().strip()
        branch = self.v_branch.get().strip() or "main"
        target = self.v_target.get().strip()
        visibility = self.v_visibility.get().strip()
        auto_create = self.v_auto_create.get()
        if not (token and owner and repo):
            messagebox.showerror("错误", "请填写 GitHub Token / 所有者 / 仓库名")
            return
        if not target:
            target = "/"
        self._clog(f"开始导入 {len(files)} 个文件 到 {owner}/{repo}@{branch}:{target}")

        def work():
            try:
                msg, created = cloud_mod.import_to_github(
                    token, owner, repo, branch, files, target,
                    visibility=visibility, auto_create=auto_create)
                self._clog(msg)
                if created:
                    self.root.after(0, self._gh_list_repos)
            except RuntimeError as e:
                self._clog("❌ 导入失败: " + str(e))

        threading.Thread(target=work, daemon=True).start()

    def _gh_export_zip(self):
        files = self._gh_collect_files()
        if files is None:
            return
        dst = filedialog.asksaveasfilename(
            defaultextension=".zip", filetypes=[("ZIP", "*.zip")],
            initialfile="ios_source.zip")
        if not dst:
            return
        import zipfile
        with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
            for rel, full in files:
                z.write(full, rel)
        self._clog(f"已导出 {len(files)} 个文件 到 {dst}")
        messagebox.showinfo("完成", f"已导出 {len(files)} 个文件:\n{dst}")

    def _gh_show_token_help(self):
        win = tk.Toplevel(self.root)
        win.title("如何生成 GitHub Token")
        win.transient(self.root)
        self._popup_geometry(win, 580, 320)
        txt = tk.Text(win, wrap="word", font=(FONT, 10))
        txt.insert("1.0", (
            "1. 打开 https://github.com/settings/tokens/new\n"
            "   （也可点旁边的『预填创建页』按钮，已自动勾好权限与 90 天有效期）\n"
            "2. Note 随便填，例如 IPATool-importer\n"
            "3. 勾选权限：repo（全部，含 workflow 勾上，否则无法推 .yml）\n"
            "4. 有效期选 90 天 或自定义\n"
            "5. 拉到底点 Generate token，复制那一串 ghp_... 粘贴到『GitHub Token』\n"
            "6. 仓库不存在时勾『自动创建』并选可见性；存在则直接导入\n"
            "7. 注意：根目录必须放 codemagic.yaml / project.yml 才能云构建")
        )
        txt.pack(fill="both", expand=True, padx=8, pady=8)
        ttk.Button(win, text="关闭", command=win.destroy).pack(pady=(0, 8))


    def _build_codemagic_tab(self) -> ttk.Frame:
        outer, page = self._make_scroll(self.page_area)
        f = ttk.Frame(page)
        f.grid(row=0, column=0, sticky="ew")
        f.columnconfigure(1, weight=1)

        ttk.Label(f, text="Codemagic Token:", style="Page.TLabel").grid(row=0, column=0, sticky="w", pady=3)
        ttk.Entry(f, textvariable=self.v_cm_token, show="*", width=40).grid(row=0, column=1, sticky="ew", pady=3, padx=5)
        ttk.Button(f, text="诊断连通性", command=self._cm_diag_api).grid(row=0, column=2, padx=3)
        ttk.Button(f, text="帮助", command=self._cm_show_help).grid(row=0, column=3, padx=3)

        ttk.Label(f, text="应用(App):", style="Page.TLabel").grid(row=1, column=0, sticky="w", pady=3)
        cb = ttk.Combobox(f, textvariable=self.v_cm_app, width=38, state="readonly")
        cb.grid(row=1, column=1, sticky="ew", pady=3, padx=5)
        cb.bind("<<ComboboxSelected>>", lambda _e: self._cm_list_apps())
        self.cm_app_cb = cb
        ttk.Button(f, text="刷新应用", command=self._cm_list_apps).grid(row=1, column=2, padx=3)

        ttk.Label(f, text="分支:", style="Page.TLabel").grid(row=2, column=0, sticky="w", pady=3)
        self.cm_branch = tk.StringVar(value=cloud_mod.DEFAULT_CM_BRANCH)
        ttk.Combobox(f, textvariable=self.cm_branch, width=14, state="readonly",
                     values=["默认", "develop", "master"]).grid(row=2, column=1, sticky="w", padx=5)

        bf = ttk.Frame(f)
        bf.grid(row=3, column=0, columnspan=3, pady=8)
        ttk.Button(bf, text="开始构建", command=self._cm_start_build).pack(side="left", padx=6)
        ttk.Button(bf, text="打开控制台", command=self._cm_open_console).pack(side="left", padx=6)
        ttk.Button(bf, text="下载构建产物", command=self._cm_download_artifacts).pack(side="left", padx=6)
        return outer

    def _cm_list_apps(self):
        token = self.v_cm_token.get().strip()
        if not token:
            messagebox.showerror("错误", "请先填写 Codemagic Token")
            return
        self._clog("正在获取 Codemagic 应用列表...")

        def work():
            try:
                apps = cloud_mod.list_codemagic_apps(token)
                if not apps:
                    self._clog("未获取到任何应用(确认 Token 正确, 且账号下已有 App)")
                    return
                self.app_map = apps
                self.root.after(0, lambda: self._cm_set_app_options(list(apps.keys())))
                self._clog(f"已获取 {len(apps)} 个应用")
            except RuntimeError as e:
                self._clog("❌ 获取应用失败: " + str(e))

        threading.Thread(target=work, daemon=True).start()

    def _cm_set_app_options(self, names):
        if self.cm_app_cb is not None:
            self.cm_app_cb["values"] = names
        if names and not self.v_cm_app.get():
            self.v_cm_app.set(names[0])

    def _cm_start_build(self):
        token = self.v_cm_token.get().strip()
        app_name = self.v_cm_app.get().strip()
        if not token:
            messagebox.showerror("错误", "请先填写 Codemagic Token")
            return
        if not app_name:
            messagebox.showerror("错误", "请先刷新并选择一个应用")
            return
        app_id = self.app_map.get(app_name)
        if not app_id:
            messagebox.showerror("错误", "应用 ID 未找到, 请重新刷新应用列表")
            return
        branch = self.cm_branch.get().strip()
        branch = None if branch == "默认" else branch
        self._clog(f"启动构建: {app_name} (branch={branch or '默认'})")

        def work():
            try:
                build_id, url = cloud_mod.importer_start_codemagic_build(token, app_id, branch)
                self.last_build_id = build_id
                self._clog(f"构建已启动: {url}")
                self.root.after(0, lambda: self._cm_open_url(url))
                self.root.after(2000, self._cm_poll_build)
            except RuntimeError as e:
                self._clog("❌ 启动构建失败: " + str(e))

        threading.Thread(target=work, daemon=True).start()

    def _cm_open_url(self, url):
        if url:
            webbrowser.open(url)

    def _cm_poll_build(self):
        token = self.v_cm_token.get().strip()
        if not (token and self.last_build_id):
            return
        self._clog(f"查询构建状态: {self.last_build_id}")

        def work():
            try:
                status, finished, artifacts = cloud_mod.poll_codemagic_build(token, self.last_build_id)
                self.last_artifacts = artifacts
                if finished:
                    self._clog(f"构建结束: {status}")
                    if artifacts:
                        self._clog(f"产物: {', '.join(a.get('name', '') for a in artifacts)}")
                    else:
                        self._clog("构建完成但未返回产物(检查 workflow 是否配置 artifacts)")
                else:
                    self._clog(f"构建中({status}), 10 秒后重试...")
                    self.root.after(10000, self._cm_poll_build)
            except RuntimeError as e:
                self._clog("❌ 查询构建失败: " + str(e))

        threading.Thread(target=work, daemon=True).start()

    def _cm_open_console(self):
        if not self.last_build_id:
            messagebox.showinfo("提示", "还没有构建记录, 请先『开始构建』")
            return
        webbrowser.open(f"https://codemagic.io/app/build/{self.last_build_id}")

    def _cm_download_artifacts(self):
        token = self.v_cm_token.get().strip()
        if not (token and self.last_build_id):
            messagebox.showerror("错误", "请先构建并等待完成")
            return
        d = filedialog.askdirectory(title="选择下载目录")
        if not d:
            return
        self._clog("下载构建产物...")

        def work():
            try:
                saved = cloud_mod.download_codemagic_artifacts(token, self.last_build_id, d)
                self._clog(f"已下载 {len(saved)} 个文件 到 {d}" if saved
                           else "没有可下载的产物(构建可能未完成或未配置 artifacts)")
                if saved:
                    self.root.after(0, lambda: messagebox.showinfo("完成", f"已下载 {len(saved)} 个文件:\n{d}"))
            except RuntimeError as e:
                self._clog("❌ 下载失败: " + str(e))

        threading.Thread(target=work, daemon=True).start()

    def _cm_diag_api(self):
        token = self.v_cm_token.get().strip()
        if not token:
            messagebox.showerror("错误", "请先填写 Codemagic Token")
            return

        def work():
            try:
                import socket as _sk
                import ssl as _ssl
                host = "api.codemagic.io"
                ip = _sk.gethostbyname(host)
                ctx = _ssl.create_default_context()
                with _sk.create_connection((host, 443), timeout=8) as s, \
                        ctx.wrap_socket(s, server_hostname=host) as ss:
                    cipher = ss.cipher()
                self._clog(f"✅ 网络可达: {host} -> {ip}, TLS: {cipher[0] if cipher else 'n/a'}")
                code, _ = cloud_mod.api_call("GET", f"{cloud_mod.API_BASE}/builds?limit=1", token)
                self._clog(f"✅ API 鉴权成功 (HTTP {code})")
            except Exception as e:
                self._clog("❌ Codemagic 连通性/鉴权失败: " + str(e))

        threading.Thread(target=work, daemon=True).start()

    def _cm_show_help(self):
        win = tk.Toplevel(self.root)
        win.title("Codemagic 使用帮助")
        win.transient(self.root)
        self._popup_geometry(win, 600, 380)
        txt = tk.Text(win, wrap="word", font=(FONT, 10))
        txt.insert("1.0", (
            "1. 登录 https://codemagic.io , 右上角 User -> Personal Access Token 创建\n"
            "2. 粘贴到『Codemagic Token』, 点『诊断连通性』确认能连上 + 鉴权通过\n"
            "3. 点『刷新应用』, 选择要构建的 App(已接入 GitHub 仓库)\n"
            "4. 选分支, 点『开始构建』会自动开浏览器到构建控制台\n"
            "5. 构建完成后点『下载构建产物』, 选目录保存 dylib 等\n"
            "6. 若长期失败: 多半是网络/代理问题, 见 README 的代理说明\n"
            "7. 注意: 仓库根目录必须有 codemagic.yaml, 否则构建找不到 workflow")
        )
        txt.pack(fill="both", expand=True, padx=8, pady=8)
        ttk.Button(win, text="关闭", command=win.destroy).pack(pady=(0, 8))


    def _build_compile_tab(self) -> ttk.Frame:
        outer, page = self._make_scroll(self.page_area)
        f = ttk.Frame(page)
        f.grid(row=0, column=0, sticky="ew")
        f.columnconfigure(1, weight=1)

        ttk.Label(f, text="仓库:", style="Page.TLabel").grid(row=0, column=0, sticky="w", pady=3)
        cb = ttk.Combobox(f, textvariable=self.v_repo, width=34, state="readonly")
        cb.grid(row=0, column=1, sticky="ew", pady=3, padx=5)
        cb.bind("<<ComboboxSelected>>", lambda _e: self._gh_on_repo_pick())
        self.repo_cb2 = cb
        ttk.Button(f, text="刷新", command=self._gh_list_repos).grid(row=0, column=2, padx=3)
        ttk.Button(f, text="仓库信息", command=self._gh_refresh_repo_info).grid(row=0, column=3, padx=3)

        ttk.Label(f, text="所有者:", style="Page.TLabel").grid(row=1, column=0, sticky="w", pady=3)
        ttk.Entry(f, textvariable=self.v_owner, width=36).grid(row=1, column=1, sticky="ew", pady=3, padx=5)

        ttk.Label(f, text="分支:", style="Page.TLabel").grid(row=2, column=0, sticky="w", pady=3)
        ttk.Entry(f, textvariable=self.v_branch, width=36).grid(row=2, column=1, sticky="ew", pady=3, padx=5)

        ttk.Label(f, text="Workflow 文件名:", style="Page.TLabel").grid(row=3, column=0, sticky="w", pady=3)
        wf = ttk.Combobox(f, textvariable=self.v_workflow_file, width=34, state="readonly")
        wf.grid(row=3, column=1, sticky="ew", pady=3, padx=5)
        self.wf_cb = wf
        ttk.Button(f, text="刷新 Workflow", command=self._gh_list_workflows).grid(row=3, column=2, padx=3)

        info = tk.Label(f, textvariable=self._repo_info, wraplength=520,
                        foreground="blue", justify="left", font=(FONT, 9))
        info.grid(row=4, column=0, columnspan=4, sticky="w", pady=(4, 6))
        self._repo_info.trace_add("write", lambda *_a: info.configure(text=self._repo_info.get()))

        bf = ttk.Frame(f)
        bf.grid(row=5, column=0, columnspan=4, pady=6, sticky="w")
        ttk.Button(bf, text="A. 编译 dylib + 下载", command=self._cmp_start_actions_build).pack(side="left", padx=6)
        ttk.Button(bf, text="导入 GitHub", command=self._gh_do_import).pack(side="left", padx=6)
        ttk.Button(bf, text="下载 / 拾取 dylib", command=self._cmp_download_dylib).pack(side="left", padx=6)
        ttk.Button(bf, text="下载 / 拾取 IPA", command=self._cmp_download_ipa).pack(side="left", padx=6)

        return outer

    def _cmp_start_actions_build(self):
        token = self.v_gh_token.get().strip()
        owner, repo = self.v_owner.get().strip(), self.v_repo.get().strip()
        branch = self.v_branch.get().strip() or "main"
        wf = self.v_workflow_file.get().strip() or "build-tweak.yml"
        if not (token and owner and repo):
            messagebox.showerror("错误", "请填写 GitHub Token / 所有者 / 仓库名")
            return
        self._clog(f"触发 GitHub Actions: {owner}/{repo} {wf} @ {branch}")

        def work():
            try:
                run_id, url = cloud_mod.trigger_github_actions(token, owner, repo, wf, branch)
                self.last_run_id = run_id
                self._clog(f"已触发 Actions run: {run_id}\n{url}")
                self.root.after(0, lambda: webbrowser.open(url))
                self.root.after(3000, self._cmp_poll_actions_run)
            except RuntimeError as e:
                self._clog("❌ 触发 Actions 失败: " + str(e))

        threading.Thread(target=work, daemon=True).start()

    def _cmp_poll_actions_run(self):
        token = self.v_gh_token.get().strip()
        owner, repo = self.v_owner.get().strip(), self.v_repo.get().strip()
        if not (token and owner and repo and self.last_run_id):
            return
        self._clog(f"查询 Actions 状态: {self.last_run_id}")

        def work():
            try:
                status, conclusion = cloud_mod.get_actions_run_status(
                    token, owner, repo, self.last_run_id)
                if status == "completed":
                    self._clog(f"✅ Actions 完成: {conclusion}")
                else:
                    self._clog(f"⏳ Actions {status}, 10 秒后重试...")
                    self.root.after(10000, self._cmp_poll_actions_run)
            except RuntimeError as e:
                self._clog("❌ 查询 Actions 失败: " + str(e))

        threading.Thread(target=work, daemon=True).start()

    def _cmp_download_dylib_manual(self):
        path = filedialog.askopenfilename(
            title="选择本地 dylib 文件",
            filetypes=[("dylib", "*.dylib"), ("所有文件", "*.*")])
        if not path:
            return
        self.v_dylib_path.set(path)
        self._clog(f"已设置 dylib 路径: {path}")

    def _cmp_download_dylib(self):
        token = self.v_gh_token.get().strip()
        owner, repo = self.v_owner.get().strip(), self.v_repo.get().strip()
        branch = self.v_branch.get().strip() or "main"
        wf = self.v_workflow_file.get().strip() or "build-tweak.yml"
        if not (token and owner and repo):
            messagebox.showerror("错误", "请填写 GitHub Token / 所有者 / 仓库名")
            return
        d = filedialog.askdirectory(title="选择 Artifacts 解压目录")
        if not d:
            return
        self._clog("下载 Actions Artifacts (dylib) ...")

        def work():
            try:
                cloud_mod.download_actions_artifact(token, owner, repo, wf, branch, d, artifact_name=None)
                self._clog(f"已下载并解压 Artifacts 到: {d}")
                self.root.after(0, lambda: self._cmp_pick_dylib(d))
            except RuntimeError as e:
                self._clog("❌ 下载 Artifacts 失败: " + str(e))

        threading.Thread(target=work, daemon=True).start()

    def _cmp_pick_dylib(self, d):
        found = [os.path.join(dp, fn) for dp, _, fns in os.walk(d)
                 for fn in fns if fn.endswith(".dylib")]
        if not found:
            self._clog(f"目录 {d} 下未找到 .dylib 文件")
            return
        added = 0
        for path in found:
            if path not in self.custom_dylibs:
                self.custom_dylibs.append(path)
                self.list_dylibs.insert("end", path)
                added += 1
        if found:
            self.v_dylib_path.set(found[0])
        self._clog(f"已自动加入注入列表 {added}/{len(found)} 个 dylib: "
                   + ", ".join(os.path.basename(p) for p in found))

    def _cmp_download_ipa_manual(self):
        path = filedialog.askopenfilename(
            title="选择本地 IPA 文件",
            filetypes=[("IPA", "*.ipa"), ("所有文件", "*.*")])
        if not path:
            return
        self.v_ipa_path.set(path)
        self._clog(f"已设置 IPA 路径: {path}")

    def _cmp_download_ipa(self):
        token = self.v_gh_token.get().strip()
        owner, repo = self.v_owner.get().strip(), self.v_repo.get().strip()
        if not (owner and repo):
            messagebox.showerror("错误", "请填写 所有者 / 仓库名")
            return

        def work():
            try:
                url = f"https://api.github.com/repos/{owner}/{repo}/releases?per_page=10"
                _, j = cloud_mod.api_call("GET", url, token)
                rels = j if isinstance(j, list) else []
                assets = []
                for r in rels:
                    for a in r.get("assets", []):
                        if str(a.get("name", "")).lower().endswith(".ipa"):
                            assets.append((a["name"], a["browser_download_url"]))
                self.root.after(0, lambda: self._cmp_pick_ipa(assets))
            except RuntimeError as e:
                self._clog("❌ 获取 Releases 失败: " + str(e))

        threading.Thread(target=work, daemon=True).start()

    def _cmp_pick_ipa(self, assets):
        if not assets:
            self._clog("该仓库最近 Releases 里没有 .ipa 资产(可手动下载后『浏览』)")
            messagebox.showinfo("提示", "没有找到 IPA 资产, 请手动下载后点『浏览』")
            return
        win = tk.Toplevel(self.root)
        win.title("选择要下载的 IPA")
        win.transient(self.root)
        self._popup_geometry(win, 460, 320)
        lb = tk.Listbox(win, font=(FONT, 10))
        for nm, _ in assets:
            lb.insert("end", nm)
        lb.pack(fill="both", expand=True, padx=8, pady=8)

        def choose():
            sel = lb.curselection()
            if not sel:
                return
            nm, url = assets[sel[0]]
            d = filedialog.askdirectory(title="选择保存目录")
            if not d:
                return
            token = self.v_gh_token.get().strip()

            def dl():
                try:
                    import urllib.request as _ur
                    dst = os.path.join(d, nm)
                    _ur.urlretrieve(url, dst)
                    self.v_ipa_path.set(dst)
                    self._clog(f"已下载 IPA: {dst}")
                except Exception as e:
                    self._clog("❌ 下载 IPA 失败: " + str(e))

            threading.Thread(target=dl, daemon=True).start()
            win.destroy()

        ttk.Button(win, text="下载", command=choose).pack(pady=(0, 8))

    # ---- GitHub 仓库导出 ------------------------------------------------ #
    def _build_export_tab(self) -> ttk.Frame:
        # 注意：自定义 tab 由 _select_tab 把「滚动外层 outer」grid 进 page_area；
        # 这里必须返回 outer（和 info / github 页一致），否则整页空白。
        outer, page = self._make_scroll(self.page_area)
        page.columnconfigure(0, weight=1)
        box = self._group(page, "导出 GitHub 仓库源码到本地", 0)
        self._entry(box, 0, "仓库地址", self.v_export_repo,
                    "https://github.com/owner/repo 或 owner/repo")
        self._entry(box, 1, "分支 / 标签 / 提交", self.v_export_branch, "留空默认 main")

        ttk.Label(box, text="导出到").grid(row=2, column=0, sticky="w", padx=(0, 8), pady=4)
        ttk.Entry(box, textvariable=self.v_export_out).grid(row=2, column=1, sticky="ew", pady=4)
        ttk.Button(box, text="浏览…", width=8,
                   command=lambda: self._pick_dir(self.v_export_out)).grid(
            row=2, column=2, sticky="w", padx=(8, 0), pady=4)

        ttk.Label(box, text="Token（私有仓库）").grid(row=3, column=0, sticky="w", padx=(0, 8), pady=4)
        ttk.Entry(box, textvariable=self.v_export_token, show="*").grid(
            row=3, column=1, sticky="ew", pady=4)

        ttk.Button(box, text="导出到本地", style="Accent.TButton",
                   command=self._export_repo_run).grid(row=4, column=0, sticky="w", pady=(10, 0))
        ttk.Label(
            box, style="Muted.TLabel", justify="left", wraplength=560,
            text="把指定仓库的源码打包下载并解压到本地目录（等价于 git archive 下载，不含 .git 历史）。"
                 "默认复用「GitHub 导入」页填的 Token。",
        ).grid(row=4, column=1, columnspan=3, sticky="w", pady=(10, 0))
        return outer

    def _export_repo_run(self) -> None:
        repo = self.v_export_repo.get().strip()
        if not repo:
            messagebox.showwarning("缺少仓库地址", "请先填写 GitHub 仓库地址。")
            return
        out = self.v_export_out.get().strip()
        if not out:
            messagebox.showwarning("缺少导出目录", "请先选择导出到的本地目录。")
            return
        branch = self.v_export_branch.get().strip() or "main"
        token = self.v_export_token.get().strip() or self.v_gh_token.get().strip()
        argv = ["export", repo, "-b", branch, "-o", out]
        if token:
            argv += ["--token", token]
        self._start(argv, "export")

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
