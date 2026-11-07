#!/usr/bin/env python3
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

"""sj-view — the session catalogue as a browsable map, served on this machine while you look at it.

Started and stopped by bin/sj-view.sh (/sjview); not a daemon. It exits on its own after
--idle minutes without a request, on POST /api/stop (the page's Stop button), or on SIGTERM.

Built on sjmcp's own readers (mcp/sjmcp_server.py imports nothing beyond the standard library until
it builds the MCP server), so the catalogue and the archive are parsed one way only. It reads the
archive and never changes it; its one write is a line in the moves ledger (bin/sj-moves.sh). Same
environment as sjmcp: SCRUBJAY_DATA, SCRUBJAY_LOCAL_CHATS, SCRUBJAY_MEMORY; SCRUBJAY_HOST names this
machine.

Safety: binds 127.0.0.1 only; every request needs the per-run token (in the URL the wrapper
prints, then a header), and a Host header naming this loopback port, so another page in the
browser cannot read the archive through it (DNS rebinding included).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse

HERE = Path(__file__).resolve().parent
APP = HERE.parent
sys.path.insert(0, str(APP / "mcp"))
import sjmcp_server as sj  # noqa: E402
import artefacts as art  # noqa: E402

PAGE = HERE / "index.html"
TRANSCRIPT_MAX = 2_000_000  # chars; a page this big is already unreadable, past it we say so
MOVES = APP / "bin" / "sj-moves.sh"
BODY_MAX = 16_384  # bytes of a POST: two paths and a host


# ── the catalogue, every row kept ─────────────────────────────────────────────────────────────
# sjmcp keeps the last row per session; the viewer also wants the earlier ones (how the topic
# moved) and every trailing field, known or not.

def _rows(r: sj.Roots) -> dict[str, list[dict]]:
    d = sj._logs_dir(r)
    out: dict[str, list[dict]] = {}
    if not d:
        return out
    for lf in sorted(d.glob("*.log")):
        try:
            lines = lf.read_text(errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            m = sj._LOG.match(line)
            e = sj._parse_log_line(line)
            if not (m and e):
                continue
            row = {"date": e.date, "time": e.time, "host": e.host, "cwd": e.cwd,
                   "topic": e.topic, "sid": e.sid, **sj._parse_extra(m.group("extra") or "")}
            out.setdefault(e.sid, []).append(row)
    # Each machine logs to its own file, so a session continued elsewhere has rows in two files: put
    # them in time order (stable, so one file's refreshes, which keep their first time, stay in order).
    for rs in out.values():
        rs.sort(key=lambda w: w["date"] + w["time"])
    return out


class Archive:
    """The transcript index, rebuilt at most once a minute: it walks the archive."""

    def __init__(self, r: sj.Roots):
        self.r, self.at, self.by_sid8 = r, 0.0, {}
        self.lock = threading.Lock()

    def readable(self, sid8: str) -> str:
        with self.lock:
            if time.time() - self.at > 60:
                idx = {}
                if self.r.chats:
                    for a in sj._iter_transcripts(self.r):
                        idx.setdefault(a.sid.lower(), a.path)
                self.by_sid8, self.at = idx, time.time()
            return self.by_sid8.get(sid8, "")

    def all(self) -> dict[str, str]:
        self.readable("")
        with self.lock:
            return dict(self.by_sid8)


class Artefacts:
    """What each archived session changed (view/artefacts.py), read in the background so the map
    is up at once. The per-transcript facts are cached on disk, keyed by the transcript's size and
    mtime, so a later start reads only what changed."""

    VERSION = 8   # bump with any change to what view/artefacts.py:facts() returns

    def __init__(self, arch: Archive, cache: Path, host: str):
        self.arch, self.cache = arch, cache
        self.resolver = art.Resolver(host)
        self.facts: dict[str, dict] = {}       # sid8 -> facts
        self.done = self.total = 0
        self.ready = False
        self.lock = threading.Lock()

    def start(self, cwd_of: dict[str, str]):
        threading.Thread(target=self._run, args=(cwd_of,), daemon=True).start()

    def _run(self, cwd_of: dict[str, str]):
        try:
            disk = json.loads(self.cache.read_text())
            entries = disk.get("entries", {}) if disk.get("version") == self.VERSION else {}
        except (OSError, ValueError):
            entries = {}
        todo = [(s8, p) for s8, p in self.arch.all().items() if s8 in cwd_of]
        self.total, fresh = len(todo), {}
        for s8, path in todo:
            cwd = cwd_of[s8]
            try:
                st = os.stat(path)
                key = [st.st_size, int(st.st_mtime), cwd]
                hit = entries.get(path)
                if hit and hit.get("key") == key:
                    f = hit["facts"]
                else:
                    with open(path, errors="replace") as fh:
                        f = art.facts(fh.read(), cwd)
                fresh[path] = {"key": key, "facts": f}
                with self.lock:
                    self.facts[s8] = f
            except OSError:
                pass
            self.done += 1
        self.ready = True
        try:
            tmp = self.cache.with_suffix(".tmp")
            tmp.write_text(json.dumps({"version": self.VERSION, "entries": fresh}))
            os.chmod(tmp, 0o600)  # commit messages and paths, like the archive it came from
            tmp.replace(self.cache)
        except OSError:
            pass

    def remotes_under(self, path: str) -> list[dict]:
        """Every remote a session saw in this folder or below it."""
        with self.lock:
            all_facts = list(self.facts.values())
        out: dict[str, dict] = {}
        inside = lambda d: d == path or d.startswith(path.rstrip("/") + "/")  # noqa: E731
        for f in all_facts:
            for d, rs in f.get("remotes", {}).items():
                if inside(d):
                    out.update({r["id"]: r for r in rs})
            for d, by_name in f.get("names", {}).items():
                if inside(d):
                    out.update({r["id"]: r for r in by_name.values()})
        return list(out.values())

    def links(self, sid8: str, host: str, cwd: str, parent: str = "",
              pairs: list[tuple[str, str]] | None = None) -> list[dict]:
        pairs = pairs or []
        with self.lock:
            f = self.facts.get(sid8)
            pf = self.facts.get(sj._handle(parent)) if parent else None
        if not f:
            return []
        if pf:
            f = art.minus(f, pf)
        out = self.resolver.links(art.relocate(f, pairs), host, cwd)
        for link in out:
            link["summary"] = art.summary(link)
            a = link["artefact"]
            for old, new in pairs:
                if a.get("path") and (a["path"] == new or a["path"].startswith(new + "/")):
                    a["moved"] = {"old": old, "new": new}
                    break
        return out


def _hops(hosts: list[str]) -> list[str]:
    """Hosts in order, a repeat of the one before dropped: laptop, henpi, laptop."""
    return [h for i, h in enumerate(hosts) if i == 0 or h != hosts[i - 1]]


def moves() -> dict[str, list[tuple[str, str]]]:
    """The moves in force, per machine, longest old path first."""
    try:
        out = subprocess.run(["bash", str(MOVES), "list"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    table: dict[str, list[tuple[str, str]]] = {}
    for line in out.splitlines():
        host, old, new = (line.split("\t") + ["", ""])[:3]
        if host and old and new:
            table.setdefault(host, []).append((old, new))
    for pairs in table.values():
        pairs.sort(key=lambda p: -len(p[0]))
    return table


def _node(sid: str, rows: list[dict], arch: Archive, mv: dict | None = None) -> dict:
    last, first = rows[-1], rows[0]
    sid8 = sj._handle(sid)
    pairs = (mv or {}).get(last["host"], [])
    cwd = art.moved(last["cwd"], pairs)
    hit = next(((o, n) for o, n in pairs if cwd != last["cwd"] and art.moved(last["cwd"], [(o, n)]) == cwd), None)
    return {
        "sid": sid, "sid8": sid8, "topic": last["topic"], "host": last["host"],
        "cwd": cwd, "project": Path(cwd).name if cwd else "",
        "recorded_cwd": last["cwd"], "moved": {"old": hit[0], "new": hit[1]} if hit else None,
        "date": first["date"], "time": first["time"],
        # Rows from before the harness field are Claude's; an opencode id says so on its own.
        "harness": last.get("harness") or ("opencode" if sid.startswith("ses_") else "claude"),
        "model": last.get("model", ""),
        "turns": last.get("turns", ""), "size": last.get("size", ""),
        "forked_from": last.get("forked_from", ""), "essence": last.get("essence") == "1",
        "summary": next((w["summary"] for w in reversed(rows) if w.get("summary")), ""),
        # Where it ran, in order: a hand-off continues the same session on another machine.
        "hosts": _hops([w["host"] for w in rows]),
        "resumed_from": next((w["resumed_from"] for w in reversed(rows) if w.get("resumed_from")), ""),
        "rows": len(rows), "archived": bool(arch.readable(sid8)),
    }


def cloud_links() -> dict | None:
    """Where this machine's files can be opened in a browser: a Nextcloud (or any web file view)
    holding the same folders. SCRUBJAY_VIEW_NEXTCLOUD is its address; SCRUBJAY_VIEW_NEXTCLOUD_MAP
    pairs a local folder with the folder Nextcloud shows it as, `local=remote`, several split by `;`.
    The page turns every path under a local folder into a link; nothing is fetched from here."""
    base = os.environ.get("SCRUBJAY_VIEW_NEXTCLOUD", "").strip().rstrip("/")
    if not base.startswith(("https://", "http://")):
        return None
    pairs = []
    for item in os.environ.get("SCRUBJAY_VIEW_NEXTCLOUD_MAP", "").split(";"):
        local, sep, remote = item.strip().partition("=")
        if sep and local.startswith("/") and remote.startswith("/"):
            pairs.append([local.rstrip("/") or "/", remote.rstrip("/") or "/"])
    pairs.sort(key=lambda x: -len(x[0]))  # the most specific folder wins
    return {"base": base, "map": pairs} if pairs else None


def cloud_url(path: str) -> str | None:
    """The Nextcloud address for a local path, checked against the disk here: a file that is gone,
    or a folder since renamed, opens the deepest part of its path that still exists (never above
    the mapped folder). A file that exists opens its folder with the file picked out."""
    c = cloud_links()
    if not c or not path.startswith("/"):
        return None
    want = os.path.normpath(path)
    hit = next(((loc, rem) for loc, rem in c["map"] if want == loc or want.startswith(loc.rstrip("/") + "/")), None)
    if not hit:
        return None
    loc, rem = hit
    # Symlinks resolved, then held inside the mapped folder: only what it shares is ever looked at.
    # Each candidate, from the path itself up to the folder, is resolved and checked right before
    # it touches the disk.
    root = os.path.realpath(loc)
    inside = root.rstrip(os.sep) + os.sep
    p, cand = root, want
    while cand.startswith(loc):
        safe = os.path.realpath(cand)
        if safe.startswith(inside) and os.path.exists(safe):
            p = safe
            break
        if cand == loc:
            break
        cand = os.path.dirname(cand)
    shown = "/" + (rem.strip("/") + "/" + p[len(root):].strip("/")).strip("/")
    if p == root:
        return f"{c['base']}/apps/files/files?dir={quote(shown, safe='/')}"
    safe = os.path.realpath(p)
    if safe.startswith(inside) and os.path.isdir(safe):
        return f"{c['base']}/apps/files/files?dir={quote(shown, safe='/')}"
    parent, _, name = shown.rpartition("/")
    return f"{c['base']}/apps/files/files?dir={quote(parent or '/', safe='/')}&scrollto={quote(name, safe='')}"


_HEADER_SAFE = re.compile(r"[\x21-\x7e]+")


def graph(st: "State") -> dict:
    rows = _rows(st.r)
    mv = moves()
    here = os.environ.get("SCRUBJAY_HOST", "")
    nodes = [_node(s, rs, st.arch, mv) for s, rs in rows.items()]
    known = {n["sid"] for n in nodes}
    edges = [{"from": n["forked_from"], "to": n["sid"], "kind": "fork"}
             for n in nodes if n["forked_from"] and n["forked_from"] in known]
    # A carry-over into another harness started a new session from an old one: an edge between them.
    # (A native hand-off kept the session id, so it is one node that ran on two machines.)
    by8 = {n["sid8"]: n["sid"] for n in nodes}
    for n in nodes:
        src = n["resumed_from"].partition(":")[2]
        src = src if src in known else by8.get(sj._handle(src), "") if src else ""
        if src and src != n["sid"]:
            edges.append({"from": src, "to": n["sid"], "kind": "carry",
                          "label": f"carried over · {n['resumed_from'].partition(':')[0]}"})
    # Artefacts: one node each, and an edge per session that changed it, labelled with what it did.
    arts: dict[str, dict] = {}
    for n in nodes:
        if not n["archived"]:
            continue
        for link in st.arts.links(n["sid8"], n["host"], n["cwd"], n["forked_from"], mv.get(n["host"])):
            a = arts.setdefault(link["artefact"]["id"], {**link["artefact"], "sessions": 0, "prs": set(), "commits": 0})
            a["sessions"] += 1
            a["prs"] |= {x["n"] for x in link["events"] if x["type"] in ("pr_open", "pr_merge") and "n" in x}
            a["commits"] += sum(1 for x in link["events"] if x["type"] == "commit")
            edges.append({"from": n["sid"], "to": a["id"], "kind": "artefact", "summary": link["summary"]})
    gone: dict[str, bool] = {}

    def is_gone(host: str, path: str) -> bool:
        """Only this machine's disk can say; each path is asked once."""
        if host != here or not path.startswith("/"):
            return False
        if path not in gone:
            gone[path] = not os.path.exists(path)
        return gone[path]

    for n in nodes:
        n["gone"] = is_gone(n["host"], n["cwd"])
    for a in arts.values():
        a["prs"] = len(a["prs"])
        a["gone"] = is_gone(a.get("host", ""), a.get("path", ""))
    return {"host": os.environ.get("SCRUBJAY_HOST", ""), "nodes": nodes, "edges": edges,
            "artefacts": list(arts.values()), "archive": bool(st.r.chats), "cloud": cloud_links(),
            "indexing": None if st.arts.ready else {"done": st.arts.done, "total": st.arts.total}}


