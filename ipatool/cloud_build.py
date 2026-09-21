"""GitHub 导入 + Codemagic 云构建 + GitHub Actions 编译 的纯逻辑层（无 GUI）。

只依赖 Python 标准库（urllib / ssl / socket / subprocess），GUI 在 gui.py 里构建，
通过本模块的函数与 GitHub / Codemagic 交互。所有函数都不碰界面，方便单独测试。

来源：原先独立的 github_importer.py，整合进 ipatool 时把界面拆出去、只留逻辑。
"""
from __future__ import annotations

import base64
import json
import os
import shutil
import socket
import subprocess
import time
import webbrowser
import urllib.error
import urllib.request
from urllib.parse import quote, urlparse

OWNER = "Ranshaoer"
REPO = "Tools"
CM_API = "https://api.codemagic.io"
API_BASE = CM_API
DEFAULT_CM_BRANCH = "master"
CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "importer_config.json")


# --------------------------------------------------------------------------- #
# 配置（与界面解耦，单独存一份 importer_config.json，不污染 ipatool 自己的设置）
# --------------------------------------------------------------------------- #
def load_config() -> dict:
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


def save_config(d: dict) -> None:
    try:
        with open(CONFIG_PATH, "w", encoding="utf-8") as fh:
            json.dump(d, fh, ensure_ascii=False, indent=2)
    except Exception:
        pass


# --------------------------------------------------------------------------- #
# 网络底层：直连，解析目标域名全部 IP 逐个试，绕开个别被掐的 IP
# --------------------------------------------------------------------------- #
def _urllib(method, url, headers, body, timeout):
    req = urllib.request.Request(url, data=body, method=method)
    for k, v in headers.items():
        req.add_header(k, v)
    opener = urllib.request.build_opener()
    with opener.open(req, timeout=timeout) as r:
        return r.status, r.read().decode("utf-8")


def _curl(method, url, headers, body, timeout, ip=None):
    curl = shutil.which("curl") or "curl"
    cmd = [curl, "-sS", "-X", method, url,
           "--connect-timeout", "20", "--max-time", str(timeout), "-w", "\n%{http_code}", "-4"]
    if ip:
        host = urlparse(url).netloc
        cmd += ["--connect-to", f"{host}:443:{ip}:443"]
    for k, v in headers.items():
        cmd += ["-H", f"{k}: {v}"]
    if body is not None:
        cmd += ["--data-binary", body]
    p = subprocess.run(cmd, capture_output=True, timeout=timeout + 15)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode("utf-8", "replace").strip()[:200])
    text = p.stdout.decode("utf-8", "replace")
    if "\n" in text:
        body_text, _, code = text.rpartition("\n")
    else:
        body_text, code = "", text.strip()
    try:
        status = int(code.strip())
    except Exception:
        status = 0
    return status, body_text


def _http_request(method, url, headers, body=None, timeout=30):
    """直连：解析全部 IP 逐个试，绕开坏 IP。"""
    host = urlparse(url).netloc
    ips = []
    try:
        ips = sorted({i[4][0] for i in socket.getaddrinfo(host, 443)})
    except Exception:
        ips = []
    try:
        return _urllib(method, url, headers, body, timeout)
    except Exception as e:
        last = f"默认: {e}"
    for ip in ips:
        try:
            return _curl(method, url, headers, body, timeout, ip=ip)
        except Exception as e:
            last = f"{ip}: {e}"
    raise RuntimeError("直连均失败(已试全部 IP): " + last)


def _parse(text, default=None):
    try:
        return json.loads(text) if text else (default or {})
    except Exception:
        return default or {}


def _download_binary(url, headers, path, timeout=180):
    """下载二进制文件（直连，解析全部 IP 逐个试）。"""
    host = urlparse(url).netloc
    ips = []
    try:
        ips = sorted({i[4][0] for i in socket.getaddrinfo(host, 443)})
    except Exception:
        ips = []
    last_err = None
    try:
        req = urllib.request.Request(url)
        for k, v in headers.items():
            req.add_header(k, v)
        opener = urllib.request.build_opener()
        with opener.open(req, timeout=timeout) as r:
            data = r.read()
        with open(path, "wb") as fh:
            fh.write(data)
        return
    except Exception as e:
        last_err = e
    for ip in ips:
        curl = shutil.which("curl") or "curl"
        cmd = [curl, "-sS", url, "-o", path,
               "--connect-timeout", "20", "--max-time", str(timeout),
               "--connect-to", f"{host}:443:{ip}:443"]
        for k, v in headers.items():
            cmd += ["-H", f"{k}: {v}"]
        p = subprocess.run(cmd, capture_output=True, timeout=timeout + 15)
        if p.returncode == 0:
            return
        last_err = RuntimeError(p.stderr.decode("utf-8", "replace").strip()[:200])
    raise RuntimeError(f"下载失败: {last_err}")


