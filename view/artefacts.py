# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

"""What a session left behind: the repos and folders it changed, and its git milestones.

Read from the archive's readable transcript, which every harness renders in one shape
(bin/render-{transcript,opencode,codex}.sh): a tool call is `**→ <tool>**` and a fenced input, its
result `**⎿ output:**` (or `error:`) and a fenced output. So one parser covers Claude, opencode and
codex, and it reads only what scrubjay already archived.

Two stages, because only the second depends on this machine:
  facts(md, cwd)      the transcript alone → files written, git/gh events, and the remotes the
                      session's own output named. Pure, so it is cached on disk per transcript.
  Resolver.links(...) facts → artefacts. A directory with no remote in the transcript is asked
                      (`git remote get-url`) only when the session ran on this machine.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import PurePosixPath

CALL = re.compile(r"^\*\*→ (?P<name>[^*]+)\*\*\s*$")
RESULT = re.compile(r"^\*\*⎿ (?P<kind>output|error):\*\*\s*$")

WRITE_TOOLS = {"edit", "write", "multiedit", "notebookedit", "patch", "apply_patch", "create_file",
               "str_replace_editor", "str_replace_based_edit_tool"}
SHELL_TOOLS = {"bash", "shell", "exec_command", "local_shell", "run_shell_command"}
PATH_KEYS = ("file_path", "filePath", "notebook_path", "path", "filename")
PATCH_FILE = re.compile(r"\*\*\* (?:Add|Update|Delete) File: ([^\n\\]+)")

# Places a session writes that are not work product: scratch space.
SCRATCH = re.compile(r"^(?:/tmp/|/private/tmp/|/var/folders/|/dev/)|/scratchpad/")


# ── the transcript as tool calls ─────────────────────────────────────────────────────────────

def _fence(lines: list[str], i: int, nest: bool = False) -> tuple[str | None, int]:
    """The fenced block starting at or after line i (blank lines skipped): its body, and the line
    after it. The renderers open a fence with a language (```bash, ```text) and close it bare. A
    command can carry fences of its own (a heredoc writing Markdown, even a transcript like this
    one), so with `nest` a tagged opener inside the block nests and the bare ``` that ends it is
    matched. Only for a command: it was written whole. An output is often cut off mid-block
    (`head -40`), and an unclosed opener there would swallow the rest of the transcript."""
    j = i
    while j < len(lines) and not lines[j].strip():
        j += 1
    if j >= len(lines) or not lines[j].startswith("```"):
        return None, i
    body, j, depth = [], j + 1, 0
    while j < len(lines):
        ln = lines[j].rstrip()
        if ln == "```":
            if depth == 0:
                break
            depth -= 1
        elif nest and re.match(r"^```[\w+-]+$", ln):
            depth += 1
        body.append(lines[j])
        j += 1
    return "\n".join(body), j + 1


def calls(md: str) -> list[dict]:
    """Every tool call with its input and, where the transcript has it, its output. Results arrive
    in call order (parallel calls first, then their results), so they are paired first-in first-out."""
    lines = md.split("\n")
    out: list[dict] = []
    pending: list[dict] = []
    i = 0
    while i < len(lines):
        m = CALL.match(lines[i])
        if m:
            body, i = _fence(lines, i + 1, nest=True)
            c = {"name": m.group("name").strip(), "input": body or "", "output": "", "error": False}
            out.append(c)
            pending.append(c)
            continue
        m = RESULT.match(lines[i])
        if m:
            body, i = _fence(lines, i + 1)
            if pending:
                c = pending.pop(0)
                c["output"], c["error"] = body or "", m.group("kind") == "error"
            continue
        i += 1
    return out


# ── remotes ──────────────────────────────────────────────────────────────────────────────────

