"""
签名身份（证书）管理。

支持两种签名方式：
  - ID 签名  : 使用系统中已安装的证书身份（macOS 钥匙串名称 / SHA-1，Windows 证书指纹）
  - 证书签名 : 直接提供 .p12 / .pfx 证书文件（macOS 会导入到临时钥匙串后再签名）
"""
from __future__ import annotations

import getpass
import json
import os
import platform
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass

from .signer import SignError

# security find-identity 的输出行：  1) ABCD... "Apple Development: xxx (TEAMID)"
_IDENTITY_RE = re.compile(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.*?)"\s*$')
_THUMBPRINT_RE = re.compile(r"^[0-9A-Fa-f]{40}$")


@dataclass
class Identity:
    """一个可用的签名身份。"""

    id: str  # codesign 用：SHA-1；Windows 用：指纹
    name: str  # 证书通用名称
    source: str  # keychain / windows-store / p12

    def __str__(self) -> str:
        return f"{self.id}  {self.name}  [{self.source}]"


def _err(r: subprocess.CompletedProcess) -> str:
    return (
        r.stderr.decode("utf-8", "replace").strip()
        or r.stdout.decode("utf-8", "replace").strip()
        or f"exit code {r.returncode}"
    )


def _run(cmd: list[str]) -> subprocess.CompletedProcess:
    r = subprocess.run(cmd, capture_output=True, check=False)
    if r.returncode != 0:
        raise SignError(f"命令失败: {' '.join(cmd)}\n{_err(r)}")
    return r


def _ps(script: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True,
        check=False,
    )


# --------------------------------------------------------------------------- #
# 列举可用身份
# --------------------------------------------------------------------------- #
def find_identities(keychain: str | None = None) -> list[Identity]:
    """macOS：列出钥匙串中可用于代码签名的身份。"""
    if platform.system() != "Darwin":
        return []
    cmd = ["security", "find-identity", "-v", "-p", "codesigning"]
    if keychain:
        cmd.append(keychain)
    r = subprocess.run(cmd, capture_output=True, check=False)
    text = r.stdout.decode("utf-8", "replace")
    out: list[Identity] = []
    for line in text.splitlines():
        m = _IDENTITY_RE.match(line)
        if m:
            out.append(Identity(id=m.group(1), name=m.group(2), source="keychain"))
    return out


def _windows_identities() -> list[Identity]:
    script = (
        "Get-ChildItem Cert:\\CurrentUser\\My, Cert:\\LocalMachine\\My -ErrorAction SilentlyContinue | "
        "Where-Object { $_.HasPrivateKey } | "
        "Select-Object Thumbprint,Subject,NotAfter | ConvertTo-Json"
    )
    r = _ps(script)
    raw = r.stdout.decode("utf-8", "replace").strip()
    if not raw:
        return []
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if isinstance(data, dict):
        data = [data]
    out = []
    for item in data:
        tp = (item.get("Thumbprint") or "").strip()
        if _THUMBPRINT_RE.match(tp):
            out.append(Identity(id=tp.upper(), name=item.get("Subject") or "", source="windows-store"))
    return out


def list_identities() -> tuple[list[Identity], str]:
    """返回 (身份列表, 说明文字)。"""
    system = platform.system()
    if system == "Darwin":
        return find_identities(), "macOS 钥匙串（security find-identity）"
    if system == "Windows":
        return _windows_identities(), "Windows 证书存储 - 个人（含私钥）"
    return [], "当前平台不支持列举系统证书，请使用 --p12 指定证书文件"


# --------------------------------------------------------------------------- #
# macOS 临时钥匙串
# --------------------------------------------------------------------------- #
class TempKeychain:
    """创建一个临时钥匙串用于导入 p12，用完即删，不污染用户钥匙串。"""

    def __init__(self) -> None:
        self._dir = tempfile.mkdtemp(prefix="ipatool-kc-")
        self.path = os.path.join(self._dir, "ipatool.keychain-db")
        self.password = secrets.token_hex(8)

    def __enter__(self) -> "TempKeychain":
        _run(["security", "create-keychain", "-p", self.password, self.path])
        subprocess.run(
            ["security", "set-keychain-settings", "-lut", "21600", self.path],
            capture_output=True,
            check=False,
        )
        _run(["security", "unlock-keychain", "-p", self.password, self.path])
        return self

    def import_p12(self, p12_path: str, p12_password: str, want: str | None = None) -> str:
        """导入 p12 并返回可用于 codesign 的身份标识（SHA-1）。"""
        base = [
            "security", "import", p12_path,
            "-k", self.path,
            "-f", "pkcs12",
            "-P", p12_password,
            "-T", "/usr/bin/codesign",
        ]
        r = subprocess.run(base + ["-A"], capture_output=True, check=False)
        if r.returncode != 0:  # 新版 macOS 可能不接受 -A
            r = subprocess.run(base, capture_output=True, check=False)
            if r.returncode != 0:
                raise SignError(f"导入证书失败（密码错误或文件损坏？）:\n{_err(r)}")

        # 避免签名时弹窗要求授权
        subprocess.run(
            ["security", "set-key-partition-list",
             "-S", "apple-tool:,apple:,codesign:",
             "-s", "-k", self.password, self.path],
            capture_output=True,
            check=False,
        )

        ids = find_identities(self.path)
        if not ids:
            raise SignError("证书已导入，但其中没有可用的代码签名身份（缺少私钥或已过期）")

        if want:
            low = want.lower().strip()
            for i in ids:
                if low in (i.id.lower(), i.name.lower()) or low in i.name.lower():
                    return i.id
            raise SignError(
                f"证书中没有匹配 `{want}` 的身份，该证书包含：\n  "
                + "\n  ".join(str(i) for i in ids)
            )
        return ids[0].id

    def __exit__(self, *exc) -> None:
        subprocess.run(["security", "delete-keychain", self.path], capture_output=True, check=False)
        shutil.rmtree(self._dir, ignore_errors=True)


