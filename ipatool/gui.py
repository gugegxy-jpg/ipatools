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
import platform
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
APP_TITLE = "ipatool"


def _gui_config_path() -> str:
    """
    GUI 设置（含上次选的证书路径与密码）存哪。

    放用户配置目录，不写在工作目录里；密码是**明文**，只为了下次不用重输，
    不想留就在「签名」页取消勾选，或点「清除已保存的证书」。
    """
    system = platform.system()
    if system == "Windows":
        base = os.environ.get("APPDATA") or os.path.expanduser("~")
        return os.path.join(base, "ipatool", "gui.json")
    if system == "Darwin":
        return os.path.expanduser("~/Library/Application Support/ipatool/gui.json")
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "ipatool", "gui.json")
APP_SUBTITLE = "修改 IPA 的 Bundle ID / 名称，注入 dylib 并重新签名"
CAPTURE_TASKS = ("info", "certs")

# 配色（ttk 的 clam 主题可以改这些值，界面风格统一从这里调）
BG = "#f4f6f9"          # 窗口底色
CARD = "#ffffff"        # 输入控件底色
BORDER = "#d5dae3"      # 分隔线 / 边框
TEXT = "#1f2937"        # 正文
MUTED = "#6b7280"       # 次要说明
ACCENT = "#2563eb"      # 主色（按钮 / 选中态）
ACCENT_ACTIVE = "#1d4ed8"
OK = "#0f766e"          # 成功的提示色
DANGER = "#b3261e"      # 出错的提示色


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
        self.root.geometry("1020x880")
        self.root.minsize(940, 660)
        self.root.configure(background=BG)
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(3, weight=1)

        self.q: "queue.Queue[tuple[str, object]]" = queue.Queue()
        self.busy = False
        self.custom_dylibs: list[str] = []
        self.action_buttons: list[ttk.Button] = []

        self._configure_style()
        self._make_vars()
        self._build_header()
        self._build_inputs()
        self._build_tabs()
        self._build_bottom()

        self.root.after(80, self._poll)

    # ------------------------------------------------------------------ #
    # 界面风格
    # ------------------------------------------------------------------ #
    def _configure_style(self) -> None:
        """统一换一套更干净的 ttk 外观（clam 主题下这些选项都能改）。"""
        style = ttk.Style(self.root)
        if "clam" in style.theme_names():
            style.theme_use("clam")

        family = "Microsoft YaHei UI" if sys.platform == "win32" else "Helvetica"
        self.root.option_add("*Font", (family, 9))

        style.configure(".", background=BG, foreground=TEXT, fieldbackground=CARD, bordercolor=BORDER)
        style.configure("TFrame", background=BG)
        style.configure("TLabel", background=BG, foreground=TEXT)
        style.configure("Muted.TLabel", foreground=MUTED)
        style.configure("Title.TLabel", font=(family, 15, "bold"), foreground="#111827")
        style.configure("Sub.TLabel", foreground=MUTED)

        style.configure("TLabelframe", background=BG, bordercolor=BORDER, lightcolor=BG, darkcolor=BORDER)
        style.configure("TLabelframe.Label", background=BG, foreground="#111827", font=(family, 9, "bold"))

        style.configure("TButton", background=CARD, foreground=TEXT, bordercolor=BORDER,
                        padding=(10, 5), relief="flat", focuscolor=ACCENT)
        style.map("TButton",
                  background=[("active", "#eef2ff"), ("disabled", "#f1f3f7")],
                  bordercolor=[("focus", ACCENT)])
        style.configure("Accent.TButton", background=ACCENT, foreground="#ffffff",
                        bordercolor=ACCENT, padding=(14, 6))
        style.map("Accent.TButton",
                  background=[("active", ACCENT_ACTIVE), ("disabled", "#a5c0f5")],
                  foreground=[("disabled", "#ffffff")])

        style.configure("TCheckbutton", background=BG, foreground=TEXT, indicatorcolor=CARD)
        style.map("TCheckbutton",
                  background=[("active", BG)],
                  indicatorcolor=[("selected", ACCENT), ("active", "#eef2ff")])

        style.configure("TEntry", fieldbackground=CARD, bordercolor=BORDER, padding=(6, 4),
                        lightcolor=BORDER, darkcolor=BORDER)
        style.map("TEntry", bordercolor=[("focus", ACCENT)],
                  lightcolor=[("focus", ACCENT)], darkcolor=[("focus", ACCENT)])
        style.configure("TCombobox", fieldbackground=CARD, bordercolor=BORDER, padding=(6, 4))
        style.map("TCombobox", bordercolor=[("focus", ACCENT)],
                  lightcolor=[("focus", ACCENT)], darkcolor=[("focus", ACCENT)])

        style.configure("TNotebook", background=BG, bordercolor=BORDER, tabmargins=(2, 4, 2, 0))
        style.configure("TNotebook.Tab", background="#e6e9ef", foreground=TEXT,
                        bordercolor=BORDER, padding=(16, 7), font=(family, 9, "bold"), focuscolor=BG)
        style.map("TNotebook.Tab",
                  background=[("selected", CARD), ("active", "#eef2ff")],
                  foreground=[("selected", ACCENT)])

        style.configure("Treeview", background=CARD, fieldbackground=CARD, bordercolor=BORDER,
                        rowheight=26)
        style.configure("Treeview.Heading", background="#e9edf4", foreground=TEXT, relief="flat")
        style.map("Treeview",
                  background=[("selected", "#dbeafe")],
                  foreground=[("selected", "#111827")])

        style.configure("TSeparator", background=BORDER)
        style.configure("Vertical.TScrollbar", background="#e9edf4", bordercolor=BORDER,
                        troughcolor=BG, arrowcolor=TEXT)

    # ------------------------------------------------------------------ #
    # 顶部标题
    # ------------------------------------------------------------------ #
    def _build_header(self) -> None:
        head = ttk.Frame(self.root, padding=(14, 10, 14, 8))
        head.grid(row=0, column=0, sticky="ew")
        head.columnconfigure(0, weight=1)
        ttk.Label(head, text=APP_TITLE, style="Title.TLabel").grid(row=0, column=0, sticky="w")
        ttk.Label(head, text=APP_SUBTITLE, style="Sub.TLabel").grid(row=1, column=0, sticky="w", pady=(2, 0))
        ttk.Separator(self.root, orient="horizontal").grid(row=1, column=0, sticky="ew")

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
        self.v_zip_level = tk.StringVar(value="auto")
        self.v_remember = tk.BooleanVar(value=True)
        self.v_hardened = tk.BooleanVar(value=False)
        self.v_dry_run = tk.BooleanVar(value=False)
        self.v_verbose = tk.BooleanVar(value=False)

        # 状态
        self.v_status = tk.StringVar(value="就绪")

        # 上次的签名设置（证书 / 密码）：启动时恢复，之后改动自动保存
        self._save_job: str | None = None
        self._restore_settings()
        for var in (self.v_sign, self.v_identity, self.v_p12, self.v_p12_password,
                    self.v_provision, self.v_entitlements, self.v_zip_level,
                    self.v_remember):
            var.trace_add("write", self._schedule_save)

    # ------------------------------------------------------------------ #
    # 顶部：输入 / 输出
    # ------------------------------------------------------------------ #
    def _build_inputs(self) -> None:
        box = ttk.LabelFrame(self.root, text="IPA 文件", padding=(10, 6))
        box.grid(row=2, column=0, sticky="ew", padx=12, pady=(10, 6))
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
            text="输入可以是 .ipa，也可以是已解包且含 Payload 的目录；输出留空则按默认名字生成（覆盖原文件时忽略此项）。"
                 "选中后不会自动解析，需要包内信息时点「读取信息」。",
            style="Muted.TLabel", justify="left", wraplength=940,
        )
        hint.grid(row=1, column=0, columnspan=6, sticky="w", pady=(6, 0))

        ttk.Checkbutton(
            box, text="直接覆盖输入文件（--in-place）", variable=self.v_inplace, command=self._sync_inplace,
        ).grid(row=2, column=0, columnspan=3, sticky="w", pady=(4, 0))

        self.msg_io = ttk.Label(box, text="", foreground=DANGER)
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
        self._append(
            f"[输入] {path}\n"
            "        已选中，未解析（只想注入 / 签名可以直接开始执行）。\n"
            "        需要包内的 Bundle ID / 名称 / 内嵌 bundle 时，点「读取信息」。\n"
        )
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
        self.nb = ttk.Notebook(self.root)
        self.nb.grid(row=3, column=0, sticky="nsew", padx=12)
        self._build_info_tab()
        self._build_pack_tab()

    # ---- 改 ID · 注入 · 签名（合并页） -------------------------------- #
    def _build_pack_tab(self) -> None:
        page = self._scroll_page("  改 ID · 注入 · 签名  ")
        self._build_pack_identity(page, 0)
        self._build_pack_dylib(page, 1)
        self._build_pack_sign(page, 2)
        self._build_pack_keep(page, 3)
        self._build_pack_run(page, 4)

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
            style="Muted.TLabel",
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
        self.info_detail = tk.Text(
            detail_box, height=8, wrap="none", state="disabled", font=("Consolas", 9),
            background=CARD, foreground=TEXT, relief="solid", borderwidth=1,
            highlightthickness=1, highlightcolor=BORDER, highlightbackground=BORDER,
        )
        self.info_detail.grid(row=0, column=0, sticky="nsew")
        bar_y = ttk.Scrollbar(detail_box, orient="vertical", command=self.info_detail.yview)
        bar_y.grid(row=0, column=1, sticky="ns")
        self.info_detail.configure(yscrollcommand=bar_y.set)

    def _scroll_page(self, title: str) -> ttk.Frame:
        """
        一个可以滚动的页签：内容比窗口高时出现竖向滚动条，而不是被裁掉。
        返回内层 Frame，往里加控件即可（用法和普通页签一样）。
        """
        outer = ttk.Frame(self.nb)
        self.nb.add(outer, text=title)
        outer.columnconfigure(0, weight=1)
        outer.rowconfigure(0, weight=1)

        canvas = tk.Canvas(outer, background=BG, highlightthickness=0, borderwidth=0)
        canvas.grid(row=0, column=0, sticky="nsew")
        vbar = ttk.Scrollbar(outer, orient="vertical", command=canvas.yview)
        vbar.grid(row=0, column=1, sticky="ns")
        canvas.configure(yscrollcommand=vbar.set)

        inner = ttk.Frame(canvas, padding=(10, 8, 10, 8))
        window = canvas.create_window((0, 0), window=inner, anchor="nw")

        inner.bind("<Configure>", lambda _e: canvas.configure(scrollregion=canvas.bbox("all")))
        canvas.bind("<Configure>", lambda e: canvas.itemconfigure(window, width=e.width))

        def _wheel(event):
            # 多行文本 / 列表自己会滚，别抢它们的滚轮
            if isinstance(event.widget, (tk.Text, tk.Listbox)):
                return None
            delta = getattr(event, "delta", 0)
            if not delta:
                return None
            step = int(-delta / 120) if abs(delta) >= 120 else (-1 if delta > 0 else 1)
            canvas.yview_scroll(step or 1, "units")
            return "break"

        # 子控件会吃掉滚轮事件，所以鼠标进本页时临时挂个全局绑定，离开就摘掉
        canvas.bind("<MouseWheel>", _wheel)
        outer.bind("<Enter>", lambda _e: canvas.bind_all("<MouseWheel>", _wheel))
        outer.bind("<Leave>", lambda _e: canvas.unbind_all("<MouseWheel>"))
        return inner

    # ---- 改 ID / 名称 -------------------------------------------------- #
    def _build_pack_identity(self, page, row: int) -> None:
        box = self._group(page, "改 Bundle ID / 名称（留空表示不改）", row)
        self._entry(box, 0, "Bundle Identifier", self.v_bundle_id, "如 com.company.newapp")
        self._entry(box, 1, "显示名称", self.v_name, "CFBundleDisplayName（桌面图标下的名字）")
        ttk.Checkbutton(
            box, text="不同步修改本地化名称（InfoPlist.strings / --no-localized）",
            variable=self.v_no_localized,
        ).grid(row=2, column=0, columnspan=3, sticky="w", pady=(6, 0))

    # ---- 注入 dylib ---------------------------------------------------- #
    def _build_pack_dylib(self, page, row: int) -> None:
        box = self._group(page, "注入 dylib（不注入就留空）", row)
        wrap = ttk.Frame(box)
        wrap.grid(row=0, column=0, columnspan=2, sticky="ew")
        wrap.columnconfigure(0, weight=1)
        self.list_dylibs = tk.Listbox(
            wrap, height=6, selectmode="extended", font=("Consolas", 9),
            background=CARD, foreground=TEXT, relief="solid", borderwidth=1,
            highlightthickness=1, highlightcolor=BORDER, highlightbackground=BORDER,
            activestyle="none",
        )
        self.list_dylibs.grid(row=0, column=0, sticky="ew")
        bar_y = ttk.Scrollbar(wrap, orient="vertical", command=self.list_dylibs.yview)
        bar_y.grid(row=0, column=1, sticky="ns")
        self.list_dylibs.configure(yscrollcommand=bar_y.set)

        btns = ttk.Frame(box)
        btns.grid(row=0, column=2, sticky="nw", padx=(10, 0))
        ttk.Button(btns, text="添加…", width=10, command=self._add_dylib).pack()
        ttk.Button(btns, text="移除", width=10, command=self._remove_dylib).pack(pady=4)
        ttk.Button(btns, text="清空", width=10, command=self._clear_dylib).pack(pady=4)
        ttk.Button(btns, text="核对产物", width=10, command=self._list_injected).pack()

        ttk.Label(
            box, style="Muted.TLabel", justify="left",
            text="dylib 会被放进 App 的 Frameworks/，并写入主可执行文件的 LC_LOAD_DYLIB；列表顺序即加载顺序。",
        ).grid(row=1, column=0, columnspan=3, sticky="w", pady=(8, 0))

    # ---- 签名 ---------------------------------------------------------- #
    def _build_pack_sign(self, page, row: int) -> None:
        box = self._group(page, "签名（改 ID / 注入共用，二选一，都不给则 ad-hoc 签名，真机装不上）", row)
        ttk.Label(box, text="后端").grid(row=0, column=0, sticky="w", padx=(0, 8), pady=3)
        ttk.Combobox(
            box, textvariable=self.v_sign, values=list(signer.BACKENDS),
            state="readonly", width=14,
        ).grid(row=0, column=1, sticky="w", pady=3)
        ttk.Label(
            box, style="Muted.TLabel", justify="left", wraplength=420,
            text="auto：macOS 用 codesign，非 macOS 用 zsign（要装；也可用环境变量 "
                 "IPATOOL_ZSIGN 指路径）；none 只重打包不签名",
        ).grid(row=0, column=2, sticky="w", padx=(10, 0), pady=3)

        ttk.Label(box, text="ID 签名").grid(row=1, column=0, sticky="w", padx=(0, 8), pady=3)
        self.cb_identity = ttk.Combobox(box, textvariable=self.v_identity, values=[], width=46)
        self.cb_identity.grid(row=1, column=1, columnspan=2, sticky="ew", pady=3)
        ttk.Button(box, text="读取系统证书", command=self._load_certs).grid(row=1, column=3, sticky="w", padx=(10, 0), pady=3)

        self._entry(box, 2, "证书文件", self.v_p12, "p12 / pfx（证书签名）", browse=lambda: self._pick_file(self.v_p12, [("证书", "*.p12 *.pfx"), ("所有文件", "*.*")]))
        ttk.Label(box, text="证书密码").grid(row=3, column=0, sticky="w", padx=(0, 8), pady=3)
        ttk.Entry(box, textvariable=self.v_p12_password, show="*", width=30).grid(row=3, column=1, sticky="w", pady=3)
        ttk.Label(box, text="也可留空，用环境变量 IPATOOL_P12_PASSWORD", style="Muted.TLabel").grid(
            row=3, column=2, columnspan=2, sticky="w", padx=(10, 0), pady=3,
        )

        self._entry(box, 4, "描述文件", self.v_provision, "embedded.mobileprovision，改过 Bundle ID 时必须匹配", browse=lambda: self._pick_file(self.v_provision, [("描述文件", "*.mobileprovision"), ("所有文件", "*.*")]))

    # ---- 记住设置 ------------------------------------------------------ #
    def _build_pack_keep(self, page, row: int) -> None:
        # 证书 / 密码存下来，下次打开自动填好
        keep = self._group(page, "记住设置", row)
        ttk.Checkbutton(
            keep, text="记住证书 / 密码 / ID 签名，下次打开自动填好",
            variable=self.v_remember,
        ).grid(row=0, column=0, columnspan=3, sticky="w")
        ttk.Label(
            keep, style="Muted.TLabel", justify="left", wraplength=620,
            text=f"保存在本机配置文件里（明文）：{_gui_config_path()}\n"
                 "不想留就取消勾选；也可以点右边按钮把已保存的清掉（不影响证书文件本身）。",
        ).grid(row=1, column=0, columnspan=2, sticky="w", pady=(4, 0))
        ttk.Button(
            keep, text="清除已保存的证书", command=self._clear_settings,
        ).grid(row=1, column=2, sticky="e", padx=(10, 0))

    # ---- 执行 ---------------------------------------------------------- #
    def _build_pack_run(self, page, row: int) -> None:
        run = self._group(page, "执行", row)
        ttk.Button(
            run, text="改 ID / 名称（含签名）", width=20,
            command=lambda: self._run_modify(False),
        ).grid(row=0, column=0, sticky="w")
        ttk.Button(
            run, text="注入 dylib（含签名）", width=20,
            command=lambda: self._run_inject(False),
        ).grid(row=0, column=1, sticky="w", padx=(8, 0))
        ttk.Button(
            run, text="只重新签名", width=20,
            command=lambda: self._run_sign(False),
        ).grid(row=0, column=2, sticky="w", padx=(8, 0))
        ttk.Label(
            run, style="Muted.TLabel", justify="left", wraplength=620,
            text="三个操作各自要解包打包一次，点哪个就只做哪个。\n"
                 "底部「开始执行」按当前填写自动选：列表里有 dylib 就注入，填了 ID / 名称就改名，"
                 "什么都没填就只重新打包 + 签名。「预览（dry-run）」只打印会改什么，不写文件。",
        ).grid(row=1, column=0, columnspan=3, sticky="w", pady=(6, 0))

    # ------------------------------------------------------------------ #
    # 底部：日志 + 操作
    # ------------------------------------------------------------------ #
    def _build_bottom(self) -> None:
        area = ttk.Frame(self.root)
        area.grid(row=4, column=0, sticky="nsew", padx=12, pady=(6, 12))
        area.columnconfigure(0, weight=1)
        area.rowconfigure(1, weight=1)

        bar = ttk.Frame(area)
        bar.grid(row=0, column=0, sticky="ew")
        b_info = ttk.Button(bar, text="读取信息", command=self._load_info)
        b_dry = ttk.Button(bar, text="预览（dry-run）", command=lambda: self._run_current(dry_run=True))
        b_go = ttk.Button(bar, text="开始执行", style="Accent.TButton",
                          command=lambda: self._run_current(dry_run=False))
        for btn in (b_info, b_dry, b_go):
            btn.pack(side="left", padx=(0, 8))
        self.action_buttons = [b_info, b_dry, b_go]
        ttk.Button(bar, text="清空日志", command=lambda: self._set_text(self.log, "")).pack(side="left")
        self.lbl_status = ttk.Label(bar, textvariable=self.v_status, foreground=OK)
        self.lbl_status.pack(side="right")

        log_box = ttk.LabelFrame(area, text=" 输出 ", padding=(6, 4))
        log_box.grid(row=1, column=0, sticky="nsew", pady=(6, 0))
        log_box.columnconfigure(0, weight=1)
        log_box.rowconfigure(0, weight=1)
        self.log = tk.Text(
            log_box, height=9, wrap="word", state="disabled", font=("Consolas", 9),
            background=CARD, foreground=TEXT, relief="solid", borderwidth=1,
            highlightthickness=1, highlightcolor=BORDER, highlightbackground=BORDER,
            insertbackground=TEXT,
        )
        self.log.grid(row=0, column=0, sticky="nsew")
        bar_y = ttk.Scrollbar(log_box, orient="vertical", command=self.log.yview)
        bar_y.grid(row=0, column=1, sticky="ns")
        self.log.configure(yscrollcommand=bar_y.set)
        self.log.tag_configure("err", foreground=DANGER)

    # ------------------------------------------------------------------ #
    # 布局小助手
    # ------------------------------------------------------------------ #
    def _group(self, parent, title: str, row: int) -> ttk.LabelFrame:
        box = ttk.LabelFrame(parent, text=f" {title} ", padding=(10, 6))
        box.grid(row=row, column=0, sticky="new", pady=(0, 8))
        box.columnconfigure(1, weight=1)
        parent.columnconfigure(0, weight=1)
        return box

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
        self.v_entitlements.set(str(data.get("entitlements") or ""))
        self.v_zip_level.set(str(data.get("zip_level") or "auto"))
        self.v_remember.set(bool(data.get("remember", True)))
        if self.v_remember.get():
            self.v_p12_password.set(str(data.get("p12_password") or ""))
        if self.v_p12.get() or self.v_identity.get():
            self.v_status.set("已载入上次的签名设置")

    def _write_settings(self) -> None:
        self._save_job = None
        path = _gui_config_path()
        data = {
            "sign": self.v_sign.get(),
            "identity": self.v_identity.get(),
            "p12": self.v_p12.get(),
            "provision": self.v_provision.get(),
            "entitlements": self.v_entitlements.get(),
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

    def _clear_settings(self) -> None:
        if not messagebox.askyesno("清除已保存的证书",
                                   "确定要删掉已保存的证书路径和密码吗？\n"
                                   "（不影响证书文件本身，只是不再自动填）"):
            return
        try:
            os.remove(_gui_config_path())
        except OSError:
            pass
        self.v_p12_password.set("")
        self.v_p12.set("")
        self.v_identity.set("")
        self._append("[设置] 已清除保存的证书信息\n")

    def _entry(self, box, row, label, var, hint=None, browse=None, width=36):
        ttk.Label(box, text=label).grid(row=row, column=0, sticky="w", padx=(0, 8), pady=3)
        ttk.Entry(box, textvariable=var, width=width).grid(row=row, column=1, sticky="ew", pady=3)
        box.columnconfigure(1, weight=1)
        col = 2
        if browse:
            ttk.Button(box, text="浏览…", width=8, command=browse).grid(row=row, column=col, padx=(6, 0), pady=3)
            col += 1
        if hint:
            ttk.Label(box, text=hint, style="Muted.TLabel").grid(row=row, column=col, sticky="w", padx=(8, 0), pady=3)

    def _combo(self, box, row, label, var, values):
        ttk.Label(box, text=label).grid(row=row, column=0, sticky="w", padx=(0, 8), pady=3)
        ttk.Combobox(box, textvariable=var, values=[OPT_DEFAULT] + values, state="readonly", width=16).grid(
            row=row, column=1, sticky="w", pady=3,
        )

    def _pick_file(self, var: tk.StringVar, filetypes=None) -> None:
        path = filedialog.askopenfilename(title="选择文件", filetypes=filetypes or [("所有文件", "*.*")])
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
        self._set_status("运行中…", "run")
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
            self._set_status("完成")
            if task in ("inject", "modify", "sign"):
                messagebox.showinfo("完成", "处理完成，输出文件已生成。")
            return
        self._set_status(f"失败（退出码 {code}）", "err")
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
            messagebox.showwarning("缺少输入", "请先选择要处理的 IPA 文件或已解包目录。")
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
        """底部「开始执行 / 预览」：信息页读信息，合并页按当前填写自动选。"""
        if self.nb.index(self.nb.select()) == 0:
            self._load_info()
            return
        fill_ident = bool(self.v_bundle_id.get().strip() or self.v_name.get().strip())
        if self.custom_dylibs:
            if fill_ident:
                self._append("[执行] 本次只做「注入」。要同时改 ID / 名称，请点上面的「改 ID / 名称（含签名）」。\n")
            self._run_inject(dry_run)
            return
        if fill_ident:
            self._run_modify(dry_run)
            return
        # 什么都没填：只重新打包 + 签名（以前会被「至少填一项」挡住，跑不了）
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