_REMOTE = [
    re.compile(r"^(?:ssh://)?[\w.-]+@(?P<host>[\w.-]+)(?::\d+)?[:/](?P<path>[\w./~-]+?)(?:\.git)?/?$"),
    re.compile(r"^(?:https?|git)://(?:[^@/\s]+@)?(?P<host>[\w.-]+)(?::\d+)?/(?P<path>[\w./~-]+?)(?:\.git)?/?$"),
    re.compile(r"^(?P<host>[\w-]+(?:\.[\w-]+)+):(?P<path>[\w./~-]+?)(?:\.git)?/?$"),  # github.com:o/r
]


def remote_id(url: str) -> dict | None:
    """A git remote, in any spelling, as {id, kind, label, url}; None for a local path."""
    url = url.strip().strip("'\"")
    for rx in _REMOTE:
        m = rx.match(url)
        if m:
            host, path = m.group("host").lower(), m.group("path").strip("/")
            if "/" not in path:
                return None
            kind = "github" if host == "github.com" else "gitlab" if "gitlab" in host else "git"
            return {"id": f"{host}/{path}", "kind": kind, "label": path,
                    "url": f"https://{host}/{path}", "host": host}
    return None


# Forge URLs for one PR/MR, issue or release, and the repo each names. GitHub repos are owner/name;
# GitLab's may nest groups, and its object paths start at `/-/`. Only these name a repo: any other URL
# in an output (an API listing, a link in a README) says nothing about what the session changed.
_PULL = re.compile(r"https://(?:github\.com/[\w.-]+/[\w.-]+/pull|[\w.-]*gitlab[\w.-]*/[\w./-]+?/-/merge_requests)/(\d+)")
_ISSUE = re.compile(r"https://(?:github\.com/[\w.-]+/[\w.-]+|[\w.-]*gitlab[\w.-]*/[\w./-]+?/-)/issues/(\d+)")
_RELEASE = re.compile(r"https://github\.com/[\w.-]+/[\w.-]+/releases/tag/(\S+)")
_REPO_OF = re.compile(r"^(https://github\.com/[\w.-]+/[\w.-]+|https://[\w.-]*gitlab[\w.-]*/[\w./-]+?)(?:/-)?/(?:pull|merge_requests|issues|releases)/")


def _repo_of(url: str) -> dict | None:
    m = _REPO_OF.match(url)
    return remote_id(m.group(1)) if m else None


def _named_remotes(text: str) -> dict[str, dict]:
    """`git remote -v` output: {name: remote}."""
    out = {}
    for name, url in re.findall(r"^(\S+)\s+(\S+)\s+\((?:fetch|push)\)$", text, re.M):
        r = remote_id(url)
        if r:
            out.setdefault(name, r)
    return out


def _repo_flag(cmd: str, tool: str) -> dict | None:
    """`gh … -R owner/name` is a GitHub repo, `glab … -R group/name` a GitLab one."""
    m = re.search(rf"\b{tool}\b[^\n;&|]*?(?:--repo|-R)[= ]\s*['\"]?([\w.-]+(?:/[\w.-]+)+)", cmd)
    if not m:
        return None
    return remote_id(("https://github.com/" if tool == "gh" else "https://gitlab.com/") + m.group(1))


# ── one shell command → directory and events ─────────────────────────────────────────────────

_WORD = r"(\"[^\"]+\"|'[^']+'|[^\s;&|()]+)"
_CD = re.compile(r"(?:^|&&|;|\|\||\n|\()\s*cd\s+(?:-[LPe@]+\s+)*" + _WORD)
_GIT_C = re.compile(r"\bgit\s+-C\s+" + _WORD)
_RESET = re.compile(r"Shell cwd was reset to (\S+)")
_HOME = re.compile(r"^(/home/[^/]+|/Users/[^/]+|/root)(?=/|$)")


def _unq(s: str) -> str:
    return s[1:-1] if len(s) > 1 and s[0] == s[-1] and s[0] in "'\"" else s