def artefact(st: "State", aid: str) -> dict | None:
    """One artefact and, per session that changed it, what it did there: the milestones."""
    rows = _rows(st.r)
    mv = moves()
    found, sessions = None, []
    for sid, rs in rows.items():
        n = _node(sid, rs, st.arch, mv)
        if not n["archived"]:
            continue
        for link in st.arts.links(n["sid8"], n["host"], n["cwd"], n["forked_from"], mv.get(n["host"])):
            if link["artefact"]["id"] == aid:
                found = link["artefact"]
                sessions.append({"node": n, "events": link["events"], "files": link["files"],
                                 "summary": link["summary"]})
    if not found:
        return None
    sessions.sort(key=lambda x: x["node"]["date"] + x["node"]["time"], reverse=True)
    return {"artefact": found, "sessions": sessions}


def _resume_cmd(harness: str, sid: str) -> str:
    """The adapter's own resume command (bin/adapters/<harness>.sh: sjh_resume_cmd)."""
    try:
        out = subprocess.run(
            ["bash", "-c", '. "$1/bin/lib.sh" && sj_load_adapter "$2" && sjh_resume_cmd "$3"',
             "_", str(APP), harness or "claude", sid],
            capture_output=True, text=True, timeout=10)
        return out.stdout.strip() if out.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def session(st: "State", sid: str) -> dict | None:
    r, arch = st.r, st.arch
    all_rows = _rows(r)
    rows = all_rows.get(sid)
    if not rows:
        return None
    mv = moves()
    node = _node(sid, rows, arch, mv)
    readable = arch.readable(node["sid8"])
    raw = sj._jsonl_for(Path(readable), r) if readable else None
    here = os.environ.get("SCRUBJAY_HOST", "")
    native = _resume_cmd(node["harness"], sid)
    if node["host"] == here and node["moved"]:
        # The harness files a session under its folder, so one that moved has to be staged there.
        resume = {"where": "moved", "cmd": f"{_q(str(APP / 'bin' / 'sj-resume.sh'))} {node['sid8']} --into {_q(node['cwd'])}",
                  "then": f"cd {_q(node['cwd'])} && {native}" if native else "",
                  "note": "its folder moved, so this stages it there first; then continue it"}
    elif node["host"] == here:
        resume = {"where": "here", "cmd": f"cd {_q(node['cwd'])} && {native}" if native else ""}
    else:
        resume = {"where": node["host"],
                  "cmd": f"{_q(str(APP / 'bin' / 'sj-resume.sh'))} {node['sid8']}",
                  "then": native,
                  "note": f"run it from this project's folder here; it copies the session over "
                          f"from {node['host']} and prints how to continue it"}
    children = [s for s, rs in all_rows.items() if rs[-1].get("forked_from") == sid]
    links = st.arts.links(node["sid8"], node["host"], node["cwd"], node["forked_from"], mv.get(node["host"])) if readable else []
    return {"node": node, "rows": rows, "children": children, "readable": readable,
            "raw": str(raw) if raw else "", "resume": resume, "artefacts": links}


