"""ipatool 命令行入口。"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import tempfile

from . import bundle as bundle_mod
from . import inject as inject_mod
from . import ipa as ipa_mod
from . import keystore
from . import plistutil
from . import signer

BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9.\-]*[A-Za-z0-9])?$")


def _add_output_args(p: argparse.ArgumentParser) -> None:
    """输出、签名相关的公共参数（modify / inject 共用）。"""
    p.add_argument(
        "-o", "--output",
        help="输出 IPA 路径；modify 默认 <原名>-modified.ipa，inject 默认 <原名>-injected.ipa",
    )
    p.add_argument("--in-place", action="store_true", help="直接覆盖输入文件")
    p.add_argument("--sign", choices=list(signer.BACKENDS), default="auto", help="重签名后端，默认 auto")

    cert = p.add_argument_group(
        "签名证书",
        "二选一：--identity 用系统里已安装的证书（ID 签名），--p12 直接给证书文件（证书签名）",
    )
    cert.add_argument(
        "--identity",
        help="ID 签名：macOS 钥匙串中的证书名称或 SHA-1（如 'Apple Development: x (TEAMID)'）；"
             "Windows 上为证书指纹。缺省为 '-'（ad-hoc 签名）",
    )
    cert.add_argument("--p12", help="证书签名：p12/pfx 证书文件路径")
    cert.add_argument("--p12-password", help="证书密码，缺省时交互输入，也可用 IPATOOL_P12_PASSWORD 环境变量")

    p.add_argument("--provision", help="写入 App 的 embedded.mobileprovision 描述文件")
    p.add_argument("--entitlements", help="主 App 使用的 entitlements.plist")
    p.add_argument("--hardened-runtime", action="store_true", help="codesign 时启用 hardened runtime")
    p.add_argument("--dry-run", action="store_true", help="只打印将要发生的改动，不写文件")
    p.add_argument("-v", "--verbose", action="store_true")


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="ipatool",
        description="修改 IPA 包的 Bundle ID / 名称、注入 dylib，并可重新签名",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    pi = sub.add_parser("info", help="查看 IPA 的 Bundle ID / 名称 / 内嵌 bundle / 已注入 dylib")
    pi.add_argument("input", help="IPA 文件路径，或已解包且含 Payload 的目录")
    pi.add_argument("--json", action="store_true", help="以 JSON 输出")

    pc = sub.add_parser("certs", help="列出可用于签名的证书身份（ID 签名用）")
    pc.add_argument("--json", action="store_true", help="以 JSON 输出")

    pm = sub.add_parser("modify", help="修改 Bundle ID 与名称")
    pm.add_argument("input", help="IPA 文件路径，或已解包且含 Payload 的目录")
    pm.add_argument("-i", "--bundle-id", help="新的 Bundle Identifier")
    pm.add_argument("-n", "--name", help="新的显示名称（CFBundleDisplayName）")
    pm.add_argument("--bundle-name", help="新的 CFBundleName，默认跟随 --name")
    pm.add_argument("--no-localized", action="store_true", help="不同步修改 InfoPlist.strings 里的本地化名称")
    _add_output_args(pm)

    pj = sub.add_parser(
        "inject",
        help="注入 dylib（内置 --keep-alive 后台保活、--files 文件导入导出）",
        description="把 dylib 放进 App 的 Frameworks/ 并写入 LC_LOAD_DYLIB；注入后必须重新签名才能安装",
    )
    pj.add_argument("input", help="IPA 文件路径，或已解包且含 Payload 的目录")
    pj.add_argument("--dylib", action="append", metavar="PATH", help="要注入的 dylib，可重复指定")
    pj.add_argument("--list", action="store_true", help="只列出已注入的 dylib，不改动任何文件")
    pj.add_argument("--background-mode", action="append", metavar="MODE", help="额外追加到 UIBackgroundModes 的值，如 fetch")
    pj.add_argument(
        "--allow-arbitrary-loads",
        action="store_true",
        help="写 NSAllowsArbitraryLoads=YES 关掉 ATS 限制（热更服务器用明文 HTTP 时需要）",
    )

    ka = pj.add_argument_group(
        "后台保活",
        "让 App 切到后台后继续运行（适合游戏后台热更/下载），默认靠静音音频，最稳定",
    )
    ka.add_argument("--keep-alive", action="store_true", help="注入内置保活 tweak")
    ka.add_argument("--keep-alive-dylib", metavar="PATH", help="保活 tweak 的 dylib 路径，默认自动查找（macOS 上会自动编译）")
    ka.add_argument(
        "--keep-alive-start-on",
        choices=["launch", "background"],
        help="静音保活音频何时开始播放，默认 launch（更稳）；background 更省电但可能来不及",
    )
    ka.add_argument("--keep-alive-no-audio", action="store_true", help="不播放静音音频（只靠后台任务续期，保活时间很短）")
    ka.add_argument("--keep-alive-no-pip", action="store_true", help="关掉画中画保活（只用静音音频；默认开启：切后台自动进画中画、回前台自动退出）")
    ka.add_argument("--keep-alive-audio-file", metavar="PATH", help="改用指定音频文件循环播放（如近乎无声的底噪）")
    ka.add_argument("--keep-alive-no-task-renew", action="store_true", help="不再续期 beginBackgroundTask（默认续期）")
    ka.add_argument("--keep-alive-renew-lead-time", type=float, metavar="SEC", help="提前多少秒续期后台任务，默认 10")
    ka.add_argument(
        "--keep-alive-location",
        action="store_true",
        help="额外用后台定位保活（耗电，需用户授权，App Store 会拒，仅自用包）",
    )
    ka.add_argument("--keep-alive-location-indicator", action="store_true", help="显示定位蓝条（默认隐藏）")
    ka.add_argument("--keep-alive-fetch", action="store_true", help="注册 BGAppRefreshTask，让系统定期把进程唤醒")
    ka.add_argument("--keep-alive-processing", action="store_true", help="注册 BGProcessingTask（长任务，通常要充电/空闲）")
    ka.add_argument("--keep-alive-refresh-interval", type=int, metavar="SEC", help="定时唤醒的最短间隔，默认 900")

    panel = pj.add_argument_group(
        "悬浮窗",
        "在 App 里显示一个可拖动的悬浮按钮，点开后实时开关后台保活 / 文件导入导出"
        "（默认跟着 --keep-alive/--files 一起注入）",
    )
    panel.add_argument("--panel", action="store_true", help="强制注入悬浮窗")
    panel.add_argument("--no-panel", action="store_true", help="不注入悬浮窗（只改配置、不加界面）")
    panel.add_argument("--panel-dylib", metavar="PATH", help="悬浮窗 dylib 路径，默认自动查找（macOS 上会自动编译）")
    panel.add_argument("--panel-title", metavar="TEXT", help="悬浮按钮上的文字，默认 IPAT")

    files = pj.add_argument_group(
        "文件导入导出",
        "在悬浮窗里浏览沙盒里的游戏热更文件，导出到系统「文件」App，或从「文件」App 导入回来",
    )
    files.add_argument("--files", action="store_true", help="注入文件导入导出 tweak")
    files.add_argument("--no-files", action="store_true", help="不注入文件导入导出 tweak")
    files.add_argument("--files-dylib", metavar="PATH", help="文件导入导出 dylib 路径，默认自动查找（macOS 上会自动编译）")
    files.add_argument(
        "--files-root",
        metavar="DIR",
        help="浏览界面的根目录，相对沙盒，默认沙盒根（沙盒根下就是 Documents / Library / tmp）",
    )
    files.add_argument(
        "--files-import-dir",
        metavar="DIR",
        help="从「文件」App 导入的落地目录，相对沙盒，默认 Documents",
    )
    files.add_argument(
        "--no-files-sharing",
        action="store_true",
        help="不打开 UIFileSharingEnabled（默认打开，让 Documents 出现在系统「文件」App 里）",
    )

    _add_output_args(pj)

    sub.add_parser(
        "gui",
        help="打开图形界面（tkinter），功能与本命令行一致",
        description="启动图形界面；界面只是把参数拼成命令行再调用本工具，行为完全一致",
    )
    return p


def _prepare(src: str, workdir: str) -> str:
    """返回包含 Payload 的根目录。"""
    if os.path.isdir(src):
        if os.path.isdir(os.path.join(src, "Payload")):
            return src
        raise SystemExit(f"错误：目录 {src} 内没有 Payload")
    if not os.path.isfile(src):
        raise SystemExit(f"错误：找不到输入文件 {src}")
    if not src.lower().endswith(".ipa"):
        print(f"提示：{src} 不是 .ipa 后缀，仍按 zip 处理")
    ipa_mod.extract(src, workdir)
    return workdir


def _payload_of(root: str) -> str:
    payload = os.path.join(root, "Payload")
    if not os.path.isdir(payload):
        raise SystemExit("错误：包内缺少 Payload 目录，这可能不是有效的 IPA")
    return payload


def _open_package(src: str, workdir: str):
    root = _prepare(src, workdir)
    payload = _payload_of(root)
    bundles = bundle_mod.discover(root)
    return root, payload, bundles, bundle_mod.main_app(bundles)


def _utf8_stdout() -> None:
    """JSON 输出固定 UTF-8，避免受控制台代码页影响。"""
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass


def cmd_info(args) -> int:
    workdir = tempfile.mkdtemp(prefix="ipatool-")
    try:
        root, _payload, bundles, app = _open_package(args.input, workdir)
        try:
            injected = inject_mod.list_injected(app)
        except (inject_mod.InjectError, OSError):
            injected = []

        info = {
            "file": os.path.abspath(args.input),
            "bundle_id": app.identifier,
            "display_name": app.display_name,
            "bundle_name": app.bundle_name,
            "version": app.version,
            "build": app.build,
            "min_os": app.min_os,
            "executable": app.executable,
            "app_path": app.rel,
            "background_modes": None,
            "injected": injected,
            "nested": [
                {"path": b.rel, "kind": b.kind, "bundle_id": b.identifier, "name": b.display_name}
                for b in bundles
                if b is not app
            ],
        }
        if app.plist_path:
            plist = plistutil.load_plist(app.plist_path)
            modes = plist.get("UIBackgroundModes")
            if isinstance(modes, list):
                info["background_modes"] = modes

        if args.json:
            _utf8_stdout()
            print(json.dumps(info, ensure_ascii=False, indent=2))
        else:
            print(f"文件        : {info['file']}")
            print(f"主程序      : {info['app_path']}")
            print(f"Bundle ID   : {info['bundle_id']}")
            print(f"显示名称    : {info['display_name']}")
            print(f"CFBundleName: {info['bundle_name']}")
            print(f"版本        : {info['version']} (build {info['build']})")
            print(f"最低系统    : {info['min_os']}")
            if info["background_modes"]:
                print(f"后台模式    : {', '.join(info['background_modes'])}")
            if injected:
                print(f"已注入 dylib ({len(injected)}):")
                for d in injected:
                    print(f"  - {d}")
            if info["nested"]:
                print(f"内嵌 bundle ({len(info['nested'])}):")
                for n in info["nested"]:
                    print(f"  - {n['path']}  [{n['kind']}]  {n['bundle_id']}")
        return 0
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def cmd_certs(args) -> int:
    ids, source = keystore.list_identities()
    if args.json:
        _utf8_stdout()
        print(json.dumps(
            {"source": source, "identities": [{"id": i.id, "name": i.name, "source": i.source} for i in ids]},
            ensure_ascii=False, indent=2,
        ))
        return 0

    print(f"证书来源: {source}")
    if not ids:
        print("未找到可用身份。可用 --p12 直接指定证书文件，或在 macOS 上安装证书到钥匙串。")
        return 0
    for n, i in enumerate(ids, 1):
        print(f"  {n:>2}) {i}")
    print("\n用法示例: --identity <上面的 ID 或名称>")
    return 0


def _output_path(args, workdir: str) -> str:
    if args.in_place:
        return os.path.join(workdir, "out.ipa")
    if args.output:
        return os.path.abspath(args.output)
    stem = os.path.splitext(os.path.basename(os.path.normpath(args.input)))[0]
    suffix = "-injected.ipa" if args.cmd == "inject" else "-modified.ipa"
    return os.path.abspath(f"{stem}{suffix}")


def _package_and_sign(args, root: str, payload: str, app, workdir: str,
                      zsign_bundle_id: str | None = None, unsigned_warning: str | None = None) -> int:
    """打包 + 按所选后端重签名 + 落盘。"""
    out = _output_path(args, workdir)
    backend = signer.resolve_backend(args.sign)
    print(f"重签名后端  : {backend}")

    want_identity = args.identity if args.identity not in (None, "", "-") else None
    if backend == "none" and (args.p12 or want_identity):
        print("  警告: 当前环境没有可用的签名工具，已忽略证书参数，输出的是未签名 IPA")
    elif backend == "none" and unsigned_warning:
        print(f"  警告: {unsigned_warning}")

    with keystore.IdentitySession(
        identity=want_identity,
        p12=args.p12,
        p12_password=args.p12_password,
        backend=backend,
    ) as ident:
        if backend == "codesign":
            signer.codesign_payload(
                payload,
                identity=ident.value,
                main_app=app.path,
                entitlements=args.entitlements,
                hardened_runtime=args.hardened_runtime,
                keychain=ident.keychain,
                log=lambda m: print(m) if args.verbose else None,
            )
            ipa_mod.archive(root, out)
        elif backend == "zsign":
            unsigned = os.path.join(workdir, "unsigned.ipa")
            ipa_mod.archive(root, unsigned)
            signer.zsign_ipa(
                unsigned,
                out,
                p12=ident.p12_path,
                p12_password=ident.p12_password,
                provision=args.provision,
                entitlements=args.entitlements,
                bundle_id=zsign_bundle_id,
                log=lambda m: print(m) if args.verbose else None,
            )
        else:
            ipa_mod.archive(root, out)
            print("  警告: 未找到可用的签名工具，输出的是未签名 IPA，设备无法直接安装")

    if args.in_place:
        shutil.move(out, os.path.abspath(args.input))
        print(f"已覆盖: {os.path.abspath(args.input)}")
    else:
        print(f"输出: {out}")
    return 0


def cmd_modify(args) -> int:
    if not args.bundle_id and not args.name:
        print("错误：至少需要指定 --bundle-id 或 --name", file=sys.stderr)
        return 2
    if args.bundle_id and not BUNDLE_ID_RE.match(args.bundle_id):
        print(f"错误：Bundle ID `{args.bundle_id}` 含非法字符", file=sys.stderr)
        return 2
    if args.in_place and args.output:
        print("错误：--in-place 与 -o/--output 不能同时使用", file=sys.stderr)
        return 2

    new_bundle_name = args.bundle_name
    workdir = tempfile.mkdtemp(prefix="ipatool-")
    try:
        root, payload, _bundles, app = _open_package(args.input, workdir)

        old_id = app.identifier or ""
        old_display = app.display_name or app.bundle_name or ""
        if args.name and not new_bundle_name:
            # CFBundleName 与显示名一致时（Xcode 默认行为）一起改
            if app.bundle_name and (app.bundle_name == app.display_name or not app.display_name):
                new_bundle_name = args.name

        print(f"原 Bundle ID : {old_id}")
        print(f"原显示名称   : {old_display}")

        changes, warnings = bundle_mod.apply_changes(
            root,
            new_bundle_id=args.bundle_id,
            new_display_name=args.name,
            new_bundle_name=new_bundle_name,
            update_localized=not args.no_localized,
            dry_run=args.dry_run,
        )

        if not changes:
            print("没有需要修改的内容")
        else:
            print(f"待应用改动 ({len(changes)}):")
            for c in changes:
                print(f"  {c}")
        for w in warnings:
            print(f"  警告: {w}")

        if args.dry_run:
            print("\n[dry-run] 未写入任何文件")
            return 0

        if args.provision:
            dest = signer.embed_provision(app.path, args.provision)
            print(f"已写入描述文件: {os.path.relpath(dest, root)}")

        code = _package_and_sign(
            args, root, payload, app, workdir, zsign_bundle_id=args.bundle_id,
        )
        if not args.provision:
            print("提示: 未指定 --provision，原描述文件与新 Bundle ID 可能不匹配（通配符描述文件除外）")
        return code
    except (signer.SignError, inject_mod.InjectError) as e:
        print(f"失败: {e}", file=sys.stderr)
        return 1
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def cmd_inject(args) -> int:
    if args.in_place and args.output:
        print("错误：--in-place 与 -o/--output 不能同时使用", file=sys.stderr)
        return 2

    workdir = tempfile.mkdtemp(prefix="ipatool-")
    try:
        root, payload, _bundles, app = _open_package(args.input, workdir)

        if args.list:
            try:
                deps = inject_mod.list_injected(app)
            except inject_mod.InjectError as e:
                print(f"失败: {e}", file=sys.stderr)
                return 1
            if not deps:
                print(f"{app.rel} 没有注入任何 dylib")
                return 0
            print(f"{app.rel} 已注入 ({len(deps)}):")
            for d in deps:
                print(f"  - {d}")
            return 0

        ka_tuning = any((
            args.keep_alive_dylib,
            args.keep_alive_start_on,
            args.keep_alive_no_audio,
            args.keep_alive_no_pip,
            args.keep_alive_audio_file,
            args.keep_alive_no_task_renew,
            args.keep_alive_renew_lead_time is not None,
            args.keep_alive_location,
            args.keep_alive_location_indicator,
            args.keep_alive_fetch,
            args.keep_alive_processing,
            args.keep_alive_refresh_interval is not None,
        ))
        keep_alive_enabled = bool(args.keep_alive or ka_tuning)
        files_tuning = any((
            args.files_dylib,
            args.files_root,
            args.files_import_dir,
        ))
        files_enabled = bool(args.files or files_tuning) and not args.no_files
        # 悬浮窗默认跟着内置功能一起注入；--no-panel 关掉它
        panel_tuning = bool(args.panel or args.panel_dylib or args.panel_title)
        panel_enabled = bool(
            keep_alive_enabled or files_enabled or panel_tuning
        ) and not args.no_panel
        plist_touched = bool(
            keep_alive_enabled
            or files_enabled
            or panel_enabled
            or args.background_mode
            or args.allow_arbitrary_loads
        )
        if not args.dylib and not plist_touched:
            print(
                "错误：请用 --dylib 指定要注入的库，或用 --keep-alive（后台保活）"
                "/ --files（文件导入导出）注入内置 tweak，或用 --panel 只注入悬浮窗",
                file=sys.stderr,
            )
            return 2

        for path in args.dylib or []:
            if not os.path.isfile(path):
                print(f"错误：找不到 dylib {path}", file=sys.stderr)
                return 2

        print(f"目标 App    : {app.rel}")
        print(f"Bundle ID   : {app.identifier}")

        planned: list[tuple[str, str]] = []  # (dylib 路径, 注入名)
        # 三个功能合编在同一个 IPATool.dylib 里：用到任意一个就只注入这一个 dylib，
        # 没用到的功能在 Info.plist 里显式关掉。只有显式给了某个功能的 dylib 路径时，
        # 才退回老的「一个功能一个 dylib」注入方式
        merged = bool(
            (keep_alive_enabled or files_enabled or panel_enabled)
            and not (args.keep_alive_dylib or args.files_dylib or args.panel_dylib)
        )
        if merged:
            tool_dylib = inject_mod.locate_merged_dylib(
                log=lambda m: print(f"  {m}"),
            )
            planned.append((tool_dylib, inject_mod.MERGED_DYLIB_NAME))
            print(f"内置 tweak  : {tool_dylib}")
            print("              （保活 / 悬浮窗 / 文件导入导出合编在一个 dylib 里，"
                  "没用到的功能在 Info.plist 里关掉）")
        else:
            if keep_alive_enabled:
                ka_dylib = inject_mod.locate_keep_alive_dylib(
                    explicit=args.keep_alive_dylib,
                    log=lambda m: print(f"  {m}"),
                )
                planned.append((ka_dylib, inject_mod.KEEP_ALIVE_DYLIB_NAME))
                print(f"保活 tweak  : {ka_dylib}")
            if files_enabled:
                files_dylib = inject_mod.locate_files_dylib(
                    explicit=args.files_dylib,
                    log=lambda m: print(f"  {m}"),
                )
                planned.append((files_dylib, inject_mod.FILES_DYLIB_NAME))
                print(f"文件导入导出: {files_dylib}")
            if panel_enabled:
                panel_dylib = inject_mod.locate_control_panel_dylib(
                    explicit=args.panel_dylib,
                    log=lambda m: print(f"  {m}"),
                )
                planned.append((panel_dylib, inject_mod.CONTROL_PANEL_DYLIB_NAME))
                print(f"悬浮窗      : {panel_dylib}")
                print("              （App 内会出现可拖动的悬浮按钮，点开即可开关上面这些功能）")
        for path in args.dylib or []:
            planned.append((path, os.path.basename(path)))

        logs: list[str] = []
        for path, name in planned:
            logs += inject_mod.inject_dylib(app, path, name=name, dry_run=args.dry_run)

        changes: list[bundle_mod.Change] = []
        warnings: list[str] = []
        settings: list[tuple[str, dict, str]] = []
        modes: list[str] = list(args.background_mode or [])

        if keep_alive_enabled:
            silent_audio = not args.keep_alive_no_audio
            audio_name = None
            if args.keep_alive_audio_file:
                audio_changes, audio_warnings = inject_mod.place_keep_alive_audio(
                    app, args.keep_alive_audio_file, dry_run=args.dry_run,
                )
                changes += audio_changes
                warnings += audio_warnings
                audio_name = inject_mod.keep_alive_audio_name(args.keep_alive_audio_file)
            ka_options = inject_mod.build_keep_alive_options(
                pip=False if args.keep_alive_no_pip else None,
                silent_audio=False if args.keep_alive_no_audio else None,
                start_on=args.keep_alive_start_on,
                task_renew=False if args.keep_alive_no_task_renew else None,
                renew_lead_time=args.keep_alive_renew_lead_time,
                audio_file=audio_name,
                location=True if args.keep_alive_location else None,
                location_indicator=True if args.keep_alive_location_indicator else None,
                fetch=True if args.keep_alive_fetch else None,
                processing=True if args.keep_alive_processing else None,
                refresh_interval=args.keep_alive_refresh_interval,
            )
            settings.append((inject_mod.KEEP_ALIVE_INFO_KEY, ka_options, "后台保活配置"))
            modes += inject_mod.keep_alive_background_modes(
                pip=not args.keep_alive_no_pip,
                silent_audio=silent_audio,
                location=args.keep_alive_location,
                fetch=args.keep_alive_fetch,
                processing=args.keep_alive_processing,
            )
            if not silent_audio:
                warnings.append("已关闭静音音频，保活只能靠后台任务续期，通常只能多撑几十秒")
        elif merged:
            # 合编 dylib 里保活也会加载，不显式关掉它就会自己开始播静音音频
            settings.append((inject_mod.KEEP_ALIVE_INFO_KEY,
                             inject_mod.build_keep_alive_options(enabled=False), "后台保活配置"))

        if panel_enabled:
            panel_options = inject_mod.build_panel_options(
                title=args.panel_title,
                enabled=True if args.panel else None,
            )
            settings.append((inject_mod.CONTROL_PANEL_INFO_KEY, panel_options, "悬浮窗"))
        elif merged:
            settings.append((inject_mod.CONTROL_PANEL_INFO_KEY,
                             inject_mod.build_panel_options(enabled=False), "悬浮窗"))

        if files_enabled:
            files_options = inject_mod.build_files_options(
                root=args.files_root,
                import_dir=args.files_import_dir,
                enabled=True if args.files else None,
            )
            settings.append((inject_mod.FILES_INFO_KEY, files_options, "文件导入导出"))
            if not panel_enabled:
                warnings.append("没有注入悬浮窗，文件导入导出在 App 里没有入口，建议配合 --panel 使用")
        elif merged:
            settings.append((inject_mod.FILES_INFO_KEY,
                             inject_mod.build_files_options(enabled=False), "文件导入导出"))

        if plist_touched:
            plist_changes, plist_warnings = inject_mod.configure_plist(
                app,
                background_modes=modes,
                settings=settings,
                location=args.keep_alive_location,
                scheduler_ids=inject_mod.keep_alive_scheduler_ids(
                    fetch=args.keep_alive_fetch, processing=args.keep_alive_processing,
                ),
                strip_exit_on_suspend=keep_alive_enabled,
                ats_arbitrary_loads=args.allow_arbitrary_loads,
                file_sharing=files_enabled and not args.no_files_sharing,
                dry_run=args.dry_run,
            )
            changes += plist_changes
            warnings += plist_warnings

        if logs:
            print(f"注入改动 ({len(logs)}):")
            for line in logs:
                print(f"  {line}")
        for c in changes:
            print(f"  {c}")
        for w in warnings:
            print(f"  警告: {w}")

        if args.dry_run:
            print("\n[dry-run] 未写入任何文件")
            return 0

        if args.provision:
            dest = signer.embed_provision(app.path, args.provision)
            print(f"已写入描述文件: {os.path.relpath(dest, root)}")

        code = _package_and_sign(
            args, root, payload, app, workdir,
            unsigned_warning="注入后必须重新签名才能安装（可用 --sign codesign/zsign 配合证书），"
                             "当前输出的是未签名 IPA",
        )
        if not args.provision:
            print("提示: 未指定 --provision，若证书与描述文件不匹配将无法安装；"
                  "注入 dylib 会让原签名失效，必须重签")
        return code
    except (signer.SignError, inject_mod.InjectError) as e:
        print(f"失败: {e}", file=sys.stderr)
        return 1
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    if args.cmd == "gui":
        from .gui import main as gui_main

        return gui_main()
    if args.cmd == "info":
        return cmd_info(args)
    if args.cmd == "certs":
        return cmd_certs(args)
    if args.cmd == "inject":
        return cmd_inject(args)
    return cmd_modify(args)