def _resolve(path: str, base: str, home: str) -> str | None:
    path = _unq(path)
    if "$" in path or "`" in path or not path or path == "-":
        return None
    if path == "~" or path.startswith("~/"):
        if not home:
            return None
        path = home + path[1:]
    if not path.startswith("/"):
        if not base:
            return None
        path = base.rstrip("/") + "/" + path
    return os.path.normpath(path)


def _msg(cmd: str) -> str:
    """A commit's subject line, from the command: -m "…", or the first line of a heredoc."""
    m = re.search(r"\s(?:-[a-zA-Z]*m\s*|--message[= ])(\"(?:[^\"\\]|\\.)*\"|'[^']*')", cmd)
    if m and not m.group(1)[1:].startswith("$("):
        return _unq(m.group(1)).replace('\\"', '"').strip().split("\n")[0]
    m = re.search(r"<<-?\s*['\"]?(\w+)['\"]?\n(.*?)\n", cmd, re.S)
    return m.group(2).strip() if m else ""


def _title(cmd: str) -> str:
    m = re.search(r"--title\s+(\"(?:[^\"\\]|\\.)*\"|'[^']*')", cmd)
    return _unq(m.group(1)).replace('\\"', '"') if m else ""


def _failed(c: dict) -> bool:
    o = c["output"]
    return c["error"] or bool(re.search(r"^(?:error|fatal|GraphQL|ERROR):|Exit code [1-9]|failed to|"
                                        r"denied|\brejected\b|could not", o, re.M | re.I))


# Where a command can start: the beginning, after a separator, a pipe, `$(`, `then`/`do`, or a few
# VAR=value assignments. `grep 'gh pr create' …` names the words without running them.
_AT = r"(?:^|(?<=[;&|(\n])|(?<=\$\()|(?<=\bthen\b)|(?<=\bdo\b)|(?<=\bxargs\b))\s*(?:[A-Za-z_]\w*=\S*\s+)*"

# `gh api` / `glab api` writing to a forge: how a session opens PRs/MRs or issues in bulk, or from
# a helper. The endpoint names the repo (GitLab URL-encodes it: projects/group%2Fname).
_API = re.compile(_AT + r"(?P<cli>gh|glab)\s+api\b(?P<args>[^\n;&|]*)", re.M)
_ENDPOINT = re.compile(r"['\"]?/?(?:projects/(?P<gl>[^/\s'\"?]+)|repos/(?P<gh>[\w.-]+/[\w.-]+))"
                       r"/(?P<what>merge_requests|pulls|issues)(?:/(?P<n>\d+)(?:/(?P<sub>merge|notes|comments))?)?\b")


def _api_events(cmd: str, mask: str, c: dict) -> list[tuple[int, dict]]:
    from urllib.parse import unquote
    ev: list[tuple[int, dict]] = []
    out = c["output"]
    if _failed(c):
        return ev
    for m in _each(_API.pattern, cmd, mask):
        args = m.group("args")
        meth = re.search(r"(?:-X|--method)[= ]\s*['\"]?([A-Z]+)", args)
        method = meth.group(1) if meth else ("POST" if re.search(r"\s-[fF]\s|--(?:raw-)?field\b|--input\b", args) else "GET")
        e = _ENDPOINT.search(args)
        if method == "GET" or not e:
            continue
        forge = "gitlab" if m.group("cli") == "glab" else "github"
        repo = None
        if e.group("gl") and "$" not in e.group("gl"):
            repo = remote_id("https://gitlab.com/" + unquote(e.group("gl")))
        elif e.group("gh"):
            repo = remote_id("https://github.com/" + e.group("gh"))
        tag = {"forge": forge, **({"remote": repo["id"]} if repo else {})}
        what, n, sub = e.group("what"), e.group("n"), e.group("sub")
        pr = what in ("merge_requests", "pulls")
        if sub == "merge" and method == "PUT":
            ev.append((m.start(), {"type": "pr_merge", "n": int(n), **tag}))
        elif sub in ("notes", "comments") and method == "POST":
            ev.append((m.start(), {"type": "issue_comment", "n": int(n), **tag}))
        elif not n and method == "POST":
            # The numbers it created. GitLab's own `!N` first: a URL in the same output may belong to
            # a listing the command printed afterwards. Else the URLs it printed.
            nums = []
            if pr and forge == "gitlab":
                nums = list(dict.fromkeys(int(x) for x in re.findall(r"!(\d+)\b", out)))
            if not nums:
                rx = _PULL if pr else _ISSUE
                nums = list(dict.fromkeys(int(u.group(1)) for u in rx.finditer(out)))
            for k in nums:
                ev.append((m.start(), {"type": "pr_open" if pr else "issue_open", "n": k, "title": "", **tag}))
    return ev