# --------------------------------------------------------------------------- #
# GitHub / Codemagic API
# --------------------------------------------------------------------------- #
def api_call(method, url, token, data=None):
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "github-importer",
        "Content-Type": "application/json",
    }
    body = json.dumps(data).encode("utf-8") if data is not None else None
    try:
        status, text = _http_request(method, url, headers, body, timeout=30)
        if status >= 400:
            try:
                msg = json.loads(text).get("message", text)
            except Exception:
                msg = text
            raise RuntimeError(f"HTTP {status}: {msg}")
        return status, _parse(text)
    except RuntimeError:
        raise
    except Exception as e:
        raise RuntimeError(f"网络错误: {e}")


def cm_call(method, path, token, data=None):
    headers = {"X-Auth-Token": token, "Content-Type": "application/json"}
    body = json.dumps(data).encode("utf-8") if data is not None else None
    try:
        status, text = _http_request(method, CM_API + path, headers, body, timeout=60)
        if status >= 400:
            try:
                msg = json.loads(text).get("message", text)
            except Exception:
                msg = text
            raise RuntimeError(f"HTTP {status}: {msg}")
        return status, _parse(text)
    except RuntimeError:
        raise
    except Exception as e:
        raise RuntimeError(f"网络错误: {e}")


# --------------------------------------------------------------------------- #
# 下载 GitHub Actions 产物 / Release（archive_download_url 会 302 到签名地址，
# 第二跳不带鉴权，避免 Bearer Token 泄露到 githubusercontent）
# --------------------------------------------------------------------------- #
def download_redirect_safe(archive_url, token, path, timeout=180):
    import urllib.request as U

    class _NoRedirect(U.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            raise U.HTTPError(req.get_full_url(), code, msg, headers, fp)

    def opener():
        return U.build_opener(_NoRedirect)

    req = U.Request(archive_url, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "github-importer",
    })
    data = None
    try:
        with opener().open(req, timeout=timeout) as r:
            data = r.read()
    except U.HTTPError as e:
        if e.code in (301, 302, 303, 307, 308):
            loc = e.headers.get("Location")
            if not loc:
                raise RuntimeError("重定向缺少 Location")
            data = U.urlopen(loc, timeout=timeout).read()
        else:
            raise RuntimeError(f"下载产物 HTTP {e.code}")
    if not data:
        raise RuntimeError("未获取到数据")
    with open(path, "wb") as fh:
        fh.write(data)


def dl_release_dylib(owner, repo, out_dir, token):
    base = f"https://api.github.com/repos/{owner}/{repo}"
    _, j = api_call("GET", f"{base}/releases?per_page=30", token)
    for rel in (j if isinstance(j, list) else j.get("releases", [])):
        if any(a.get("name") == "IPATool.dylib" for a in rel.get("assets", [])):
            url = (f"https://github.com/{owner}/{repo}/releases/download/"
                   f"{rel['tag_name']}/IPATool.dylib")
            path = os.path.join(out_dir, "IPATool.dylib")
            _download_binary(url, {}, path, timeout=180)
            return path
    raise RuntimeError("Releases 里没有 IPATool.dylib")


def dl_artifact_dylib(token, owner, repo, run_id, out_dir):
    import zipfile
    base = f"https://api.github.com/repos/{owner}/{repo}"
    _, j = api_call("GET", f"{base}/actions/runs/{run_id}/artifacts", token)
    arts = j.get("artifacts", [])
    art = next((a for a in arts if a.get("name") in ("ipatool-tweaks", "build-artifacts")), None)
    if not art:
        raise RuntimeError("该运行没有 ipatool-tweaks 产物")
    zip_path = os.path.join(out_dir, "ipatool-tweaks.zip")
    download_redirect_safe(art["archive_download_url"], token, zip_path)
    with zipfile.ZipFile(zip_path) as z:
        names = [n for n in z.namelist() if n.endswith("IPATool.dylib")]
        if not names:
            raise RuntimeError("zip 里没有 IPATool.dylib")
        data = z.read(names[0])
    path = os.path.join(out_dir, "IPATool.dylib")
    with open(path, "wb") as fh:
        fh.write(data)
    return path


