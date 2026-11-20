#!/usr/bin/env python3
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.
"""sj pick: choose a session and get back into it. `sj` with no arguments opens it.

    usage: sj-pick.py [--all] [--live] [--cwd DIR] [--popup] [--client NAME]
           sj-pick.py --list [--all] [--live] [--cwd DIR]     the rows, TSV, for scripts and tests
           sj-pick.py --plan SID [--popup] [--client NAME]    what Enter would do with SID

It opens on this project's sessions (the git repository of the folder you are in, worktrees
included; another machine's sessions count by the repository's name), live ones first, then the
rest newest first. Tab widens it to every project. The panel shows what tells sessions of one
folder apart: the title, the first and the last prompt, the end of the last reply, and what Enter
will do.

Enter takes whichever way back fits, the same as `sj resume`, never a second live copy:
  running here in tmux     switch to that tmux session (attach, outside tmux)
  running here, no tmux    nothing to attach to: it says where it runs
  anything else            `sj resume <sid>`: in this terminal, or, from the tmux popup
                           (--popup), in a new kept sj-* session the popup then switches to

Everything comes from `sj rows` (bin/sj.sh): the live sessions here and relayed from other hosts,
and the catalogue. tmux/scrubjay.conf opens it in a popup on a click on the status bar and on
prefix S. Tests: SJ_PICK_ROWS names a file to read instead of `sj rows`.
"""
from __future__ import annotations

import argparse
import base64
import curses
import json
import locale
import os
import re
import shlex
import subprocess
import sys
import textwrap
import threading
import time
from dataclasses import dataclass
from pathlib import Path

APP = Path(__file__).resolve().parent.parent
SJ = APP / "bin" / "sj.sh"
KEEP = APP / "bin" / "sj-keep.sh"
TMUX = os.environ.get("SJ_KEEP_TMUX", "tmux")
CLAUDE_DIR = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
LIVE = ("working", "waiting", "idle")
GLYPH = {"working": "●", "waiting": "◐", "idle": "○", "exited": "✕"}
RELOAD = 10.0  # seconds between readings of the live states


# ── the sessions ───────────────────────────────────────────────────────────────────────────────
@dataclass
class S:
    sid: str
    host: str = ""
    state: str = ""          # working/waiting/idle/ended/exited/reaped, "" for catalogue-only
    ts: float = 0.0          # newest sign of life
    src: str = ""            # here | relay | "" (catalogue only)
    tmux: str = ""
    attached: bool = False
    cwd: str = ""
    pid: str = ""
    topic: str = ""
    harness: str = "claude"
    summary: str = ""
    started: str = ""
    transcript: str = ""
    project: str = ""
    branch: str = ""

    @property
    def live(self) -> bool:
        return self.state in LIVE

    @property
    def rank(self) -> int:
        if self.live:
            return 0 if self.src == "here" else 1
        return 2