_HEREDOC = re.compile(r"<<(-?)\s*(['\"]?)(\w+)\2")


def _code(cmd: str) -> str:
    """The command without its heredoc bodies: text it writes somewhere (a file, a commit message, a
    script handed to python) is not something it ran, even when that text spells `gh pr merge 42`."""
    out, end = [], None
    for line in cmd.split("\n"):
        if end is not None:
            if (line.strip() if end[0] else line) == end[1]:
                end = None
            continue
        out.append(line)
        m = _HEREDOC.search(line)
        if m:
            end = (m.group(1) == "-", m.group(3))
    return "\n".join(out)


def _mask(cmd: str) -> str:
    """The command with every quoted span blanked (same length): a command never starts inside
    quotes, and `grep 'gh pr create\\|git commit'` must not read as two of them."""
    out, q, i = list(cmd), "", 0
    while i < len(cmd):
        ch = cmd[i]
        if q:
            if ch == "\\" and q == '"' and i + 1 < len(cmd):
                out[i] = out[i + 1] = "_"
                i += 2
                continue
            if ch == q:
                q = ""
            else:
                out[i] = "_" if ch != "\n" else "\n"
        elif ch in "'\"":
            q = ch
        i += 1
    return "".join(out)


def _each(rx: str, cmd: str, mask: str):
    """Matches of rx found in the masked command, read back from the real one at the same place."""
    pat = re.compile(rx, re.M)
    for m in pat.finditer(mask):
        yield pat.match(cmd, m.start()) or m


def _first(rx: str, cmd: str, mask: str):
    return next(_each(rx, cmd, mask), None)