def record_move(host: str, old: str, new: str) -> str:
    """A move into the ledger, or an undo when `new` is empty. "" when done, else what is wrong."""
    if not (isinstance(host, str) and isinstance(old, str) and isinstance(new, str)) or not host or not old:
        return "a move needs a host and a path"
    # On this machine the target must exist; the ledger checks, so no path from a request is opened here.
    here = host == os.environ.get("SCRUBJAY_HOST", "")
    args = (["add", *(["--must-exist"] if here else []), host, old, new]) if new else ["undo", host, old]
    try:
        r = subprocess.run(["bash", str(MOVES), *args], capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return "could not reach the ledger"
    return "" if r.returncode == 0 else (r.stderr.strip().removeprefix("sj-moves: ") or "could not record the move")


def suggest(st: "State", path: str) -> list[str]:
    """Where a folder that is gone may have gone: this machine's catalogued folders that exist and
    carry its name, or the remote the sessions saw there."""
    here = os.environ.get("SCRUBJAY_HOST", "")
    mv = moves().get(here, [])
    seen = {art.moved(rs[-1]["cwd"], mv) for rs in _rows(st.r).values() if rs[-1]["host"] == here and rs[-1]["cwd"]}
    want = {r["id"] for r in st.arts.remotes_under(path)}
    name = os.path.basename(path.rstrip("/")).lower()
    named, same_remote = [], []
    for d in sorted(seen):
        if d == path or not os.path.isdir(d):
            continue
        if os.path.basename(d).lower() == name:
            named.append(d)
        elif want and want & {r["id"] for r in st.arts.resolver.local(d)[1].values()}:
            same_remote.append(d)
    return (same_remote + named)[:8]


def _q(s: str) -> str:
    return "'" + s.replace("'", "'\\''") + "'"


def transcript(r: sj.Roots, arch: Archive, sid8: str, fmt: str) -> dict:
    path = arch.readable(sid8)
    if not path:
        return {"error": "this session's transcript is not in the archive on this machine"}
    return sj.core_get(path, format="condensed" if fmt == "condensed" else "readable",
                       max_chars=TRANSCRIPT_MAX, r=r)


# ── the server ────────────────────────────────────────────────────────────────────────────────

class State:
    def __init__(self, token: str, port: int, idle: float, r: sj.Roots, cache: Path | None = None):
        self.token, self.port, self.idle, self.r = token, port, idle, r
        self.arch = Archive(r)
        self.arts = Artefacts(self.arch, cache or Path(os.devnull), os.environ.get("SCRUBJAY_HOST", ""))
        self.last = time.time()
        self.server: ThreadingHTTPServer | None = None


def handler_for(st: State):
    hosts = {f"127.0.0.1:{st.port}", f"localhost:{st.port}"}

    class H(BaseHTTPRequestHandler):
        server_version = "sj-view"

        def log_message(self, *a):  # quiet: the wrapper keeps a log only for start-up failures
            pass

        def _send(self, code: int, body: bytes, ctype: str = "application/json"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.end_headers()
            self.wfile.write(body)

        def _json(self, obj, code: int = 200):
            self._send(code, json.dumps(obj).encode())

        def _allowed(self, q: dict) -> bool:
            if self.headers.get("Host", "") not in hosts:
                return False
            tok = self.headers.get("X-SJ-Token") or (q.get("t") or [""])[0]
            return secrets.compare_digest(tok, st.token)

        def _route(self, method: str):
            st.last = time.time()
            u = urlparse(self.path)
            q = parse_qs(u.query)
            if not self._allowed(q):
                return self._json({"error": "forbidden"}, 403)
            if method == "GET" and u.path == "/":
                return self._send(200, PAGE.read_bytes(), "text/html; charset=utf-8")
            if method == "GET" and u.path == "/api/graph":
                return self._json(graph(st))
            if method == "GET" and u.path == "/api/artefact":
                a = artefact(st, (q.get("id") or [""])[0])
                return self._json(a) if a else self._json({"error": "no such artefact"}, 404)
            if method == "GET" and u.path == "/api/session":
                s = session(st, (q.get("sid") or [""])[0])
                return self._json(s) if s else self._json({"error": "no such session"}, 404)
            if method == "GET" and u.path == "/go":
                # A link the page opens in a new tab: resolved now, so it follows the disk.
                url = cloud_url((q.get("path") or [""])[0])
                # Printable ASCII only into a header: the address is percent-encoded, and this
                # also stops a configured base with a line break in it.
                url = (url or "").replace("\r", "").replace("\n", "")
                if not url or not _HEADER_SAFE.fullmatch(url):
                    return self._json({"error": "not a folder this machine shares with Nextcloud"}, 404)
                self.send_response(302)
                self.send_header("Location", url)
                self.send_header("Cache-Control", "no-store")
                self.send_header("Referrer-Policy", "no-referrer")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return None
            if method == "GET" and u.path == "/api/transcript":
                return self._json(transcript(st.r, st.arch, (q.get("sid8") or [""])[0],
                                             (q.get("format") or ["readable"])[0]))
            if method == "GET" and u.path == "/api/suggest":
                return self._json({"paths": suggest(st, (q.get("path") or [""])[0])})
            if method == "POST" and u.path == "/api/move":
                try:
                    n = int(self.headers.get("Content-Length") or 0)
                    body = json.loads(self.rfile.read(n)) if 0 < n <= BODY_MAX else None
                except ValueError:
                    body = None
                if not isinstance(body, dict):
                    return self._json({"error": "not a move"}, 400)
                err = record_move(body.get("host"), body.get("old"), body.get("new", ""))
                return self._json({"error": err}, 400) if err else self._json({"ok": True})
            if method == "POST" and u.path == "/api/stop":
                self._json({"stopped": True})
                threading.Thread(target=st.server.shutdown, daemon=True).start()
                return None
            return self._json({"error": "not found"}, 404)

        def do_GET(self):
            self._route("GET")

        def do_POST(self):
            self._route("POST")

    return H


def _watch_idle(st: State):
    while st.idle > 0:
        time.sleep(min(30.0, st.idle / 4))
        if time.time() - st.last > st.idle:
            st.server.shutdown()
            return


def main() -> int:
    ap = argparse.ArgumentParser(description="scrubjay session viewer (run it via bin/sj-view.sh)")
    ap.add_argument("--port", type=int, default=0, help="0 = any free port")
    ap.add_argument("--idle", type=float, default=30, help="minutes without a request before it exits; 0 = never")
    ap.add_argument("--state", required=True, help="file to write {pid, port, url} to while running")
    a = ap.parse_args()

    r = sj.roots()
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", a.port), handler_for(State("", 0, 0, r)))
    except OSError as e:
        print(f"sj-view: cannot listen on 127.0.0.1:{a.port}: {e.strerror}", file=sys.stderr)
        return 1
    port = srv.server_address[1]
    state = Path(a.state)
    st = State(secrets.token_urlsafe(18), port, a.idle * 60, r, state.parent / "view-artefacts.json")
    st.server = srv
    st.arts.start({sj._handle(sid): rs[-1]["cwd"] for sid, rs in _rows(r).items()})
    srv.RequestHandlerClass = handler_for(st)
    srv.daemon_threads = True

    url = f"http://127.0.0.1:{port}/?t={st.token}"
    state.parent.mkdir(parents=True, exist_ok=True)
    tmp = state.with_suffix(".tmp")
    tmp.write_text(json.dumps({"pid": os.getpid(), "port": port, "url": url, "idle": a.idle}))
    os.chmod(tmp, 0o600)  # the token is the only key to the archive this serves
    tmp.replace(state)

    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=srv.shutdown, daemon=True).start())
    threading.Thread(target=_watch_idle, args=(st,), daemon=True).start()
    try:
        srv.serve_forever(poll_interval=0.5)
    finally:
        srv.server_close()
        try:
            if json.loads(state.read_text()).get("pid") == os.getpid():
                state.unlink()
        except (OSError, ValueError):
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
