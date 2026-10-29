"""GitHub 导入 + Codemagic 云构建 + GitHub Actions 编译 的纯逻辑层（无 GUI）。

只依赖 Python 标准库（urllib / ssl / socket / subprocess），GUI 在 gui.py 里构建，
通过本模块的函数与 GitHub / Codemagic 交互。所有函数都不碰界面，方便单独测试。

来源：原先独立的 github_importer.py，整合进 ipatool 时把界面拆出去、只留逻辑。
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import tempfile
import time
import webbrowser
import zipfile
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
    tmp_path = None
    try:
        if body is not None:
            # Windows 命令行有长度上限（WinError 206），大 body 必须走临时文件
            data = body if isinstance(body, bytes) else body.encode("utf-8")
            with tempfile.NamedTemporaryFile("wb", delete=False, suffix=".bin") as tf:
                tf.write(data)
                tmp_path = tf.name
            cmd += ["--data-binary", "@" + tmp_path]
        p = subprocess.run(cmd, capture_output=True, timeout=timeout + 15)
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
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


def _parse_repo(url: str, default_branch: str = "main"):
    """从各种写法里抠出 (owner, repo)；分支沿用传入值（默认 main）。"""
    s = url.strip().rstrip("/")
    s = re.sub(r"\.git$", "", s, flags=re.IGNORECASE)
    m = re.search(r"github\.com[:/]+([^/\s]+)/([^/\s]+)", s)
    if m:
        return m.group(1), m.group(2)
    m = re.match(r"^([^/\s]+)/([^/\s]+)$", s)          # 允许直接写 owner/repo
    if m:
        return m.group(1), m.group(2)
    raise ValueError(f"无法解析 GitHub 仓库地址: {url}")


def export_repo(url, branch, out_dir, token="", log=print, timeout=300):
    """把仓库源码打包下载并解压到本地目录（等价 git archive 下载，不含 .git 历史）。

    branch 可为分支 / 标签 / 提交；私有仓库传 token（走 Authorization 头）。
    """
    owner, repo = _parse_repo(url, branch)
    archive_url = f"https://codeload.github.com/{owner}/{repo}/zip/{branch}"
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    os.makedirs(out_dir, exist_ok=True)
    tmp = os.path.join(out_dir, f".{repo}-{branch}.zip.tmp")
    log(f"[导出] {owner}/{repo}@{branch} 开始下载 …")
    _download_binary(archive_url, headers, tmp, timeout=timeout)
    log("[导出] 下载完成，正在解压 …")
    _extract_zip(tmp, out_dir)
    try:
        os.remove(tmp)
    except OSError:
        pass
    log(f"[导出] 已导出到 {out_dir}")


def _extract_zip(zip_path, out_dir):
    with zipfile.ZipFile(zip_path, "r") as z:
        bad = z.testzip()
        if bad is not None:
            raise RuntimeError(f"压缩包损坏: {bad}")
        z.extractall(out_dir)


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
# GitHub 导入（差量上传：远端树比对 + 只传改动 + 合并成 1 个提交）
# --------------------------------------------------------------------------- #
def _git_blob_sha(data: bytes) -> str:
    """算文件的 git blob SHA-1，用于和远端树比对，判断文件是否真的变了。"""
    h = hashlib.sha1()
    h.update(b"blob %d\0" % len(data))
    h.update(data)
    return h.hexdigest()


def import_to_github(token, owner, repo, branch, files, target="",
                     visibility="public", auto_create=False, log=print):
    """把 files[(rel, full), ...] 推到 owner/repo@branch 的 target 路径下。

    差量上传：先 2 次请求拉远端整棵树，本地算 blob 哈希比对，只上传有变化的
    文件，并合并成 **1 个提交**（老实现每文件 2 次请求 + 各一个提交，几百个
    文件既慢还会连环触发 Actions）。不删除远端多出来的文件：本地列表常带大小
    过滤，镜像删除容易误删，宁可多留。

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
    base = f"https://api.github.com/repos/{owner}/{repo}"
    target = target.strip().strip("/")

    # 1) 读本地文件、算哈希（不走网络）
    local: dict[str, bytes] = {}
    for rel, full in files:
        r = rel.replace("\\", "/").strip().strip("/")
        path = "/".join(p for p in (target, r) if p)
        try:
            with open(full, "rb") as fh:
                local[path] = fh.read()
        except OSError as e:
            raise RuntimeError(f"读取本地文件失败 {full}: {e}")

    # 2) 拉远端整棵树（2 次请求）；分支不存在/空仓库时按全量新上传处理
    remote: dict[str, str] = {}
    head_sha = head_tree_sha = None
    try:
        _, rj = api_call("GET", f"{base}/git/ref/heads/{_q(branch)}", token)
        head_sha = rj["object"]["sha"]
        _, tj = api_call("GET", f"{base}/git/trees/{head_sha}?recursive=1", token)
        head_tree_sha = tj.get("sha")
        for e in tj.get("tree", []):
            if e.get("type") == "blob":
                remote[e["path"]] = e["sha"]
    except RuntimeError:
        pass

    # 3) 差异比对：只传真变了/新增的
    changed = [(p, d) for p, d in local.items() if _git_blob_sha(d) != remote.get(p)]
    unchanged = len(local) - len(changed)
    if not changed:
        return (f"✅ 无改动，{unchanged} 个文件远端已是最新，跳过上传", created)

    # 4) 只为变化的文件建 blob，然后 1 个 tree + 1 个 commit + 1 次 ref 更新
    tree_entries = []
    for i, (path, data) in enumerate(changed, 1):
        _, bj = api_call("POST", f"{base}/git/blobs", token,
                         {"content": base64.b64encode(data).decode("ascii"),
                          "encoding": "base64"})
        tree_entries.append({"path": path, "mode": "100644",
                             "type": "blob", "sha": bj["sha"]})
        log(f"  [{i}/{len(changed)}] {path}")

    tree_payload: dict = {"tree": tree_entries}
    if head_tree_sha:
        tree_payload["base_tree"] = head_tree_sha
    _, ntj = api_call("POST", f"{base}/git/trees", token, tree_payload)

    commit_payload = {"message": f"Add {repo} from local folder",
                      "tree": ntj["sha"],
                      "parents": [head_sha] if head_sha else []}
    _, cj = api_call("POST", f"{base}/git/commits", token, commit_payload)

    if head_sha:
        api_call("PATCH", f"{base}/git/refs/heads/{_q(branch)}", token,
                 {"sha": cj["sha"], "force": False})
    else:
        api_call("POST", f"{base}/git/refs", token,
                 {"ref": f"refs/heads/{branch}", "sha": cj["sha"]})

    msg = (f"✅ 导入成功! {len(changed)} 个文件有改动已上传"
           f"（{unchanged} 个未变跳过），合并为 1 个提交 -> {owner}/{repo}@{branch}")
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