def dl_artifact_ipa(token, owner, repo, run_id, out_dir, workflow_file="build-ipa.yml"):
    import zipfile
    base = f"https://api.github.com/repos/{owner}/{repo}"
    if run_id:
        _, j = api_call("GET", f"{base}/actions/runs/{run_id}/artifacts", token)
        arts = j.get("artifacts", [])
        if not arts:
            raise RuntimeError("该运行没有产物")
    else:
        _, j = api_call("GET",
                        f"{base}/actions/workflows/{workflow_file}/runs?per_page=10&status=success", token)
        runs = j.get("workflow_runs", [])
        if not runs:
            raise RuntimeError("该工作流没有成功过的运行")
        _, j = api_call("GET", f"{base}/actions/runs/{runs[0]['id']}/artifacts", token)
        arts = j.get("artifacts", [])
    art = next((a for a in arts if "ipa" in (a.get("name") or "").lower()), None)
    if not art:
        names = ", ".join(a.get("name", "") for a in arts) or "无"
        raise RuntimeError(f"没有 IPA 产物(现有: {names})")
    zip_path = os.path.join(out_dir, art["name"] + ".zip")
    download_redirect_safe(art["archive_download_url"], token, zip_path)
    with zipfile.ZipFile(zip_path) as z:
        inners = [n for n in z.namelist() if n.endswith(".ipa")]
        if not inners:
            raise RuntimeError("产物 zip 里没有 .ipa 文件")
        data = z.read(inners[0])
    path = os.path.join(out_dir, os.path.basename(inners[0]))
    with open(path, "wb") as fh:
        fh.write(data)
    return path


# --------------------------------------------------------------------------- #
# GitHub 导入（把本地文件夹逐文件推到仓库；空仓库首个文件会自动建默认分支）
# --------------------------------------------------------------------------- #
def import_to_github(token, owner, repo, branch, files, target="",
                     visibility="public", auto_create=False):
    """把 files[(rel, full), ...] 推到 owner/repo@branch 的 target 路径下。

    返回 (msg, created)。仓库不存在且 auto_create=True 时自动在 Token 对应账号下创建。
    """
    from urllib.parse import quote as _q
    created = False
    if auto_create:
        try:
            api_call("GET", f"https://api.github.com/repos/{owner}/{repo}", token)
        except RuntimeError:
            try:
                _, uj = api_call("GET", "https://api.github.com/user", token)
                login = uj.get("login")
                if login and login != owner:
                    owner = login
            except RuntimeError:
                pass
            private = (visibility == "私有")
            api_call("POST", "https://api.github.com/user/repos", token,
                     {"name": repo, "private": private,
                      "description": "Imported via ipatool", "auto_init": False})
            created = True
    base_api = f"https://api.github.com/repos/{owner}/{repo}"
    total = len(files)
    for i, (rel, full) in enumerate(files, 1):
        # 规范化：两侧斜杠都去掉，避免生成 "/foo" 或 "//foo"
        # （GitHub Contents API 的 path 不能以斜杠开头，否则 422）
        t = target.strip().strip("/")
        r = rel.replace("\\", "/").strip().strip("/")
        path = "/".join(p for p in (t, r) if p)
        try:
            with open(full, "rb") as fh:
                content = base64.b64encode(fh.read()).decode("ascii")
        except OSError as e:
            raise RuntimeError(f"读取本地文件失败 {full}: {e}")
        sha = None
        try:
            _, gj = api_call("GET", f"{base_api}/contents/{_q(path)}?ref={_q(branch)}", token)
            sha = gj.get("sha") if isinstance(gj, dict) else None
        except RuntimeError:
            pass
        payload = {"message": f"Add {repo} from local folder", "content": content}
        if sha:
            payload["sha"] = sha
        try:
            api_call("PUT", f"{base_api}/contents/{_q(path)}", token, payload)
        except RuntimeError as e:
            msg = str(e)
            if ".github/workflows" in msg:
                msg += ("\n提示: 上传工作流文件需要 Token 含 workflow 权限，"
                        "请重新生成 Token 并同时勾选 repo 与 workflow。")
            raise RuntimeError(f"[上传 {path}] {msg}")
    msg = f"✅ 导入成功! {total} 个文件 -> {owner}/{repo}@{branch}"
    return msg, created


# --------------------------------------------------------------------------- #
# GitHub Actions 编译（触发 workflow，等运行生成，查状态，下载产物）
# --------------------------------------------------------------------------- #
def trigger_github_actions(token, owner, repo, workflow_file, branch="main"):
    """触发 workflow 并阻塞等到新运行记录出现，返回 (run_id, html_url)。"""
    base = f"https://api.github.com/repos/{owner}/{repo}"
    pre_ids = None
    try:
        _, pj = api_call("GET", f"{base}/actions/workflows/{workflow_file}/runs?per_page=20", token)
        pre_ids = {r["id"] for r in pj.get("workflow_runs", [])}
    except RuntimeError:
        pass
    api_call("POST", f"{base}/actions/workflows/{workflow_file}/dispatches", token, {"ref": branch})
    dispatch_time = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 120))
    waited = 0
    while waited < 300:
        try:
            _, j = api_call("GET", f"{base}/actions/workflows/{workflow_file}/runs?per_page=10", token)
            runs_all = j.get("workflow_runs", [])
            if pre_ids is not None:
                runs = [r for r in runs_all if r["id"] not in pre_ids]
            else:
                runs = [r for r in runs_all if r.get("created_at", "") >= dispatch_time]
            if runs:
                r = runs[0]
                return r["id"], r.get("html_url", f"{base}/actions/runs/{r['id']}")
        except RuntimeError:
            pass
        waited += 5
        time.sleep(5)
    raise RuntimeError("触发后 5 分钟内未出现新的 Actions 运行记录")


