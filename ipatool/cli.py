"""ipatool 命令行入口。"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import tempfile
import time

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
    p.add_argument(
        "--zip-level",
        default="auto",
        metavar="auto|0-9",
        help="打包压缩级别（打包是耗时大头）：auto=默认，已经压缩过的资源"
             "（png/mp4/astc…）直接存储、其余 deflate；0=全部存储，最快、体积最大；"
             "1-9=全部 deflate，越小越快",
    )
    p.add_argument("--dry-run", action="store_true", help="只打印将要发生的改动，不写文件")
    p.add_argument("-v", "--verbose", action="store_true")


def _zip_level(args) -> int | None:
    """解析 --zip-level：auto -> None（智能），0 -> 全存储，1-9 -> deflate 等级。"""
    raw = str(getattr(args, "zip_level", "auto") or "auto").strip().lower()
    if raw in ("", "auto"):
        return None
    try:
        level = int(raw)
    except ValueError:
        raise SystemExit(f"错误：--zip-level 只接受 auto 或 0-9，收到 {raw!r}")
    if not 0 <= level <= 9:
        raise SystemExit(f"错误：--zip-level 只能是 0-9，收到 {level}")
    return level


def _zip_level_text(level: int | None) -> str:
    if level is None:
        return "auto（已压缩资源直接存储，其余 deflate）"
    if level == 0:
        return "0（全部存储，最快，体积最大）"
    return f"{level}（deflate）"


def _timed(fn, *args, **kwargs):
    """跑一个步骤并返回 (结果, 用了多少秒)。"""
    start = time.perf_counter()
    result = fn(*args, **kwargs)
    return result, time.perf_counter() - start


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
        help="注入 dylib（内置 --files 文件导入导出、--qnet 弱网测试、--plugins 运行时插件加载）",
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

    qnet = pj.add_argument_group(
        "弱网测试（QNet）",
        "在悬浮窗里打开参数弹窗，实时调限速 / 延迟 / 抖动 / 丢包，"
        "只对当前 App 生效（改的是这个进程自己的 socket 读写，不影响系统设置和其它 App）",
    )
    qnet.add_argument("--qnet", action="store_true", help="注入弱网测试 tweak（不给参数时套用 3G 档默认值）")
    qnet.add_argument("--no-qnet", action="store_true", help="不注入弱网测试 tweak")
    qnet.add_argument("--qnet-dylib", metavar="PATH", help="弱网测试 dylib 路径，默认自动查找（macOS 上会自动编译）")
    qnet.add_argument("--qnet-down", type=int, metavar="KBPS", help="下行带宽上限，KB/s，0 = 不限")
    qnet.add_argument("--qnet-up", type=int, metavar="KBPS", help="上行带宽上限，KB/s，0 = 不限")
    qnet.add_argument("--qnet-delay", type=int, metavar="MS", help="单向附加延迟，毫秒")
    qnet.add_argument("--qnet-jitter", type=int, metavar="MS", help="延迟抖动，毫秒（在延迟上随机 ±该值）")
    qnet.add_argument("--qnet-loss", type=int, metavar="PCT", help="丢包率，0-100")

    plugins = pj.add_argument_group(
        "运行时插件加载（--plugins）",
        "注入一次之后，之后想试的 dylib 只要丢进 App 沙盒就能在悬浮窗里直接加载，"
        "不用再重新打包签名安装（插件必须用签主 App 的同一把证书签名：ipatool signdylib）",
    )
    plugins.add_argument("--plugins", action="store_true", help="注入插件加载器")
    plugins.add_argument("--no-plugins", action="store_true", help="不注入插件加载器")
    plugins.add_argument("--plugins-dylib", metavar="PATH", help="插件加载器 dylib 路径，默认自动查找")
    plugins.add_argument(
        "--plugins-autoload",
        dest="plugins_autoload",
        action="store_true",
        help="启动时自动加载上次加载过的插件（也可在面板里随时开关）",
    )

    panel = pj.add_argument_group(
        "悬浮窗",
        "在 App 里显示一个可拖动的悬浮按钮，点开后操作文件导入导出 / 弱网测试"
        "（默认跟着 --files / --qnet 一起注入）",
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

    psd = sub.add_parser(
        "signdylib",
        help="给单个插件 dylib 签名（运行时 dlopen 加载的前提）",
        description=(
            "给插件 dylib 单独签名。iOS 的 library validation 要求插件和主 App 同一个 Team ID，\n"
            "所以插件必须用签主 App 的那把证书签，否则 dlopen 会报 code signature invalid。\n"
            "只能走 codesign 后端（macOS）：zsign 只能签整个 IPA。"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    psd.add_argument("dylib", help="要签名的 .dylib 文件")
    psd.add_argument(
        "--identity",
        help="证书名称或 SHA-1，和重签 App 时用的那把一致（如 'Apple Development: x (TEAMID)'）",
    )
    psd.add_argument("--p12", help="p12/pfx 证书文件（和 --identity 二选一）")
    psd.add_argument("--p12-password", help="证书密码，也可用 IPATOOL_P12_PASSWORD 环境变量")
    psd.add_argument("--entitlements", help="给这个 dylib 用的 entitlements.plist")
    psd.add_argument("--hardened-runtime", action="store_true", help="启用 hardened runtime")
    psd.add_argument("-v", "--verbose", action="store_true")

    psg = sub.add_parser(
        "sign",
        help="只重新打包 + 重新签名（不改 ID、不注入任何东西）",
        description=(
            "什么都不改，把包解包后按指定证书重新签名再打包。\n"
            "inject / modify 虽然都会顺带签名，但两者都要求至少改点东西；\n"
            "只想「签一下」的时候用这个，不用为了能执行去填一个假的 Bundle ID。\n"
            "签名参数与 inject / modify 完全一致。"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    psg.add_argument("input", help="IPA 文件路径，或已解包且含 Payload 的目录")
    _add_output_args(psg)

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

    # 有证书但本机没有签名工具时，下一步必然踩坑（--sign auto 会落到 none），提前说清楚
    try:
        backend = signer.resolve_backend("auto")
    except signer.SignError as e:
        print(f"\n注意: {e}")
        backend = "none"
    if backend == "none":
        print("\n注意: 本机没有可用的签名工具（macOS 的 codesign / 任意平台的 zsign），"
              "下面这些证书列出来也用不上，注入时只会得到未签名 IPA：")
        for line in signer.auto_backend_hint().splitlines():
            print(f"  {line}")
    elif backend == "zsign":
        print("\n提示: 本机签名会走 zsign（非 macOS 上只能这样），"
              "ID 签名会先从证书存储导出 p12 再交给 zsign")
    return 0


def cmd_signdylib(args) -> int:
    """
    给单个插件 dylib 签名。

    运行时 dlopen 的库必须自带有效签名，而且和主 App 同一个 Team ID
    （iOS 的 library validation），所以插件要用签 App 的那把证书签。
    """
    path = os.path.abspath(args.dylib)
    if not os.path.isfile(path):
        print(f"错误：找不到文件 {path}", file=sys.stderr)
        return 2
    if not ipa_mod.is_macho(path):
        print(f"警告：{path} 不是 Mach-O 文件，codesign 多半会失败", file=sys.stderr)

    try:
        signer.resolve_backend("codesign")
    except signer.SignError as e:
        print(f"失败: {e}", file=sys.stderr)
        print("提示：给单个 dylib 签名只能用 codesign（macOS），zsign 只能签整个 IPA", file=sys.stderr)
        return 1

    want_identity = args.identity if args.identity not in (None, "", "-") else None
    if want_identity is None and not args.p12:
        print("警告：没有指定证书，将按 ad-hoc 签名。ad-hoc 没有 Team ID，"
              "iOS 上基本加载不了（除非主 App 也是 ad-hoc 签的）")

    try:
        with keystore.IdentitySession(
            identity=want_identity,
            p12=args.p12,
            p12_password=args.p12_password,
            backend="codesign",
        ) as ident:
            signer.codesign_one(
                path,
                identity=ident.value,
                entitlements=args.entitlements,
                hardened_runtime=args.hardened_runtime,
                keychain=ident.keychain,
                log=lambda m: print(f"  {m}"),
            )
    except (signer.SignError, RuntimeError, OSError, ValueError) as e:
        print(f"失败: {e}", file=sys.stderr)
        return 1

    print(f"已签名插件  : {path}")
    print("  放进 App 的 Documents（用悬浮窗的「文件导入导出」导入），"
          "再到「插件加载 → 浏览并加载插件…」里点一下就能加载")
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
    """打包 + 按所选后端重签名 + 落盘。

    注入和签名本来就是这一条命令里做完的：解包一次、打包一次、中间把签名一起做掉，
    不需要再拿第二个工具跑一遍（那样会白白多一次解包 + 打包）。
    想只要注入不签名就 `--sign none`。
    """
    out = _output_path(args, workdir)
    backend = signer.resolve_backend(args.sign)
    level = _zip_level(args)
    print(f"重签名后端  : {backend}")
    print(f"打包压缩    : {_zip_level_text(level)}")

    want_identity = args.identity if args.identity not in (None, "", "-") else None
    if backend == "none":
        # 光说「没有可用的签名工具」没用，把原因和两条出路一起打出来
        if args.sign == "auto":
            print("  说明: --sign auto 没找到可用的签名工具，本次只注入、不签名")
            for line in signer.auto_backend_hint().splitlines():
                print(f"        {line}")
        if args.p12 or want_identity:
            print("  警告: 证书参数被忽略（本机没有可用的签名工具），输出的是未签名 IPA")
        elif unsigned_warning:
            print(f"  警告: {unsigned_warning}")

    sign_seconds = 0.0
    archive_seconds = 0.0
    with keystore.IdentitySession(
        identity=want_identity,
        p12=args.p12,
        p12_password=args.p12_password,
        backend=backend,
    ) as ident:
        if backend == "codesign":
            _, sign_seconds = _timed(
                signer.codesign_payload,
                payload,
                identity=ident.value,
                main_app=app.path,
                entitlements=args.entitlements,
                hardened_runtime=args.hardened_runtime,
                keychain=ident.keychain,
                log=lambda m: print(m) if args.verbose else None,
            )
            _, archive_seconds = _timed(ipa_mod.archive, root, out, level)
        elif backend == "zsign":
            unsigned = os.path.join(workdir, "unsigned.ipa")
            # 中间包还要被 zsign 重新打一次，所以这里一律不压缩，省一遍 CPU
            _, archive_seconds = _timed(ipa_mod.archive, root, unsigned, 0)
            _, sign_seconds = _timed(
                signer.zsign_ipa,
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
            _, archive_seconds = _timed(ipa_mod.archive, root, out, level)
            # 显式 --sign none 是用户自己的选择，别再说「未找到可用的签名工具」
            if args.sign != "none":
                print("  警告: 未找到可用的签名工具，输出的是未签名 IPA，设备无法直接安装")

    if backend == "none":
        print(f"阶段耗时    : 打包 {archive_seconds:.1f}s")
    else:
        print(f"阶段耗时    : 签名 {sign_seconds:.1f}s / 打包 {archive_seconds:.1f}s")

    if args.in_place:
        shutil.move(out, os.path.abspath(args.input))
        print(f"已覆盖: {os.path.abspath(args.input)}")
    else:
        print(f"输出: {out}")
    return 0


def cmd_sign(args) -> int:
    """
    只重新打包 + 重新签名：不改 Bundle ID / 名称，也不注入任何 dylib。

    inject / modify 都会顺带把签名做掉，但两者都要求至少改点东西；
    只想「签一下」的时候用这个，不用为了能跑起来而填一个假的 Bundle ID。
    """
    if args.in_place and args.output:
        print("错误：--in-place 与 -o/--output 不能同时使用", file=sys.stderr)
        return 2
    _zip_level(args)   # 参数有问题立刻报错，别等解包都跑完才发现

    workdir = tempfile.mkdtemp(prefix="ipatool-")
    started = time.perf_counter()
    try:
        root, payload, _bundles, app = _open_package(args.input, workdir)
        print(f"解包耗时    : {time.perf_counter() - started:.1f}s")
        print(f"目标 App    : {app.rel}")
        print(f"Bundle ID   : {app.identifier}")
        print("改动        : 无（只重新打包 + 签名）")

        if args.dry_run:
            print("\n[dry-run] 未写入任何文件")
            return 0

        if args.provision:
            dest = signer.embed_provision(app.path, args.provision)
            print(f"已写入描述文件: {os.path.relpath(dest, root)}")

        code = _package_and_sign(
            args, root, payload, app, workdir,
            unsigned_warning="没有可用的签名工具，输出的是未签名 IPA（等于只重新打包）",
        )
        if not args.provision:
            print("提示: 未指定 --provision，若证书与描述文件不匹配将无法安装")
        print(f"总耗时      : {time.perf_counter() - started:.1f}s")
        return code
    except (signer.SignError, inject_mod.InjectError) as e:
        print(f"失败: {e}", file=sys.stderr)
        return 1
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


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
    _zip_level(args)   # 参数有问题立刻报错，别等解包都跑完才发现

    new_bundle_name = args.bundle_name
    workdir = tempfile.mkdtemp(prefix="ipatool-")
    started = time.perf_counter()
    try:
        root, payload, _bundles, app = _open_package(args.input, workdir)
        print(f"解包耗时    : {time.perf_counter() - started:.1f}s")

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
        print(f"总耗时      : {time.perf_counter() - started:.1f}s")
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
    _zip_level(args)   # 参数有问题立刻报错，别等解包+注入都跑完才发现

    workdir = tempfile.mkdtemp(prefix="ipatool-")
    started = time.perf_counter()
    try:
        root, payload, _bundles, app = _open_package(args.input, workdir)
        print(f"解包耗时    : {time.perf_counter() - started:.1f}s")

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

        files_tuning = any((
            args.files_dylib,
            args.files_root,
            args.files_import_dir,
        ))
        files_enabled = bool(args.files or files_tuning) and not args.no_files
        qnet_tuning = any((
            args.qnet_dylib,
            args.qnet_down is not None,
            args.qnet_up is not None,
            args.qnet_delay is not None,
            args.qnet_jitter is not None,
            args.qnet_loss is not None,
        ))
        qnet_enabled = bool(args.qnet or qnet_tuning) and not args.no_qnet
        plugins_tuning = bool(args.plugins_dylib or args.plugins_autoload)
        plugins_enabled = bool(args.plugins or plugins_tuning) and not args.no_plugins
        # 悬浮窗默认跟着内置功能一起注入；--no-panel 关掉它
        panel_tuning = bool(args.panel or args.panel_dylib or args.panel_title)
        panel_enabled = bool(
            files_enabled or qnet_enabled or plugins_enabled or panel_tuning
        ) and not args.no_panel
        plist_touched = bool(
            files_enabled
            or qnet_enabled
            or plugins_enabled
            or panel_enabled
            or args.background_mode
            or args.allow_arbitrary_loads
        )
        if not args.dylib and not plist_touched:
            print(
                "错误：请用 --dylib 指定要注入的库，或用 --files（文件导入导出）"
                "/ --qnet（弱网测试）/ --plugins（运行时插件加载）注入内置 tweak，"
                "或用 --panel 只注入悬浮窗",
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
        # 四个功能合编在同一个 IPATool.dylib 里：用到任意一个就只注入这一个 dylib，
        # 没用到的功能在 Info.plist 里显式关掉。只有显式给了某个功能的 dylib 路径时，
        # 才退回老的「一个功能一个 dylib」注入方式
        merged = bool(
            (files_enabled or qnet_enabled or plugins_enabled or panel_enabled)
            and not (args.files_dylib or args.qnet_dylib or args.plugins_dylib or args.panel_dylib)
        )
        if merged:
            tool_dylib = inject_mod.locate_merged_dylib(
                log=lambda m: print(f"  {m}"),
            )
            planned.append((tool_dylib, inject_mod.MERGED_DYLIB_NAME))
            print(f"内置 tweak  : {tool_dylib}")
            print("              （悬浮窗 / 文件导入导出 / 弱网测试 / 插件加载合编在一个 dylib 里，"
                  "没用到的功能在 Info.plist 里关掉）")
        else:
            if qnet_enabled:
                qnet_dylib = inject_mod.locate_qnet_dylib(
                    explicit=args.qnet_dylib,
                    log=lambda m: print(f"  {m}"),
                )
                planned.append((qnet_dylib, inject_mod.QNET_DYLIB_NAME))
                print(f"弱网测试    : {qnet_dylib}")
            if plugins_enabled:
                plugins_dylib = inject_mod.locate_plugins_dylib(
                    explicit=args.plugins_dylib,
                    log=lambda m: print(f"  {m}"),
                )
                planned.append((plugins_dylib, inject_mod.PLUGINS_DYLIB_NAME))
                print(f"插件加载    : {plugins_dylib}")
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

        if qnet_enabled:
            qnet_options = inject_mod.build_qnet_options(
                enabled=True,
                down=args.qnet_down,
                up=args.qnet_up,
                delay=args.qnet_delay,
                jitter=args.qnet_jitter,
                loss=args.qnet_loss,
                use_defaults=args.qnet,
            )
            settings.append((inject_mod.QNET_INFO_KEY, qnet_options, "弱网测试"))
            if not panel_enabled:
                warnings.append("没有注入悬浮窗，弱网测试在 App 里没有入口，建议配合 --panel 使用")
        elif merged:
            settings.append((inject_mod.QNET_INFO_KEY,
                             inject_mod.build_qnet_options(enabled=False), "弱网测试"))

        if plugins_enabled:
            plugins_options = inject_mod.build_plugins_options(
                enabled=True,
                auto_load=True if args.plugins_autoload else None,
            )
            settings.append((inject_mod.PLUGINS_INFO_KEY, plugins_options, "运行时插件加载"))
            if not panel_enabled:
                warnings.append("没有注入悬浮窗，插件加载在 App 里没有入口，建议配合 --panel 使用")
            if not files_enabled:
                warnings.append("插件要靠「文件导入导出」放进沙盒，建议同时加 --files")
        elif merged:
            settings.append((inject_mod.PLUGINS_INFO_KEY,
                             inject_mod.build_plugins_options(enabled=False), "运行时插件加载"))

        if plist_touched:
            plist_changes, plist_warnings = inject_mod.configure_plist(
                app,
                background_modes=modes,
                settings=settings,
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
        print(f"总耗时      : {time.perf_counter() - started:.1f}s")
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
    if args.cmd == "signdylib":
        return cmd_signdylib(args)
    if args.cmd == "sign":
        return cmd_sign(args)
    return cmd_modify(args)