def _shell_events(full: str, c: dict) -> list[dict]:
    """The git milestones one command made, in the order it made them."""
    ev: list[tuple[int, dict]] = []
    out = c["output"]
    cmd = _code(full)
    mask = _mask(cmd)
    m = _first(_AT + r"git\b(?:\s+-C\s+\S+)?\s+commit\b", cmd, mask)
    if m and "nothing to commit" not in out and not c["error"]:
        shas = re.findall(r"^\[[^\]\s]+(?: \(root-commit\))? ([0-9a-f]{7,40})\] (.+)$", out, re.M)
        if shas:
            ev += [(m.start(), {"type": "commit", "sha": s, "title": t}) for s, t in shas]
        else:
            ev.append((m.start(), {"type": "commit", "title": _msg(full)}))
    for m in _each(_AT + r"git\b(?:\s+-C\s+\S+)?\s+push\b([^;&|\n]*)", cmd, mask):
        if _failed(c):
            break
        # `git push [opts] [remote [refspec…]]`: options and redirections are not names.
        words = [w for w in m.group(1).split() if not w.startswith("-") and not re.match(r"^\d*[<>]", w)]
        e = {"type": "push"}
        if words and "$" not in words[0]:
            e["remote_name"] = words[0]
        if len(words) > 1 and "$" not in words[1]:
            e["branch"] = words[1].split(":")[-1].strip("'\"")
        to = re.search(r"^To (\S+)$", out, re.M)
        if to and remote_id(to.group(1)):
            e["remote"] = remote_id(to.group(1))["id"]
        ev.append((m.start(), e))
    for m in _each(_AT + r"git\b(?:\s+-C\s+\S+)?\s+(?:checkout\s+(?:-q\s+)?-b|switch\s+(?:-q\s+)?(?:-c|--create))\s+([^\s;&|]+)", cmd, mask):
        ev.append((m.start(), {"type": "branch", "branch": m.group(1)}))
    for cli, noun, forge in (("gh", "pr", "github"), ("glab", "mr", "gitlab")):
        flag = _repo_flag(cmd, cli)
        tag = {"forge": forge, **({"remote": flag["id"]} if flag else {})}
        m = _first(_AT + rf"{cli} {noun} create\b", cmd, mask)
        if m:
            # One command may open several (a helper called once per branch): every URL counts.
            urls = list(dict.fromkeys(u.group(0) for u in _PULL.finditer(out)))
            title = _title(cmd) if len(urls) == 1 else ""
            for u in urls:
                r = _repo_of(u)
                ev.append((m.start(), {"type": "pr_open", "n": int(u.rsplit("/", 1)[1]), "url": u, "title": title,
                                       **tag, **({"remote": r["id"]} if r else {})}))
        for m in _each(_AT + rf"{cli} {noun} (merge|close|reopen)\b(?:\s+(\d+))?", cmd, mask):
            if not _failed(c):
                e = {"type": f"pr_{m.group(1)}", **tag}
                if m.group(2):
                    e["n"] = int(m.group(2))
                ev.append((m.start(), e))
        m = _first(_AT + rf"{cli} issue create\b", cmd, mask)
        if m:
            urls = list(dict.fromkeys(u.group(0) for u in _ISSUE.finditer(out)))
            title = _title(cmd[m.start():]) if len(urls) == 1 else ""
            for u in urls:
                r = _repo_of(u)
                ev.append((m.start(), {"type": "issue_open", "n": int(u.rsplit("/", 1)[1]), "url": u, "title": title,
                                       **tag, **({"remote": r["id"]} if r else {})}))
        for m in _each(_AT + rf"{cli} issue (close|comment|reopen)\s+(\d+)", cmd, mask):
            if not _failed(c):
                ev.append((m.start(), {"type": f"issue_{m.group(1)}", "n": int(m.group(2)), **tag}))
    ev += _api_events(cmd, mask, c)
    m = _first(_AT + r"gh release create\s+([^\s;&|]+)", cmd, mask)
    if m and not _failed(c):
        e = {"type": "release", "tag": _unq(m.group(1)), "forge": "github"}
        flag = _repo_flag(cmd, "gh")
        if flag:
            e["remote"] = flag["id"]
        u = _RELEASE.search(out)
        if u:
            e["url"] = u.group(0)
            r = _repo_of(u.group(0))
            if r:
                e["remote"] = r["id"]
        ev.append((m.start(), e))
    return [e for _, e in sorted(ev, key=lambda x: x[0])]