def get_actions_run_status(token, owner, repo, run_id):
    """返回 (status, conclusion)。"""
    base = f"https://api.github.com/repos/{owner}/{repo}"
    _, j = api_call("GET", f"{base}/actions/runs/{run_id}", token)
    return j.get("status"), j.get("conclusion")


def download_actions_artifact(token, owner, repo, workflow_file, branch, out_dir,
                              artifact_name=None):
    """下载某 workflow 最近一次成功运行的产物并解压到 out_dir，返回 out_dir。

    artifact_name 为子串过滤（如 "dylib"）；为空则取第一个产物。
    """
    import zipfile
    base = f"https://api.github.com/repos/{owner}/{repo}"
    _, j = api_call("GET",
                    f"{base}/actions/workflows/{workflow_file}/runs?per_page=10&status=success",
                    token)
    runs = j.get("workflow_runs", [])
    if not runs:
        raise RuntimeError(f"工作流 {workflow_file} 没有成功过的运行")
    run_id = runs[0]["id"]
    _, j = api_call("GET", f"{base}/actions/runs/{run_id}/artifacts", token)
    arts = j.get("artifacts", [])
    art = next((a for a in arts if (artifact_name is None
                                    or artifact_name in (a.get("name") or ""))), None)
    if art is None:
        names = ", ".join(a.get("name", "") for a in arts) or "无"
        raise RuntimeError(f"没有匹配的产物(现有: {names})")
    os.makedirs(out_dir, exist_ok=True)
    zip_path = os.path.join(out_dir, art["name"] + ".zip")
    download_redirect_safe(art["archive_download_url"], token, zip_path)
    with zipfile.ZipFile(zip_path) as z:
        z.extractall(out_dir)
    return out_dir


# --------------------------------------------------------------------------- #
# Codemagic 构建
# --------------------------------------------------------------------------- #
def list_codemagic_apps(token):
    """返回 {显示名: app_id} 的字典。"""
    _, j = cm_call("GET", "/apps", token)
    apps = j.get("applications", [])
    app_map = {}
    for a in apps:
        app_id = a.get("_id") or a.get("appId") or a.get("id")
        name = a.get("appName") or a.get("name") or "?"
        disp = f"{name} ({app_id})"
        if app_id:
            app_map[disp] = app_id
    return app_map


def importer_start_codemagic_build(token, app_id, branch=None, workflow_id=None):
    """触发 Codemagic 构建，返回 (build_id, 控制台 url)。"""
    wf = workflow_id or "ios-demo"
    branch = branch or "main"
    body = {"appId": app_id, "workflowId": wf, "branch": branch}
    _, j = cm_call("POST", "/builds", token, body)
    b = j.get("build", j)
    build_id = b.get("id") or j.get("buildId")
    url = f"https://codemagic.io/builds/{build_id}"
    return build_id, url


def poll_codemagic_build(token, build_id):
    """返回 (status, finished, artifacts)。finished 表示终态。"""
    _, j = cm_call("GET", f"/builds/{build_id}", token)
    b = j.get("build", j)
    status = b.get("status")
    arts = b.get("artifacts", [])
    finished = status in ("finished", "success", "failed", "canceled", "timeout", "skipped")
    return status, finished, arts


def download_codemagic_artifacts(token, build_id, dest):
    """下载构建产物到 dest，返回成功保存的文件路径列表（失败项改用浏览器兜底）。"""
    _, j = cm_call("GET", f"/builds/{build_id}", token)
    b = j.get("build", j)
    arts = b.get("artifacts", [])
    saved = []
    os.makedirs(dest, exist_ok=True)
    for a in arts:
        url = a.get("url")
        name = a.get("name") or "artifact"
        if not url:
            continue
        if "api.codemagic.io" in url and "token=" not in url:
            url = url + ("&" if "?" in url else "?") + "token=" + token
        path = os.path.join(dest, name)
        try:
            _download_binary(url, {"X-Auth-Token": token}, path, timeout=180)
            saved.append(path)
        except Exception:
            try:
                webbrowser.open(url)
            except Exception:
                pass
    return saved