# --------------------------------------------------------------------------- #
# Windows 证书存储 -> 临时 p12
# --------------------------------------------------------------------------- #
def export_windows_identity(thumbprint: str, dest_dir: str, password: str) -> str:
    """按指纹从 Windows 证书存储导出 p12（要求私钥可导出）。"""
    tp = thumbprint.strip().replace(" ", "").upper()
    if not _THUMBPRINT_RE.match(tp):
        raise SignError(f"Windows 证书指纹应为 40 位十六进制字符串: {thumbprint}")

    out = os.path.join(dest_dir, "identity.p12")
    pw = password.replace("'", "''")
    script = (
        "$ErrorActionPreference='Stop'\n"
        "$c = Get-ChildItem Cert:\\CurrentUser\\My, Cert:\\LocalMachine\\My -ErrorAction SilentlyContinue |\n"
        "  Where-Object { $_.Thumbprint -eq '" + tp + "' -and $_.HasPrivateKey } | Select-Object -First 1\n"
        "if (-not $c) { exit 2 }\n"
        "$sec = ConvertTo-SecureString -String '" + pw + "' -AsPlainText -Force\n"
        "Export-PfxCertificate -Cert $c -FilePath '" + out.replace("'", "''") + "' -Password $sec | Out-Null\n"
    )
    r = _ps(script)
    if r.returncode != 0 or not os.path.isfile(out):
        raise SignError(
            "从 Windows 证书存储导出失败：证书不存在、不含私钥或私钥不可导出。\n"
            "可直接提供证书文件：--p12 cert.p12\n"
            + _err(r)
        )
    return out


# --------------------------------------------------------------------------- #
# 统一入口
# --------------------------------------------------------------------------- #
def _prompt_password() -> str:
    if not sys.stdin.isatty():
        raise SignError("未提供证书密码，请用 --p12-password 或环境变量 IPATOOL_P12_PASSWORD 指定")
    return getpass.getpass("证书密码: ")


class IdentitySession:
    """
    根据「ID 签名」或「证书签名」准备好签名所需的身份 / 证书，并在结束时清理临时资源。

    用法：
        with IdentitySession(identity=..., p12=..., backend="codesign") as s:
            s.value         # codesign 的 --sign 参数
            s.keychain      # codesign 的 --keychain 参数（可能为 None）
            s.p12_path      # zsign 的 -k 参数
            s.p12_password  # zsign 的 -p 参数
    """

    def __init__(
        self,
        identity: str | None = None,
        p12: str | None = None,
        p12_password: str | None = None,
        backend: str = "auto",
    ) -> None:
        self.identity = identity
        self.p12 = p12
        self._p12_password = p12_password
        self.backend = backend

        self.value: str = "-"
        self.keychain: str | None = None
        self.p12_path: str | None = None
        self.p12_password: str | None = None
        self._keychain: TempKeychain | None = None
        self._tmpdir: str | None = None

    def __enter__(self) -> "IdentitySession":
        if self.backend == "none":  # 不签名，证书参数仅忽略
            self.value = self.identity or "-"
            self.p12_path = self.p12
            self.p12_password = self._p12_password
            return self

        if self.p12 and not os.path.isfile(self.p12):
            raise SignError(f"找不到证书文件: {self.p12}")

        password = self._p12_password
        if self.p12 and password is None:
            password = os.environ.get("IPATOOL_P12_PASSWORD") or _prompt_password()

        if self.backend == "codesign":
            if self.p12:
                kc = TempKeychain()
                kc.__enter__()
                self._keychain = kc
                self.keychain = kc.path
                self.value = kc.import_p12(self.p12, password or "", want=self.identity)
                print(f"证书签名: 已导入 {os.path.basename(self.p12)} -> {self.value}")
            elif self.identity:
                self.value = self.identity
                print(f"ID 签名  : {self.identity}")
            else:
                self.value = "-"
                print("ID 签名  : ad-hoc（未指定证书，签名后无法安装到未越狱设备）")
            self.p12_path = self.p12
            self.p12_password = password

        elif self.backend == "zsign":
            if self.p12:
                self.p12_path = self.p12
                self.p12_password = password
                print(f"证书签名: {os.path.basename(self.p12)}")
            elif self.identity and platform.system() == "Windows":
                self._tmpdir = tempfile.mkdtemp(prefix="ipatool-cert-")
                pw = secrets.token_hex(8)
                self.p12_path = export_windows_identity(self.identity, self._tmpdir, pw)
                self.p12_password = pw
                print(f"ID 签名  : 已从 Windows 证书存储导出 {self.identity}")
            elif self.identity:
                raise SignError(
                    "zsign 需要 p12 证书文件；当前平台无法按 ID 从系统证书存储导出。\n"
                    "请改用 --p12 cert.p12（macOS 上建议 --sign codesign --identity <ID>）"
                )
            else:
                raise SignError("zsign 需要证书：请用 --p12 cert.p12（证书签名）或 --identity <指纹>（ID 签名）")
        else:
            self.value = self.identity or "-"
            self.p12_path = self.p12
            self.p12_password = password

        return self

    def __exit__(self, *exc) -> None:
        if self._keychain:
            self._keychain.__exit__()
            self._keychain = None
        if self._tmpdir:
            shutil.rmtree(self._tmpdir, ignore_errors=True)
            self._tmpdir = None