def facts(md: str, cwd: str) -> dict:
    """The transcript alone → {files: {path: n}, events: [...], remotes: {dir: [remote…]},
    names: {dir: {remote-name: remote}}, repos: {id: remote}}. Every event carries the directory it
    ran in and, where its own command or output said, its repo; the rest is resolved later."""
    home_m = _HOME.match(cwd or "")
    home = home_m.group(1) if home_m else ""
    here = cwd or ""
    files: dict[str, int] = {}
    events: list[dict] = []
    remotes: dict[str, list[dict]] = {}
    names: dict[str, dict[str, dict]] = {}
    repos: dict[str, dict] = {}

    for c in calls(md):
        name = c["name"].lower()
        if name in WRITE_TOOLS and not c["error"]:
            paths: list[str] = []
            try:
                j = json.loads(c["input"])
            except ValueError:
                j = None
            if isinstance(j, dict):
                paths += [j[k] for k in PATH_KEYS if isinstance(j.get(k), str)]
                for k in ("patch", "input", "patchText"):
                    if isinstance(j.get(k), str):
                        paths += PATCH_FILE.findall(j[k])
            elif isinstance(j, str):
                paths += PATCH_FILE.findall(j)
            else:
                paths += PATCH_FILE.findall(c["input"])
            for p in paths:
                r = _resolve(p.strip(), here, home)
                if r:
                    files[r] = files.get(r, 0) + 1
            continue
        if name not in SHELL_TOOLS:
            continue
        cmd = c["input"]
        cds = _CD.findall(cmd)
        start = here
        for d in cds:
            r = _resolve(d, start, home)
            if r:
                start = r
        gm = _GIT_C.search(cmd)
        where = (_resolve(gm.group(1), start, home) if gm else None) or start
        if re.search(r"\b(?:git|gh|glab)\b", cmd):
            if re.search(r"\bgit\b[^\n;&|]*\bremote\b", cmd):
                for nm, r in _named_remotes(c["output"]).items():
                    names.setdefault(where, {}).setdefault(nm, r)
                    repos[r["id"]] = r
            for e in _shell_events(cmd, c):
                e["dir"] = where
                if e.get("remote"):
                    r = remote_id("https://" + e["remote"])
                    if r:
                        repos[r["id"]] = r
                        lst = remotes.setdefault(where, [])
                        if all(x["id"] != r["id"] for x in lst):
                            lst.append(r)
                events.append(e)
        reset = _RESET.search(c["output"])
        here = reset.group(1) if reset else start
    return {"files": files, "events": events, "remotes": remotes, "names": names, "repos": repos}


# ── facts → artefacts ────────────────────────────────────────────────────────────────────────

def _git(args: list[str]) -> str:
    try:
        r = subprocess.run(["git", *args], capture_output=True, text=True, timeout=5)
        return r.stdout.strip() if r.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


