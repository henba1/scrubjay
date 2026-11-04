#!/usr/bin/env python3
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

"""sj-view — the session catalogue as a browsable map, served on this machine while you look at it.

Started and stopped by bin/sj-view.sh (/sjview); not a daemon. It exits on its own after
--idle minutes without a request, on POST /api/stop (the page's Stop button), or on SIGTERM.

Read-only, like sjmcp, and built on sjmcp's own readers (mcp/sjmcp_server.py imports nothing
beyond the standard library until it builds the MCP server), so the catalogue and the archive are
parsed one way only. Same environment as sjmcp: SCRUBJAY_DATA, SCRUBJAY_LOCAL_CHATS,
SCRUBJAY_MEMORY; SCRUBJAY_HOST names this machine.

Safety: binds 127.0.0.1 only; every request needs the per-run token (in the URL the wrapper
prints, then a header), and a Host header naming this loopback port, so another page in the
browser cannot read the archive through it (DNS rebinding included).
"""
from __future__ import annotations

import argparse
import json
import os
import secrets
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
APP = HERE.parent
sys.path.insert(0, str(APP / "mcp"))
import sjmcp_server as sj  # noqa: E402

PAGE = HERE / "index.html"
TRANSCRIPT_MAX = 2_000_000  # chars; a page this big is already unreadable, past it we say so


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


def _node(sid: str, rows: list[dict], arch: Archive) -> dict:
    last, first = rows[-1], rows[0]
    sid8 = sj._handle(sid)
    return {
        "sid": sid, "sid8": sid8, "topic": last["topic"], "host": last["host"],
        "cwd": last["cwd"], "project": Path(last["cwd"]).name if last["cwd"] else "",
        "date": first["date"], "time": first["time"],
        # Rows from before the harness field are Claude's; an opencode id says so on its own.
        "harness": last.get("harness") or ("opencode" if sid.startswith("ses_") else "claude"),
        "model": last.get("model", ""),
        "turns": last.get("turns", ""), "size": last.get("size", ""),
        "forked_from": last.get("forked_from", ""), "essence": last.get("essence") == "1",
        "rows": len(rows), "archived": bool(arch.readable(sid8)),
    }


def graph(r: sj.Roots, arch: Archive) -> dict:
    rows = _rows(r)
    nodes = [_node(s, rs, arch) for s, rs in rows.items()]
    known = {n["sid"] for n in nodes}
    edges = [{"from": n["forked_from"], "to": n["sid"], "kind": "fork"}
             for n in nodes if n["forked_from"] and n["forked_from"] in known]
    return {"host": os.environ.get("SCRUBJAY_HOST", ""), "nodes": nodes, "edges": edges,
            "archive": bool(r.chats)}


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


def session(r: sj.Roots, arch: Archive, sid: str) -> dict | None:
    all_rows = _rows(r)
    rows = all_rows.get(sid)
    if not rows:
        return None
    node = _node(sid, rows, arch)
    readable = arch.readable(node["sid8"])
    raw = sj._jsonl_for(Path(readable), r) if readable else None
    here = os.environ.get("SCRUBJAY_HOST", "")
    native = _resume_cmd(node["harness"], sid)
    if node["host"] == here:
        resume = {"where": "here", "cmd": f"cd {_q(node['cwd'])} && {native}" if native else ""}
    else:
        resume = {"where": node["host"],
                  "cmd": f"{_q(str(APP / 'bin' / 'sj-resume.sh'))} {node['sid8']}",
                  "then": native,
                  "note": f"run it from this project's folder here; it copies the session over "
                          f"from {node['host']} and prints how to continue it"}
    children = [s for s, rs in all_rows.items() if rs[-1].get("forked_from") == sid]
    return {"node": node, "rows": rows, "children": children, "readable": readable,
            "raw": str(raw) if raw else "", "resume": resume}


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
    def __init__(self, token: str, port: int, idle: float, r: sj.Roots):
        self.token, self.port, self.idle, self.r = token, port, idle, r
        self.arch = Archive(r)
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
                return self._json(graph(st.r, st.arch))
            if method == "GET" and u.path == "/api/session":
                s = session(st.r, st.arch, (q.get("sid") or [""])[0])
                return self._json(s) if s else self._json({"error": "no such session"}, 404)
            if method == "GET" and u.path == "/api/transcript":
                return self._json(transcript(st.r, st.arch, (q.get("sid8") or [""])[0],
                                             (q.get("format") or ["readable"])[0]))
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
    st = State(secrets.token_urlsafe(18), port, a.idle * 60, r)
    st.server = srv
    srv.RequestHandlerClass = handler_for(st)
    srv.daemon_threads = True

    state = Path(a.state)
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
