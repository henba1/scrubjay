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

def _fence(lines: list[str], i: int) -> tuple[str | None, int]:
    """The fenced block starting at or after line i (blank lines skipped): its body, and the line
    after it. The renderers close a fence with a bare ``` line, so the first one ends it."""
    j = i
    while j < len(lines) and not lines[j].strip():
        j += 1
    if j >= len(lines) or not lines[j].startswith("```"):
        return None, i
    body, j = [], j + 1
    while j < len(lines) and lines[j].rstrip() != "```":
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
            body, i = _fence(lines, i + 1)
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


# A forge URL in a command's output, and the repo it names. GitHub repos are owner/name; GitLab's
# may nest groups, and its object paths start at `/-/`.
_GH_URL = re.compile(r"https://github\.com/(?P<path>[\w.-]+/[\w.-]+?)(?:\.git)?(?=[/\s)\]'\"#?]|$)")
_GL_URL = re.compile(r"https://(?P<host>[\w.-]*gitlab[\w.-]*)/(?P<path>[\w.-]+(?:/[\w.-]+)+?)/-/")
_PULL = re.compile(r"https://(?:github\.com/[\w.-]+/[\w.-]+/pull|[\w.-]*gitlab[\w.-]*/[\w./-]+?/-/merge_requests)/(\d+)")
_ISSUE = re.compile(r"https://(?:github\.com/[\w.-]+/[\w.-]+|[\w.-]*gitlab[\w.-]*/[\w./-]+?/-)/issues/(\d+)")
_RELEASE = re.compile(r"https://github\.com/[\w.-]+/[\w.-]+/releases/tag/(\S+)")


def _remote_in(text: str) -> dict | None:
    m = _GH_URL.search(text)
    if m:
        return remote_id(f"https://github.com/{m.group('path')}")
    m = _GL_URL.search(text)
    if m:
        return remote_id(f"https://{m.group('host')}/{m.group('path')}")
    m = re.search(r"^To (\S+)$", text, re.M)  # git push
    if m:
        return remote_id(m.group(1))
    m = re.search(r"^origin\s+(\S+)\s+\((?:fetch|push)\)$", text, re.M)  # git remote -v
    if m:
        return remote_id(m.group(1))
    return None


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


def _shell_events(cmd: str, c: dict) -> list[dict]:
    """The git milestones one command made, in the order it made them."""
    ev: list[tuple[int, dict]] = []
    out = c["output"]
    m = re.search(r"\bgit\b(?:\s+-C\s+\S+)?\s+commit\b", cmd)
    if m and "nothing to commit" not in out and not c["error"]:
        shas = re.findall(r"^\[[^\]\s]+(?: \(root-commit\))? ([0-9a-f]{7,40})\] (.+)$", out, re.M)
        if shas:
            ev += [(m.start(), {"type": "commit", "sha": s, "title": t}) for s, t in shas]
        else:
            ev.append((m.start(), {"type": "commit", "title": _msg(cmd)}))
    for m in re.finditer(r"\bgit\b(?:\s+-C\s+\S+)?\s+push\b([^;&|\n]*)", cmd):
        if _failed(c):
            break
        # `git push [opts] [remote [refspec…]]`: options and redirections are not names.
        words = [w for w in m.group(1).split() if not w.startswith("-") and not re.match(r"^\d*[<>]", w)]
        e = {"type": "push"}
        if len(words) > 1 and "$" not in words[1]:
            e["branch"] = words[1].split(":")[-1].strip("'\"")
        ev.append((m.start(), e))
    for m in re.finditer(r"\bgit\b(?:\s+-C\s+\S+)?\s+(?:checkout\s+(?:-q\s+)?-b|switch\s+(?:-q\s+)?(?:-c|--create))\s+([^\s;&|]+)", cmd):
        ev.append((m.start(), {"type": "branch", "branch": m.group(1)}))
    for tool in ("gh pr", "glab mr"):
        m = re.search(rf"\b{tool} create\b", cmd)
        if m:
            u = _PULL.search(out)
            if u:
                ev.append((m.start(), {"type": "pr_open", "n": int(u.group(1)), "url": u.group(0), "title": _title(cmd)}))
        for m in re.finditer(rf"\b{tool} (merge|close|reopen)\b(?:\s+(\d+))?", cmd):
            if not _failed(c):
                e = {"type": f"pr_{m.group(1)}"}
                if m.group(2):
                    e["n"] = int(m.group(2))
                ev.append((m.start(), e))
    for tool in ("gh issue", "glab issue"):
        m = re.search(rf"\b{tool} create\b", cmd)
        if m:
            u = _ISSUE.search(out)
            if u:
                ev.append((m.start(), {"type": "issue_open", "n": int(u.group(1)), "url": u.group(0), "title": _title(cmd[m.start():])}))
        for m in re.finditer(rf"\b{tool} (close|comment|reopen)\s+(\d+)", cmd):
            if not _failed(c):
                ev.append((m.start(), {"type": f"issue_{m.group(1)}", "n": int(m.group(2))}))
    m = re.search(r"\bgh release create\s+([^\s;&|]+)", cmd)
    if m and not _failed(c):
        e = {"type": "release", "tag": _unq(m.group(1))}
        u = _RELEASE.search(out)
        if u:
            e["url"] = u.group(0)
        ev.append((m.start(), e))
    return [e for _, e in sorted(ev, key=lambda x: x[0])]