class Resolver:
    """Events and files → repos. Answers about this machine's folders are cached for the server's
    lifetime."""

    def __init__(self, this_host: str):
        self.host = this_host
        self.cache: dict[str, tuple[str, dict[str, dict]]] = {}

    def local(self, d: str) -> tuple[str, dict[str, dict]]:
        """(repo root or "", {remote name: remote}) for a folder on THIS machine."""
        if d in self.cache:
            return self.cache[d]
        p = d
        while p and p != "/" and not os.path.isdir(p):  # a file's folder may be gone; ask its parent
            p = os.path.dirname(p)
        root = _git(["-C", p, "rev-parse", "--show-toplevel"]) if p and p != "/" else ""
        self.cache[d] = (root, _named_remotes(_git(["-C", root, "remote", "-v"])) if root else {})
        return self.cache[d]

    def links(self, f: dict, host: str, cwd: str) -> list[dict]:
        """One entry per artefact the session touched: {artefact, events, files}."""
        local = host == self.host
        seen = f.get("remotes", {})      # dir -> [remote], each named by an event's own evidence
        named = f.get("names", {})       # dir -> {name: remote}, from `git remote -v` it ran
        repos = f.get("repos", {})
        out: dict[str, dict] = {}

        def under(d: str, table: dict):
            """The entry for d or the nearest folder above it."""
            best = ""
            for k in table:
                if (d == k or d.startswith(k.rstrip("/") + "/")) and len(k) > len(best):
                    best = k
            return table.get(best) if best else None

        def remotes_of(d: str) -> tuple[str, dict[str, dict], list[dict]]:
            """(local repo root, {name: remote}, [remotes seen]) for folder d."""
            root, names = self.local(d) if local else ("", {})
            names = {**names, **(under(d, named) or {})}
            return root, names, list(under(d, seen) or [])

        def pick(e: dict, d: str) -> dict | None:
            if e.get("remote"):                                   # its own command or output said
                return repos.get(e["remote"]) or remote_id("https://" + e["remote"])
            root, names, seen_here = remotes_of(d)
            pool = list(names.values()) + seen_here
            if e.get("forge"):                                     # gh → GitHub, glab → GitLab
                return next((r for r in pool if r["kind"] == e["forge"]), None)
            if e.get("remote_name"):                               # git push <name> …
                nm = e["remote_name"]
                if nm in names:
                    return names[nm]
                hint = next((k for k in ("github", "gitlab") if k in nm), None)
                if hint:
                    return next((r for r in pool if r["kind"] == hint), None)
            if "origin" in names:                                  # a commit, a branch: origin's
                return names["origin"]
            if pool:
                return pool[0]
            if root:
                return {"id": f"git:{host}:{root}", "kind": "repo", "label": _tail(root), "path": root, "host": host}
            return None

        def add(a: dict) -> dict:
            return out.setdefault(a["id"], {"artefact": a, "events": [], "files": []})

        for e in f.get("events", []):
            d = e.get("dir") or cwd or ""
            # Scratch space is no repo of yours, unless the command itself named one (`-R`, a URL).
            if SCRATCH.search(d + "/") and not e.get("remote"):
                continue
            rem = pick(e, d) or {"id": f"git:{host}:{d}", "kind": "repo", "label": _tail(d), "path": d, "host": host}
            ev = {k: v for k, v in e.items() if k not in ("dir", "remote", "forge", "remote_name")}
            add(rem)["events"].append(ev)

        for path, n in f.get("files", {}).items():
            if SCRATCH.search(path):
                continue
            a = _record(path, host, cwd)
            if not a:
                d = os.path.dirname(path)
                a = pick({}, d) if (local or under(d, named) or under(d, seen)) else None
                if not a:
                    inside = cwd and (path == cwd or path.startswith(cwd.rstrip("/") + "/"))
                    folder = cwd if inside else d
                    a = {"id": f"dir:{host}:{folder}", "kind": "folder", "label": _tail(folder),
                         "path": folder, "host": host}
            add(a)["files"].append(path)

        # A PR merged without its number (`gh pr merge` on the current branch) is the one opened here.
        for e in out.values():
            once, kept = set(), []
            for x in e["events"]:   # opened twice (a retry, a listing): once
                k = (x["type"], x.get("n")) if x["type"] in ("pr_open", "issue_open") and "n" in x else None
                if k and k in once:
                    continue
                once.add(k) if k else None
                kept.append(x)
            e["events"] = kept
            opened = [x["n"] for x in e["events"] if x["type"] == "pr_open"]
            for x in e["events"]:
                if x["type"] in ("pr_merge", "pr_close") and "n" not in x and opened:
                    x["n"] = opened[-1]
            a = e["artefact"]
            for x in e["events"]:
                if "n" in x and "url" not in x and a["kind"] in ("github", "gitlab"):
                    pr = x["type"].startswith("pr_")
                    x["url"] = (f"{a['url']}/{'pull' if pr else 'issues'}/{x['n']}" if a["kind"] == "github"
                                else f"{a['url']}/-/{'merge_requests' if pr else 'issues'}/{x['n']}")
                if x.get("sha") and a["kind"] in ("github", "gitlab"):
                    x["url"] = f"{a['url']}{'/-' if a['kind'] == 'gitlab' else ''}/commit/{x['sha']}"
            e["files"].sort()
        return list(out.values())


def minus(child: dict, parent: dict) -> dict:
    """A fork's transcript starts with its parent's whole history; keep only what came after."""
    seen: dict[str, int] = {}
    for e in parent.get("events", []):
        k = json.dumps(e, sort_keys=True)
        seen[k] = seen.get(k, 0) + 1
    events = []
    for e in child.get("events", []):
        k = json.dumps(e, sort_keys=True)
        if seen.get(k):
            seen[k] -= 1
        else:
            events.append(e)
    pf = parent.get("files", {})
    files = {p: n - pf.get(p, 0) for p, n in child.get("files", {}).items() if n > pf.get(p, 0)}
    return {**child, "events": events, "files": files}