def rows_text() -> str:
    f = os.environ.get("SJ_PICK_ROWS")
    if f:
        return Path(f).read_text(errors="replace")
    try:
        return subprocess.run(["bash", str(SJ), "rows"], capture_output=True, text=True, errors="replace", timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def _epoch(stamp: str) -> float:
    try:
        return time.mktime(time.strptime(stamp.strip(), "%Y-%m-%d %H:%M"))
    except ValueError:
        return 0.0


_PROJ: dict[str, tuple[str, str]] = {}


def project_of(cwd: str) -> tuple[str, str]:
    """(project, branch): the git repository's name, worktrees included, else the folder's."""
    if not cwd or cwd == "-":
        return "", ""
    if cwd in _PROJ:
        return _PROJ[cwd]
    name, branch = os.path.basename(cwd.rstrip("/")) or cwd, ""
    if os.path.isdir(cwd):
        try:
            out = subprocess.run(["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir",
                                  "--abbrev-ref", "HEAD"], capture_output=True, text=True, timeout=5)
            lines = out.stdout.splitlines()
            if out.returncode == 0 and lines:
                common = lines[0].rstrip("/")
                name = os.path.basename(os.path.dirname(common)) if common.endswith("/.git") \
                    else os.path.basename(common.removesuffix(".git"))
                branch = lines[1] if len(lines) > 1 and lines[1] != "HEAD" else ""
        except (OSError, subprocess.TimeoutExpired):
            pass
    _PROJ[cwd] = (name, branch)
    return _PROJ[cwd]


def transcripts() -> dict[str, str]:
    out = {}
    for p in (CLAUDE_DIR / "projects").glob("*/*.jsonl"):
        out[p.stem] = str(p)
    return out


def load() -> list[S]:
    by: dict[str, S] = {}
    best: dict[str, tuple] = {}
    cat: dict[str, list[str]] = {}
    for line in rows_text().splitlines():
        f = line.split("\t")
        if f[0] == "L" and len(f) >= 10:
            _, src, host, sid, state, ts, tmux, att, cwd, pid = f[:10]
            if not sid or sid == "-":
                continue
            s = S(sid, host, state, float(ts or 0), src, "" if tmux == "-" else tmux, att == "1",
                  "" if cwd == "-" else cwd, "" if pid == "-" else pid)
            key = (s.rank, -s.ts)
            if sid not in best or key < best[sid]:
                best[sid], by[sid] = key, s
        elif f[0] == "C" and len(f) >= 7:
            cat.setdefault(f[3], f[1:])   # newest first: the first row of a session is its newest
    paths = transcripts()
    for sid, (ts, host, _sid, cwd, topic, harness, *rest) in cat.items():
        s = by.setdefault(sid, S(sid, host, cwd=cwd))
        s.topic, s.started, s.summary = topic, ts, (rest[0] if rest else "")
        s.harness = harness if harness and harness != "-" else ("opencode" if sid.startswith("ses_") else "claude")
        s.cwd = s.cwd or cwd
        s.ts = max(s.ts, _epoch(ts))
    for s in by.values():
        s.transcript = paths.get(s.sid, "")
        if s.transcript and not s.live:
            try:
                s.ts = max(s.ts, os.path.getmtime(s.transcript))
            except OSError:
                pass
        s.project, branch = project_of(s.cwd)
        s.branch = branch if s.live and s.src == "here" else ""
    return sorted(by.values(), key=lambda s: (s.rank, -s.ts))


def age(sec: float) -> str:
    s = max(0, int(sec))
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m"
    if s < 86400:
        return f"{s // 3600}h"
    return f"{s // 86400}d"


def where(s: S) -> str:
    if s.src == "here" and s.live:
        return (s.tmux + ("*" if s.attached else "")) if s.tmux else "(no tmux)"
    return "" if s.host == HOST else "@" + s.host


HOST = ""


def empty(s: S) -> bool:
    """A session that recorded nothing to tell it by: no title, and nothing running."""
    return not s.live and s.topic in ("", "-", "(no text)")


def scoped(sessions: list[S], project: str, live_only: bool, words: list[str], empties: bool = False) -> list[S]:
    out = []
    for s in sessions:
        if project and s.project != project:
            continue
        if not empties and empty(s):
            continue
        if live_only and not s.live:
            continue
        hay = " ".join((s.sid, s.topic, s.project, s.host, s.tmux, s.branch, s.state, s.summary)).lower()
        if any(w not in hay for w in words):
            continue
        out.append(s)
    return out


# ── what a session said ────────────────────────────────────────────────────────────────────────
_SKIP = ("<local-command", "<system-reminder", "<bash-", "<user-prompt-submit-hook", "[Request interrupted")


def _user_text(o: dict) -> str | None:
    if o.get("type") != "user" or o.get("isMeta") or o.get("isSidechain"):
        return None
    c = (o.get("message") or {}).get("content")
    if isinstance(c, list):
        c = "\n".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
    if not isinstance(c, str):
        return None
    t = c.strip()
    m = re.search(r"<command-name>(.*?)</command-name>", t)
    if m:
        a = re.search(r"<command-args>(.*?)</command-args>", t, re.S)
        return (m.group(1) + " " + (a.group(1).strip() if a else "")).strip()
    if not t or t.startswith(_SKIP):
        return None
    return t


def _reply_text(o: dict) -> str | None:
    if o.get("type") != "assistant" or o.get("isSidechain"):
        return None
    c = (o.get("message") or {}).get("content")
    if isinstance(c, list):
        t = "\n".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text").strip()
        return t or None
    return None


def _lines(path: str, head: bool, n: int) -> list[dict]:
    out = []
    try:
        with open(path, "rb") as fh:
            if not head:
                size = fh.seek(0, 2)
                fh.seek(max(0, size - n))
            data = fh.read(n)
    except OSError:
        return out
    raw = data.split(b"\n")
    if not head and len(data) == n:
        raw = raw[1:]   # the first line is cut
    for ln in raw:
        try:
            o = json.loads(ln)
            if isinstance(o, dict):
                out.append(o)
        except ValueError:
            pass
    return out


_SAID: dict[tuple[str, float], dict] = {}


def said(path: str) -> dict:
    """{first, last, reply, prompts}: what a Claude transcript asked first and last, and answered."""
    if not path:
        return {}
    try:
        key = (path, os.path.getmtime(path))
    except OSError:
        return {}
    if key in _SAID:
        return _SAID[key]
    first = next((t for o in _lines(path, True, 256 * 1024) if (t := _user_text(o))), "")
    tail = _lines(path, False, 1024 * 1024)
    last = next((t for o in reversed(tail) if (t := _user_text(o))), "")
    reply = next((t for o in reversed(tail) if (t := _reply_text(o))), "")
    # its prose: a code block's fences and lines say little in a few lines of panel
    # (a reply that is little else keeps them)
    prose = re.sub(r"```.*?(```|$)", "[code]", reply, flags=re.S).strip()
    if len(re.sub(r"\[code\]|\s", "", prose)) >= 20:
        reply = prose
    _SAID[key] = {"first": first, "last": last if last != first else "", "reply": reply}
    return _SAID[key]


# ── what Enter does ───────────────────────────────────────────────────────────────────────────
@dataclass
class Plan:
    what: str                 # one line, for the panel
    kind: str                 # switch | exec | detach | msg
    arg: list[str]            # switch: [tmux session]; exec: argv; detach: [cwd, argv…]


def plan(s: S, popup: bool, in_tmux: bool) -> Plan:
    if s.live and s.src == "here":
        if s.tmux:
            if in_tmux:
                return Plan(f"switch to tmux session {s.tmux}", "switch", [s.tmux])
            return Plan(f"attach to tmux session {s.tmux}", "exec", [TMUX, "attach-session", "-t", "=" + s.tmux])
        return Plan(f"it runs here outside tmux (pid {s.pid or '?'}), in the terminal it was started from:"
                    " go back there", "msg", [])
    if s.harness != "claude":
        return Plan(f"not a Claude session ({s.harness}): resume it from {s.harness} itself", "msg", [])
    argv = ["bash", str(SJ), "resume", s.sid]
    if s.live:
        what = f"it runs on {s.host} (as of {age(time.time() - s.ts)} ago): attach there over ssh, or hand it off"
    elif s.transcript and s.cwd and os.path.isdir(s.cwd):
        what = f"resume it in {pretty(s.cwd)}"
    else:
        what = f"hand it off from the archive{f' ({s.host})' if s.host else ''} and resume it here"
    if popup:
        cwd = s.cwd if s.cwd and os.path.isdir(s.cwd) else os.getcwd()
        return Plan(what + ", in a new tmux session", "detach", [cwd, *argv])
    return Plan(what, "exec", argv)


def pretty(p: str) -> str:
    h = str(Path.home())
    return "~" + p[len(h):] if p == h or p.startswith(h + "/") else p


def run_plan(p: Plan, client: str, popup: bool = False) -> str:
    """Carries a plan out. Returns a message when it did not leave the picker (exec never returns)."""
    if p.kind == "msg":
        return p.what
    if p.kind == "exec":
        os.execvp(p.arg[0], p.arg)
    if p.kind == "detach":
        cwd, *argv = p.arg
        r = subprocess.run(["bash", str(KEEP), "--detach", "--as", "claude", "--", *argv],
                           cwd=cwd, capture_output=True, text=True)
        name = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
        if r.returncode != 0 or not name:
            return "could not start a tmux session: " + (r.stderr.strip() or "no name came back")
        p = Plan("", "switch", [name])
    cmd = [TMUX, "switch-client"] + (["-c", client] if client else []) + ["-t", "=" + p.arg[0]]
    if popup:
        # tmux ignores a switch of a client while its popup is open: the server does it once it closes
        cmd = [TMUX, "run-shell", "-b", " ".join(shlex.quote(c) for c in cmd)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return "" if r.returncode == 0 else "tmux: " + r.stderr.strip()


def popup_client() -> str:
    """The client whose click or key opened the popup: the most recently active one. A popup's command
    is not format-expanded, so tmux cannot pass #{client_name} in."""
    r = subprocess.run([TMUX, "list-clients", "-F", "#{client_activity}\t#{client_name}"], capture_output=True, text=True)
    rows = sorted((ln.split("\t", 1) for ln in r.stdout.splitlines() if "\t" in ln), key=lambda x: -int(x[0] or 0))
    return rows[0][1] if rows else ""


def copy(text: str) -> str:
    """To the clipboard of the terminal you look through: tmux's buffer (and on, by OSC 52), else OSC 52."""
    if os.environ.get("TMUX"):
        if subprocess.run([TMUX, "set-buffer", "-w", "--", text], capture_output=True).returncode == 0:
            return "copied"
    try:
        with open("/dev/tty", "w") as tty:
            tty.write("\033]52;c;" + base64.b64encode(text.encode()).decode() + "\a")
        return "copied"
    except OSError:
        return "not copied"


def viewer(sid: str) -> tuple[str, str]:
    """Starts (or finds) the viewer on <sid>: (url, ssh forward or "")."""
    try:
        r = subprocess.run(["bash", str(SJ), "view", sid, "--json"], capture_output=True, text=True, timeout=30)
        d = json.loads(r.stdout.strip().splitlines()[-1])
        return d.get("url", ""), d.get("ssh") or ""
    except (OSError, subprocess.TimeoutExpired, ValueError, IndexError):
        return "", ""


# ── the screen ─────────────────────────────────────────────────────────────────────────────────
HELP = """\
 ↑↓ jk  move          Enter   go back into it (the panel says how)
 PgUp/PgDn g G        Tab a   this project / every project
 /      filter        l       live only     e  untitled ones too
 v      the viewer on it, its address copied
 y      copy its session id
 r      read again    q Esc   quit
"""


class UI:
    def __init__(self, a):
        self.a = a
        self.sessions: list[S] = []
        self.loaded = 0.0
        self.loading = False
        self.here_project = project_of(os.getcwd())[0]
        self.all = a.all
        self.live_only = a.live
        self.empties = False
        self.filter = ""
        self.typing = False
        self.sel_sid = ""
        self.top = 0
        self.msg = ""
        self.help = False
        self.in_tmux = bool(os.environ.get("TMUX"))

    def reload(self):
        if self.loading:
            return
        self.loading = True

        def go():
            try:
                self.sessions = load()
            finally:
                self.loaded, self.loading = time.time(), False
        threading.Thread(target=go, daemon=True).start()

    def scope(self) -> str:
        if self.all or not self.here_project:
            return ""
        if not any(s.project == self.here_project for s in self.sessions):
            return ""
        return self.here_project

    def shown(self) -> list[S]:
        return scoped(self.sessions, self.scope(), self.live_only, self.filter.lower().split(), self.empties)

    def put(self, w, y, x, text, attr=0, width=None):
        h, cols = w.getmaxyx()
        if y < 0 or y >= h or x >= cols:
            return
        n = (cols - x) if width is None else min(width, cols - x)
        try:
            w.addnstr(y, x, text, max(0, n - (1 if y == h - 1 else 0)), attr)
        except curses.error:
            pass

    def draw(self, w):
        w.erase()
        h, cols = w.getmaxyx()
        rows = self.shown()
        sid_list = [s.sid for s in rows]
        idx = sid_list.index(self.sel_sid) if self.sel_sid in sid_list else 0
        if rows:
            self.sel_sid = rows[idx].sid
        scope = self.scope()
        nlive = sum(1 for s in rows if s.live)
        head = f" {scope or 'every project'}  ·  {len(rows)} session{'s' * (len(rows) != 1)}, {nlive} live"
        if self.live_only:
            head += "  ·  live only"
        if self.filter:
            head += f"  ·  “{self.filter}”"
        self.put(w, 0, 0, head, curses.A_BOLD)
        keys = "Enter go · Tab " + ("this project" if not scope and self.here_project else "all") + " · / filter · v view · ? keys"
        self.put(w, 0, max(len(head) + 2, cols - len(keys) - 1), keys, curses.A_DIM)

        side = cols >= 150
        listw = cols // 2 if side else cols
        listh = (h - 2) if side else max(3, (h - 2) * 2 // 5)
        if idx < self.top:
            self.top = idx
        if idx >= self.top + listh:
            self.top = idx - listh + 1
        if not self.sessions and self.loading:
            self.put(w, 2, 2, "reading the sessions…", curses.A_DIM)
        elif not rows:
            self.put(w, 2, 2, "no session matches" + (" — Tab shows every project" if scope else ""), curses.A_DIM)
        now = time.time()
        for i, s in enumerate(rows[self.top:self.top + listh]):
            y = 1 + i
            cur = self.top + i == idx
            g = GLYPH.get(s.state, "·")
            state = s.state
            parts = f" {g} {s.sid[:8]}  {state:<7} {age(now - s.ts):>4}  "
            wh = where(s)
            col = f"{wh[:22]:<22} " if any(where(r) for r in rows) else ""
            proj = "" if scope else f"{s.project[:16]:<16} "
            line = parts + col + proj + (s.topic or "(no title)")
            attr = curses.A_REVERSE if cur else (0 if s.live else curses.A_DIM)
            self.put(w, y, 0, line.ljust(listw), attr, listw)
            if COLORS and s.state in COLORS:
                self.put(w, y, 1, g, COLORS[s.state] | (curses.A_REVERSE if cur else 0))
        if rows:
            if side:
                for y in range(1, h - 1):
                    self.put(w, y, listw, "│", curses.A_DIM)
                self.panel(w, rows[idx], 1, listw + 2, h - 2, cols - listw - 3)
            else:
                self.put(w, listh + 1, 0, "─" * cols, curses.A_DIM)
                self.panel(w, rows[idx], listh + 2, 1, h - listh - 3, cols - 2)
        foot = ("/" + self.filter + "▏") if self.typing else self.msg
        self.put(w, h - 1, 0, " " + foot, curses.A_BOLD if self.typing else curses.A_DIM)
        if self.help:
            for i, ln in enumerate(HELP.splitlines()):
                self.put(w, 2 + i, 2, ln.ljust(64), curses.A_REVERSE)
        w.refresh()

    def panel(self, w, s: S, y0, x0, h, width):
        if h <= 0 or width <= 10:
            return
        out: list[tuple[str, int]] = []

        def add(text, attr=0, indent=""):
            for para in (text or "").splitlines() or [""]:
                for ln in textwrap.wrap(para, width - len(indent)) or [""]:
                    out.append((indent + ln, attr))

        p = plan(s, self.a.popup, self.in_tmux)
        add(s.topic or "(no title)", curses.A_BOLD)
        meta = [s.sid, s.harness, s.host]
        if s.branch:
            meta.append("⎇ " + s.branch)
        add("  ·  ".join(x for x in meta if x), curses.A_DIM)
        if s.cwd:
            add(pretty(s.cwd), curses.A_DIM)
        st = (s.state or "recorded") + (f" {age(time.time() - s.ts)} ago" if s.ts else "")
        add(st + (f"  ·  started {s.started}" if s.started else ""), curses.A_DIM)
        add("Enter: " + p.what, curses.A_BOLD)
        if s.summary:
            out.append(("", 0))
            add(s.summary)
        t = said(s.transcript) if s.harness == "claude" else {}
        if not s.transcript and s.harness == "claude":
            out.append(("", 0))
            add(f"(its transcript is not on this machine{f'; it ran on {s.host}' if s.host else ''})", curses.A_DIM)
        # the prompts a few lines each; the reply its end, which is where a turn says what it did
        for label, key, lines in (("first prompt", "first", 4), ("last prompt", "last", 4), ("last reply", "reply", 0)):
            if not t.get(key):
                continue
            out.append(("", 0))
            out.append(("── " + label, curses.A_DIM))
            start = len(out)
            add(t[key][-1500:] if key == "reply" else t[key], 0, "  ")
            if lines and len(out) - start > lines:
                out[start + lines:] = [("  …", curses.A_DIM)]
            elif not lines:
                room = h - start
                if len(out) - start > room > 1:
                    out[start:] = [("  …", curses.A_DIM)] + out[len(out) - room + 1:]
        for i, (ln, attr) in enumerate(out[:h]):
            self.put(w, y0 + i, x0, ln, attr, width)

    def key(self, w, k) -> bool:
        rows = self.shown()
        sids = [s.sid for s in rows]
        idx = sids.index(self.sel_sid) if self.sel_sid in sids else 0
        h, _ = w.getmaxyx()
        page = max(1, (h - 2) // 2 - 1)
        if self.help:
            self.help = False
            return True
        if self.typing:
            if k in ("\n", "\r", curses.KEY_ENTER):
                self.typing = False
            elif k == "\x1b":
                self.typing, self.filter = False, ""
            elif k in (curses.KEY_BACKSPACE, "\x7f", "\b"):
                self.filter = self.filter[:-1]
            elif isinstance(k, str) and k.isprintable():
                self.filter += k
            return True
        self.msg = ""
        move = {curses.KEY_DOWN: 1, "j": 1, curses.KEY_UP: -1, "k": -1, curses.KEY_NPAGE: page,
                curses.KEY_PPAGE: -page, "g": -10**9, curses.KEY_HOME: -10**9, "G": 10**9, curses.KEY_END: 10**9}
        if k in move and rows:
            self.sel_sid = rows[max(0, min(len(rows) - 1, idx + move[k]))].sid
        elif k in ("q", "\x1b"):
            if self.filter:
                self.filter = ""
            else:
                return False
        elif k in ("\t", "a"):
            self.all = not self.all if self.here_project else True
            self.top, self.sel_sid = 0, ""
        elif k == "l":
            self.live_only = not self.live_only
        elif k == "e":
            self.empties = not self.empties
            self.msg = "untitled sessions shown" if self.empties else "untitled sessions hidden"
        elif k == "/":
            self.typing = True
        elif k == "?":
            self.help = True
        elif k == "r":
            self.reload()
            self.msg = "reading again…"
        elif k == "y" and rows:
            self.msg = f"{rows[idx].sid}: {copy(rows[idx].sid)}"
        elif k == "v" and rows:
            self.msg = "starting the viewer…"
            self.draw(w)
            url, ssh = viewer(rows[idx].sid)
            if not url:
                self.msg = "the viewer did not start (sj view says why)"
            else:
                self.msg = f"{copy(url)}: {url}" + (f"   over SSH, forward first: {ssh}" if ssh else "")
        elif k in ("\n", "\r", curses.KEY_ENTER) and rows:
            p = plan(rows[idx], self.a.popup, self.in_tmux)
            if p.kind == "msg":
                self.msg = p.what
                return True
            if p.kind == "exec":
                curses.endwin()
                print(f"sj: {p.what}", file=sys.stderr)
            m = run_plan(p, self.a.client or (popup_client() if self.a.popup else ""), self.a.popup)
            if not m:
                return False
            self.msg = m
        return True


COLORS: dict[str, int] = {}


def main(w, a):
    curses.curs_set(0)
    if curses.has_colors():
        try:
            curses.use_default_colors()
            for i, (st, c) in enumerate((("working", curses.COLOR_YELLOW), ("waiting", curses.COLOR_YELLOW),
                                         ("idle", curses.COLOR_GREEN), ("exited", curses.COLOR_RED)), 1):
                curses.init_pair(i, c, -1)
                COLORS[st] = curses.color_pair(i) | (curses.A_BOLD if st == "waiting" else 0)
        except curses.error:
            pass
    ui = UI(a)
    ui.reload()
    w.timeout(250)
    while True:
        if not ui.loading and time.time() - ui.loaded > RELOAD:
            ui.reload()
        ui.draw(w)
        try:
            k = w.get_wch()
        except curses.error:
            continue
        if k == curses.KEY_RESIZE:
            continue
        if not ui.key(w, k):
            return


def cli(argv: list[str]) -> int:
    global HOST
    ap = argparse.ArgumentParser(prog="sj pick", add_help=True)
    ap.add_argument("--all", action="store_true", help="every project, not this one")
    ap.add_argument("--live", action="store_true", help="live sessions only")
    ap.add_argument("--cwd", help="the folder whose project to open on (default: here)")
    ap.add_argument("--popup", action="store_true", help="in a tmux popup: resume into a new tmux session")
    ap.add_argument("--client", default="", help="the tmux client to switch (a popup: the latest active)")
    ap.add_argument("--list", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--plan", metavar="SID", help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    HOST = os.environ.get("SCRUBJAY_HOST") or subprocess.run(
        ["bash", "-c", '. "$1/bin/lib.sh" && sj_load_config && sj_host', "_", str(APP)],
        capture_output=True, text=True).stdout.strip()
    if a.cwd:
        try:
            os.chdir(a.cwd)
        except OSError:
            pass
    if a.list or a.plan:
        sessions = load()
        if a.plan:
            hit = [s for s in sessions if s.sid.startswith(a.plan)]
            if len(hit) != 1:
                print(f"sj pick: {len(hit)} sessions match {a.plan}", file=sys.stderr)
                return 1
            p = plan(hit[0], a.popup, bool(os.environ.get("TMUX")))
            print(p.what)
            print("\t".join([p.kind, *p.arg]))
            return 0
        here = project_of(os.getcwd())[0]
        proj = "" if a.all or not any(s.project == here for s in sessions) else here
        print(f"# {proj or 'every project'}")
        for s in scoped(sessions, proj, a.live, []):
            print("\t".join((s.sid, s.state or "-", where(s) or "-", s.project or "-", s.topic or "-")))
        return 0
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        print("sj pick: needs a terminal (sj ls lists the sessions)", file=sys.stderr)
        return 2
    locale.setlocale(locale.LC_ALL, "")
    os.environ.setdefault("ESCDELAY", "25")
    curses.wrapper(main, a)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(cli(sys.argv[1:]))
    except BrokenPipeError:   # `--list | head`
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        sys.exit(0)