def facts(md: str, cwd: str) -> dict:
    """The transcript alone → {files: {path: n}, events: [...], remotes: {dir: remote}, dirs: [...]}.
    Every event carries the directory it ran in, so a later step can tell which repo it belongs to."""
    home_m = _HOME.match(cwd or "")
    home = home_m.group(1) if home_m else ""
    here = cwd or ""
    files: dict[str, int] = {}
    events: list[dict] = []
    remotes: dict[str, dict] = {}
    git_dirs: set[str] = set()

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
            rem = _remote_in(c["output"]) if re.search(r"\b(?:git|gh|glab)\b", cmd) else None
            m = re.search(r"(?:--repo|-R)\s+([\w.-]+/[\w.-]+)", cmd)
            if m and not rem:
                rem = remote_id(f"https://github.com/{m.group(1)}")
            if rem and where and where not in remotes:
                remotes[where] = rem
            for e in _shell_events(cmd, c):
                e["dir"] = where
                if rem:
                    e["remote"] = rem["id"]
                events.append(e)
                git_dirs.add(where)
        reset = _RESET.search(c["output"])
        here = reset.group(1) if reset else start
    return {"files": files, "events": events, "remotes": remotes, "dirs": sorted(d for d in git_dirs if d)}


# ── facts → artefacts ────────────────────────────────────────────────────────────────────────

def _git(args: list[str]) -> str:
    try:
        r = subprocess.run(["git", *args], capture_output=True, text=True, timeout=5)
        return r.stdout.strip() if r.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


class Resolver:
    """Directories → repos. A remote the transcript named wins; on this machine a directory may
    also be asked. Answers are cached for the server's lifetime."""

    def __init__(self, this_host: str):
        self.host = this_host
        self.cache: dict[str, tuple[str, dict | None]] = {}

    def local(self, d: str) -> tuple[str, dict | None]:
        """(repo root or "", its origin) for a directory on THIS machine."""
        if d in self.cache:
            return self.cache[d]
        p = d
        while p and p != "/" and not os.path.isdir(p):  # a file's folder may be gone; ask its parent
            p = os.path.dirname(p)
        root = _git(["-C", p, "rev-parse", "--show-toplevel"]) if p and p != "/" else ""
        rem = remote_id(_git(["-C", root, "remote", "get-url", "origin"])) if root else None
        self.cache[d] = (root, rem)
        return self.cache[d]

    def links(self, f: dict, host: str, cwd: str) -> list[dict]:
        """One entry per artefact the session touched: {artefact, events, files}."""
        local = host == self.host
        known = dict(f.get("remotes", {}))   # dir -> remote, from the transcript
        out: dict[str, dict] = {}

        def repo_for(d: str) -> dict | None:
            for k, rem in known.items():                    # the transcript named it
                if d == k or d.startswith(k.rstrip("/") + "/"):
                    return rem
            if local:
                root, rem = self.local(d)
                if rem:
                    return rem
                if root:
                    return {"id": f"git:{host}:{root}", "kind": "repo", "label": _tail(root),
                            "path": root, "host": host}
            return None

        def add(a: dict) -> dict:
            e = out.setdefault(a["id"], {"artefact": a, "events": [], "files": []})
            return e

        for e in f.get("events", []):
            rem = None
            if e.get("remote"):
                rem = next((r for r in known.values() if r["id"] == e["remote"]), None)
            if SCRATCH.search((e.get("dir") or cwd or "") + "/"):
                continue
            rem = rem or repo_for(e.get("dir", ""))
            if not rem:
                d = e.get("dir", "") or cwd
                rem = {"id": f"git:{host}:{d}", "kind": "repo", "label": _tail(d), "path": d, "host": host}
            ev = {k: v for k, v in e.items() if k not in ("dir", "remote")}
            add(rem)["events"].append(ev)

        for path, n in f.get("files", {}).items():
            if SCRATCH.search(path):
                continue
            a = _record(path, host, cwd)
            if not a:
                d = os.path.dirname(path)
                a = repo_for(d)
                if not a:
                    inside = cwd and (path == cwd or path.startswith(cwd.rstrip("/") + "/"))
                    folder = cwd if inside else d
                    a = {"id": f"dir:{host}:{folder}", "kind": "folder", "label": _tail(folder),
                         "path": folder, "host": host}
            add(a)["files"].append(path)

        # A PR merged without its number (`gh pr merge` on the current branch) is the one opened here.
        for e in out.values():
            opened = [x["n"] for x in e["events"] if x["type"] == "pr_open"]
            for x in e["events"]:
                if x["type"] in ("pr_merge", "pr_close") and "n" not in x and opened:
                    x["n"] = opened[-1]
            a = e["artefact"]
            for x in e["events"]:
                if a["kind"] == "github" and "n" in x and "url" not in x:
                    kind = "pull" if x["type"].startswith("pr_") else "issues"
                    x["url"] = f"{a['url']}/{kind}/{x['n']}"
                if a["kind"] == "github" and x.get("sha"):
                    x["url"] = f"{a['url']}/commit/{x['sha']}"
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
    merged = sorted({x["n"] for x in ev if x["type"] == "pr_merge" and "n" in x})
    opened = sorted({x["n"] for x in ev if x["type"] == "pr_open" and "n" in x} - set(merged))
    if merged:
        bits.append(f"PR {' '.join('#' + str(n) for n in merged)} merged")
    if opened:
        bits.append(f"PR {' '.join('#' + str(n) for n in opened)} opened")
    issues = sorted({x["n"] for x in ev if x["type"] == "issue_open" and "n" in x})
    if issues:
        bits.append(f"issue {' '.join('#' + str(n) for n in issues)}")
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