def moved(path: str, pairs: list[tuple[str, str]]) -> str:
    """Where a path is now, by the moves of its machine (longest old path first)."""
    for old, new in pairs:
        if path == old or path.startswith(old + "/"):
            return new + path[len(old):]
    return path


def relocate(f: dict, pairs: list[tuple[str, str]]) -> dict:
    """Facts with their paths where they are now, so a moved repo still resolves, and old sessions
    meet new ones on one artefact. The facts themselves stay as the transcript has them."""
    if not pairs:
        return f
    files: dict[str, int] = {}
    for p, n in f.get("files", {}).items():
        q = moved(p, pairs)
        files[q] = files.get(q, 0) + n
    return {**f, "files": files,
            "events": [{**e, "dir": moved(e["dir"], pairs)} if e.get("dir") else e for e in f.get("events", [])],
            "remotes": {moved(d, pairs): v for d, v in f.get("remotes", {}).items()},
            "names": {moved(d, pairs): v for d, v in f.get("names", {}).items()}}


def _record(path: str, host: str, cwd: str = "") -> dict | None:
    """scrubjay's own records: cross-machine memory and plans."""
    if "/.claude/plans/" in path:
        return {"id": f"plans:{host}", "kind": "record", "label": "plans", "path": os.path.dirname(path), "host": host}
    m = re.search(r"/\.claude/projects/([^/]+)/memory/", path) or re.search(r"/scrubjay-memory/([^/]+)/", path)
    if m:
        # A Claude project dir is its folder's path with / turned into -; the folder's own name is
        # what a person calls it, which is the part after the parent the session also lives under.
        name = m.group(1)
        if name.startswith("-") and cwd and name == re.sub(r"[^A-Za-z0-9]", "-", cwd):
            name = os.path.basename(cwd)
        elif name.startswith("-"):
            name = re.sub(r"^.*-(?:Code|code|Projects|projects|home-[^-]+)-", "", name) or name
        return {"id": "memory:" + re.sub(r"[-_]", "-", name.lower()), "kind": "record", "label": f"memory · {name}",
                "path": os.path.dirname(path), "host": ""}
    return None


def _tail(p: str) -> str:
    parts = PurePosixPath(p).parts
    return "/".join(parts[-2:]) if len(parts) > 2 else p


def summary(link: dict) -> str:
    """One line for an edge: what the session did to this artefact."""
    ev = link["events"]
    bits = []
    word, mark = ("MR", "!") if link["artefact"]["kind"] == "gitlab" else ("PR", "#")
    merged = sorted({x["n"] for x in ev if x["type"] == "pr_merge" and "n" in x})
    opened = sorted({x["n"] for x in ev if x["type"] == "pr_open" and "n" in x} - set(merged))
    if merged:
        bits.append(f"{word} {' '.join(mark + str(n) for n in merged)} merged")
    if opened:
        bits.append(f"{word} {' '.join(mark + str(n) for n in opened)} opened")
    issues = sorted({x["n"] for x in ev if x["type"] == "issue_open" and "n" in x})
    if issues:
        bits.append(f"issue {' '.join('#' + str(n) for n in issues)}")
    comments = sorted({x["n"] for x in ev if x["type"] == "issue_comment" and "n" in x})
    if comments:
        bits.append(f"comment on {' '.join('#' + str(n) for n in comments)}")
    rel = [x["tag"] for x in ev if x["type"] == "release"]
    if rel:
        bits.append(f"release {', '.join(rel)}")
    commits = sum(1 for x in ev if x["type"] == "commit")
    if commits:
        bits.append(f"{commits} commit{'s' if commits != 1 else ''}")
    if link["files"]:
        n = len(link["files"])
        bits.append(f"{n} file{'s' if n != 1 else ''}")
    return " · ".join(bits) or "git activity"
