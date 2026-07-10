#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp[cli]>=1.2"]
# ///
"""sjmcp — a read interface over the scrubjay archive, exposed via MCP.

scrubjay *writes* every session's records to the NAS (transcripts, plans, cross-machine
memory); this server is the missing *read* path back into a live Claude Code session. It is
**read-only** and runs where the archive is mounted (the archive host). Config comes from the same
pointers the rest of scrubjay uses (`~/.config/scrubjay/config`), passed in as env:

    SCRUBJAY_LOCAL_CHATS   storage root: contains <host>/{readable,plans,<slug>}/, memory/
    SCRUBJAY_MEMORY        the cross-machine memory clone (fallback memory source)
    SCRUBJAY_DATA          the data repo: logs/<host>.log, hosts/<host>/chats.index.json

Where a tree is absent (e.g. a non-NAS machine has no readable/ archive) the server simply
serves what it can and reports the rest as unavailable, rather than failing.

The recall path is deliberately embedding-free: a fast ripgrep prefilter surfaces candidate
snippets and the in-session model does the semantic ranking. (A deferred local-embedding
rerank was considered and kept as an internal note, not built.)

Run `python sjmcp_server.py --selftest` to exercise the core logic against the real archive
without the MCP stdio handshake.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, asdict
from pathlib import Path

# ── storage roots ──────────────────────────────────────────────────────────────────────────
# Resolved once from env. Any of these may be missing on a given machine; callers must cope.


def _dir(env: str) -> Path | None:
    v = os.environ.get(env, "").strip()
    if not v:
        return None
    p = Path(v).expanduser()
    return p if p.is_dir() else None


@dataclass(frozen=True)
class Roots:
    chats: Path | None  # SCRUBJAY_LOCAL_CHATS (the archive root)
    memory: Path | None  # memory tree (chats/memory if present, else SCRUBJAY_MEMORY clone)
    data: Path | None  # SCRUBJAY_DATA (logs + chats.index.json)

    @property
    def all(self) -> list[Path]:
        return [p for p in (self.chats, self.memory, self.data) if p]


def roots() -> Roots:
    chats = _dir("SCRUBJAY_LOCAL_CHATS")
    # Prefer the archive's own memory/ tree (full, cross-machine) over the local clone.
    mem = (chats / "memory") if chats and (chats / "memory").is_dir() else _dir("SCRUBJAY_MEMORY")
    return Roots(chats=chats, memory=mem, data=_dir("SCRUBJAY_DATA"))


# ── metadata parsing ───────────────────────────────────────────────────────────────────────
# Filenames already encode the metadata scrubjay assigns on relay:
#   readable transcript: <project>/<date>_<topic>__<sid8>.md
#   plan:                <date>_<topic>.md
#   memory:              <project>/<name>.md   (+ a MEMORY.md index per project)

_READABLE = re.compile(r"^(?P<date>\d{4}-\d{2}-\d{2})_(?P<topic>.+)__(?P<sid8>[0-9a-f]{8})$")
_PLAN = re.compile(r"^(?P<date>\d{4}-\d{2}-\d{2})_(?P<topic>.+)$")


def _untopic(slug: str) -> str:
    return slug.replace("-", " ").strip()


@dataclass
class Artifact:
    type: str  # transcript | plan | memory
    host: str  # "" for memory (cross-machine, not host-keyed)
    project: str
    date: str  # YYYY-MM-DD ("" if unknown)
    topic: str  # human-ish title
    sid: str  # 8-char session id ("" if n/a)
    path: str  # absolute path to the artifact
    turns: int | None = None
    size: str = ""

    def to_row(self) -> dict:
        d = asdict(self)
        return {k: v for k, v in d.items() if v not in (None, "")}


def _human_size(p: Path) -> str:
    try:
        n = p.stat().st_size
    except OSError:
        return ""
    for unit in ("B", "K", "M", "G"):
        if n < 1024 or unit == "G":
            return f"{n}{unit}" if unit == "B" else f"{n:.0f}{unit}"
        n /= 1024
    return ""


def _turns(md: Path) -> int | None:
    # The readable render carries a `_N turns_` line near the top; fall back to counting the
    # `## User` / `## Assistant` block headers.
    try:
        head = md.read_text(errors="replace")
    except OSError:
        return None
    m = re.search(r"^_(\d+) turns_", head, re.M)
    if m:
        return int(m.group(1))
    n = len(re.findall(r"^## (?:User|Assistant)\b", head, re.M))
    return n or None


# ── enumeration ────────────────────────────────────────────────────────────────────────────


def _iter_transcripts(r: Roots) -> list[Artifact]:
    out: list[Artifact] = []
    if not r.chats:
        return out
    for host_dir in sorted(p for p in r.chats.iterdir() if p.is_dir() and p.name not in ("memory", "memory.git")):
        rd = host_dir / "readable"
        if not rd.is_dir():
            continue
        for proj_dir in sorted(p for p in rd.iterdir() if p.is_dir()):
            for md in sorted(proj_dir.glob("*.md")):
                m = _READABLE.match(md.stem)
                date = m.group("date") if m else ""
                topic = _untopic(m.group("topic")) if m else md.stem
                sid = m.group("sid8") if m else ""
                out.append(Artifact("transcript", host_dir.name, proj_dir.name, date, topic, sid,
                                     str(md), size=_human_size(md)))
    return out


def _iter_plans(r: Roots) -> list[Artifact]:
    out: list[Artifact] = []
    if not r.chats:
        return out
    for host_dir in sorted(p for p in r.chats.iterdir() if p.is_dir()):
        pd = host_dir / "plans"
        if not pd.is_dir():
            continue
        for md in sorted(pd.glob("*.md")):
            m = _PLAN.match(md.stem)
            date = m.group("date") if m else ""
            topic = _untopic(m.group("topic")) if m else md.stem
            out.append(Artifact("plan", host_dir.name, "", date, topic, "", str(md),
                                 size=_human_size(md)))
    return out


def _iter_memories(r: Roots) -> list[Artifact]:
    out: list[Artifact] = []
    if not r.memory:
        return out
    for proj_dir in sorted(p for p in r.memory.iterdir() if p.is_dir()):
        for md in sorted(proj_dir.glob("*.md")):
            if md.name == "MEMORY.md":  # the per-project index, not a fact
                continue
            out.append(Artifact("memory", "", proj_dir.name, "", md.stem, "", str(md),
                                 size=_human_size(md)))
    return out


def _all_artifacts(r: Roots) -> list[Artifact]:
    return _iter_transcripts(r) + _iter_plans(r) + _iter_memories(r)


# ── session-log catalogue ──────────────────────────────────────────────────────────────────
# <data>/logs/<host>.log carries ONE line per session, appended by the SessionEnd hook:
#   "YYYY-MM-DD HH:MM | host | cwd | "first user prompt (topic)" | session=<uuid>"
# This is the *complete* cross-machine index — it includes sessions whose full transcript never
# reached this archive (other machines, un-relayed runs). Recall folds it in: a topic match here
# links to the transcript when present, else stands alone as a "look on <host>" pointer.

_LOG = re.compile(
    r'^(?P<date>\d{4}-\d{2}-\d{2}) (?P<time>\d{2}:\d{2}) \| '
    r'(?P<host>[^|]*?) \| (?P<cwd>[^|]*?) \| '
    r'"(?P<topic>.*)" \| session=(?P<sid>[0-9a-fA-F][0-9a-fA-F-]+)\s*$'
)
_NOISE_TOPICS = {"", "(no text)"}


@dataclass
class LogEntry:
    date: str
    time: str
    host: str
    cwd: str
    topic: str
    sid: str  # full uuid as logged

    @property
    def sid8(self) -> str:
        return self.sid.replace("-", "")[:8].lower()

    @property
    def project(self) -> str:
        return Path(self.cwd).name if self.cwd else ""


def _parse_log_line(line: str) -> LogEntry | None:
    m = _LOG.match(line.rstrip("\n"))
    if not m:
        return None
    topic = m.group("topic").lstrip("❯>").strip()  # drop stray prompt markers
    if topic in _NOISE_TOPICS:  # empty / "(no text)" sessions carry nothing to recall on
        return None
    return LogEntry(m.group("date"), m.group("time"), m.group("host").strip(),
                    m.group("cwd").strip(), topic, m.group("sid").strip())


def _logs_dir(r: Roots) -> Path | None:
    d = (r.data / "logs") if r.data else None
    return d if d and d.is_dir() else None


def _iter_logs(r: Roots) -> list[LogEntry]:
    d = _logs_dir(r)
    if not d:
        return []
    out: list[LogEntry] = []
    for lf in sorted(d.glob("*.log")):
        try:
            for line in lf.read_text(errors="replace").splitlines():
                e = _parse_log_line(line)
                if e:
                    out.append(e)
        except OSError:
            continue
    return out


# ── id / path resolution ───────────────────────────────────────────────────────────────────
# A `ref` accepted by sj_get / sj_search_within may be: an absolute path under a known root, a
# root-relative path, a `sj://…` resource URI, or a bare 8-char session id. We resolve to a real
# path and confine it to the configured roots (no traversal out of the archive).


def _confined(p: Path, r: Roots) -> Path | None:
    try:
        rp = p.resolve()
    except OSError:
        return None
    for root in r.all:
        try:
            rp.relative_to(root.resolve())
            return rp
        except ValueError:
            continue
    return None


def resolve_ref(ref: str, r: Roots) -> Path | None:
    ref = ref.strip()
    if ref.startswith("sj://"):
        return _resolve_uri(ref, r)
    # bare session id (8 hex) → find the readable for it
    if re.fullmatch(r"[0-9a-f]{8}", ref):
        for a in _iter_transcripts(r):
            if a.sid == ref:
                return Path(a.path)
        return None
    p = Path(ref).expanduser()
    if p.is_absolute():
        return _confined(p, r) if p.exists() else None
    # root-relative: try each root
    for root in r.all:
        cand = root / ref
        if cand.exists():
            return _confined(cand, r)
    return None


# ── jsonl <-> readable mapping ─────────────────────────────────────────────────────────────


def _jsonl_for(readable: Path, r: Roots) -> Path | None:
    # readable: <root>/<host>/readable/<project>/<date>_<topic>__<sid8>.md
    # canonical: <root>/<host>/<slug>/<sid>.jsonl  (slug != project; find by sid8 prefix)
    m = _READABLE.match(readable.stem)
    if not (m and r.chats):
        return None
    sid8 = m.group("sid8")
    # host = the dir two levels up from the project dir (…/<host>/readable/<project>/file)
    try:
        host_dir = readable.parents[2]
    except IndexError:
        return None
    hits = list(host_dir.glob(f"*/{sid8}*.jsonl"))
    return hits[0] if hits else None


# ── core: list ─────────────────────────────────────────────────────────────────────────────


def core_list(type=None, host=None, project=None, since=None, until=None, limit=50, r=None):
    r = r or roots()
    if type == "log":  # browse the cross-machine session catalogue (not a file-backed artifact)
        rows = []
        for e in _iter_logs(r):
            if host and e.host != host:
                continue
            if project and project.lower() not in e.project.lower():
                continue
            if since and e.date < since:
                continue
            if until and e.date > until:
                continue
            rows.append({"type": "log", "host": e.host, "project": e.project, "date": e.date,
                         "time": e.time, "topic": e.topic, "sid": e.sid8, "cwd": e.cwd})
        rows.sort(key=lambda d: (d["date"], d["time"]), reverse=True)
        total = len(rows)
        rows = rows[: int(limit)] if limit else rows
        return {"total": total, "shown": len(rows), "items": rows}
    arts = _all_artifacts(r)
    if type:
        arts = [a for a in arts if a.type == type]
    if host:
        arts = [a for a in arts if a.host == host]
    if project:
        pl = project.lower()
        arts = [a for a in arts if pl in a.project.lower()]
    if since:
        arts = [a for a in arts if a.date and a.date >= since]
    if until:
        arts = [a for a in arts if a.date and a.date <= until]
    # newest first; memory (no date) sinks to the end but stays grouped
    arts.sort(key=lambda a: (a.date or "", a.host), reverse=True)
    total = len(arts)
    arts = arts[: int(limit)] if limit else arts
    # fill turns lazily only for the page we return (cheap; keeps listing fast)
    for a in arts:
        if a.type == "transcript":
            a.turns = _turns(Path(a.path))
    return {"total": total, "shown": len(arts), "items": [a.to_row() for a in arts]}


# ── core: get ──────────────────────────────────────────────────────────────────────────────


def _slice_lines(text: str, spec: str) -> str:
    lines = text.splitlines()
    lo, _, hi = spec.partition("-")
    a = max(1, int(lo)); b = int(hi) if hi else a
    sel = lines[a - 1 : b]
    return f"[lines {a}-{a + len(sel) - 1} of {len(lines)}]\n" + "\n".join(sel)


def _slice_turns(text: str, spec: str) -> str:
    # A turn = a `## User` / `## Assistant` block. Slice blocks [lo..hi] inclusive (1-based).
    lines = text.splitlines(keepends=True)
    bounds = [i for i, ln in enumerate(lines) if re.match(r"^## (?:User|Assistant)\b", ln)]
    if not bounds:
        return text
    bounds.append(len(lines))
    lo, _, hi = spec.partition("-")
    a = max(1, int(lo)); b = int(hi) if hi else a
    a = min(a, len(bounds) - 1); b = min(b, len(bounds) - 1)
    chunk = "".join(lines[bounds[a - 1] : bounds[b]])
    return f"[turns {a}-{b} of {len(bounds) - 1}]\n{chunk}"


def core_get(ref, format="readable", turns=None, lines=None, r=None):
    r = r or roots()
    path = resolve_ref(ref, r)
    if not path:
        return {"error": f"not found or outside the archive: {ref!r}"}
    if format == "raw":
        jl = _jsonl_for(path, r) if path.suffix == ".md" else path
        if not jl or not jl.exists():
            return {"error": f"no raw .jsonl for {ref!r}"}
        path = jl
    try:
        text = path.read_text(errors="replace")
    except OSError as e:
        return {"error": str(e)}
    body = text
    if lines:
        body = _slice_lines(text, lines)
    elif turns and format != "raw":
        body = _slice_turns(text, turns)
    return {"path": str(path), "format": format, "content": body}


# ── ripgrep prefilter (grep fallback) ──────────────────────────────────────────────────────


def _rg_available() -> bool:
    return shutil.which("rg") is not None


def _search_paths(r: Roots, type=None) -> list[Path]:
    paths: list[Path] = []
    if r.chats:
        for host_dir in r.chats.iterdir():
            if not host_dir.is_dir() or host_dir.name in ("memory", "memory.git"):
                continue
            if type in (None, "transcript") and (host_dir / "readable").is_dir():
                paths.append(host_dir / "readable")
            if type in (None, "plan") and (host_dir / "plans").is_dir():
                paths.append(host_dir / "plans")
    if type in (None, "memory") and r.memory:
        paths.append(r.memory)
    return paths


def _grep(query: str, paths: list[Path], globs=("*.md",), max_count_per_file=3
          ) -> list[tuple[str, int, str]]:
    """Return (file, lineno, line) hits. Case-insensitive, fixed-string, restricted to `globs`."""
    if not paths:
        return []
    hits: list[tuple[str, int, str]] = []
    if _rg_available():
        gargs = [a for g in globs for a in ("-g", g)]
        cmd = ["rg", "-i", "-F", "--no-heading", "--line-number", "-m", str(max_count_per_file),
               *gargs, "--", query, *map(str, paths)]
    else:
        gargs = [f"--include={g}" for g in globs]
        cmd = ["grep", "-r", "-i", "-F", "-n", *gargs, "-m", str(max_count_per_file),
               "--", query, *map(str, paths)]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return []
    for line in out.stdout.splitlines():
        # path:lineno:text
        parts = line.split(":", 2)
        if len(parts) == 3 and parts[1].isdigit():
            hits.append((parts[0], int(parts[1]), parts[2]))
    return hits


# ── core: recall ───────────────────────────────────────────────────────────────────────────


def _index_meta(path: str, by_path: dict) -> dict:
    """Best-effort metadata for a hit's file, so recall results are self-describing. Looks the
    file up in a prebuilt {path: Artifact} map (built once per recall) instead of re-walking the
    whole archive per hit."""
    a = by_path.get(path)
    if a:
        row = a.to_row()
        row.setdefault("topic", Path(path).stem)
        return row
    return {"type": "file", "path": path, "topic": Path(path).stem}


def core_recall(query, host=None, project=None, since=None, k=8, r=None):
    r = r or roots()
    terms = [t for t in re.split(r"\s+", query.strip()) if len(t) > 2] or [query]
    paths = _search_paths(r)
    # Enumerate the archive ONCE and index by path, so a hit's metadata (below) is a dict lookup
    # rather than re-walking the whole tree per candidate (recall used to be O(hits × corpus)).
    arts = _all_artifacts(r)
    by_path = {a.path: a for a in arts}
    # Union hits across the individual terms (OR), then score files by distinct-term coverage +
    # hit count. This is the lexical *prefilter*; the calling model does the semantic ranking.
    per_file: dict[str, dict] = {}
    for term in terms:
        for path, lineno, text in _grep(term, paths):
            f = per_file.setdefault(path, {"terms": set(), "hits": [], "n": 0, "log": None})
            f["terms"].add(term.lower())
            f["n"] += 1
            if len(f["hits"]) < 4:
                f["hits"].append({"line": lineno, "text": text.strip()[:240]})

    # Fold in the session-log catalogue. A topic match in the log keys onto the *transcript* when
    # one exists here (so a session surfaces even if only its first-prompt/topic matched, not its
    # body) — otherwise it stands alone as a cross-machine pointer (type=log). One sid → one key,
    # so a session matched in BOTH its body and its log naturally scores higher (more terms/hits).
    logs_dir = _logs_dir(r)
    if logs_dir:
        readable_by_sid = {a.sid: a.path for a in arts if a.type == "transcript" and a.sid}
        for term in terms:
            for _lf, lineno, text in _grep(term, [logs_dir], globs=("*.log",), max_count_per_file=80):
                e = _parse_log_line(text)
                if not e:
                    continue
                key = readable_by_sid.get(e.sid8) or f"log:{e.sid8}"
                f = per_file.setdefault(key, {"terms": set(), "hits": [], "n": 0, "log": None})
                f["terms"].add(term.lower())
                f["n"] += 1
                f["log"] = e
                snip = {"line": lineno, "text": f"🗒 log · {e.host} · {e.date} · {e.project}: {e.topic}"[:240]}
                if snip not in f["hits"] and len(f["hits"]) < 5:
                    f["hits"].append(snip)

    scored = []
    for key, f in per_file.items():
        log = f.get("log")
        if isinstance(key, str) and key.startswith("log:") and log:
            # log-only: no transcript in this archive — surface as a "look on <host>" pointer
            meta = {"type": "log", "host": log.host, "project": log.project, "date": log.date,
                    "topic": log.topic, "sid": log.sid8, "cwd": log.cwd,
                    "path": str((logs_dir / f"{log.host}.log")) if logs_dir else "",
                    "note": "transcript not in this archive — recall it on this host"}
        else:
            meta = _index_meta(key, by_path)
            if log:  # enrich a transcript hit with the log's exact cwd (readables keep only basename)
                meta.setdefault("cwd", log.cwd)
        if host and meta.get("host") != host:
            continue
        if project and project.lower() not in str(meta.get("project", "")).lower():
            continue
        if since and (meta.get("date", "") or "") < since:
            continue
        score = len(f["terms"]) * 10 + f["n"]
        scored.append((score, {**meta, "score": score, "snippets": f["hits"]}))
    scored.sort(key=lambda x: (x[0], x[1].get("date", "")), reverse=True)
    results = [r_ for _, r_ in scored[: int(k)]]
    note = ("ripgrep" if _rg_available() else "grep") + " prefilter (transcripts·plans·memory + " \
           "the session-log catalogue) — rank these by reading the snippets; sj_get the best one. " \
           "type=log hits have no transcript here: their host/cwd/date tell you where to find it."
    return {"query": query, "engine": note, "count": len(results), "results": results}


# ── core: search within ────────────────────────────────────────────────────────────────────


def core_search_within(ref, query, context=2, r=None):
    r = r or roots()
    path = resolve_ref(ref, r)
    if not path:
        return {"error": f"not found or outside the archive: {ref!r}"}
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError as e:
        return {"error": str(e)}
    # map line -> enclosing turn (## User / ## Assistant block index), so a hit cites a turn.
    turn_at = []
    cur = 0
    for ln in lines:
        if re.match(r"^## (?:User|Assistant)\b", ln):
            cur += 1
        turn_at.append(cur)
    ctx = max(0, int(context))
    q = query.lower()
    passages = []
    for i, ln in enumerate(lines):
        if q in ln.lower():
            lo = max(0, i - ctx); hi = min(len(lines), i + ctx + 1)
            passages.append({
                "line": i + 1,
                "turn": turn_at[i] or None,
                "excerpt": "\n".join(lines[lo:hi]).strip()[:600],
            })
    return {"path": str(path), "query": query, "matches": len(passages), "passages": passages[:40]}


# ── status (for graceful-degradation visibility) ───────────────────────────────────────────


def core_status(r=None):
    r = r or roots()
    arts = _all_artifacts(r)
    by_type: dict[str, int] = {}
    for a in arts:
        by_type[a.type] = by_type.get(a.type, 0) + 1
    by_type["log_sessions"] = len(_iter_logs(r))
    return {
        "archive_root": str(r.chats) if r.chats else None,
        "memory_root": str(r.memory) if r.memory else None,
        "data_root": str(r.data) if r.data else None,
        "logs_dir": str(_logs_dir(r)) if _logs_dir(r) else None,
        "ripgrep": _rg_available(),
        "counts": by_type,
        "unavailable": [name for name, present in
                        (("transcripts/plans", r.chats), ("memory", r.memory), ("logs", _logs_dir(r)))
                        if not present],
    }


# ── MCP server ─────────────────────────────────────────────────────────────────────────────


def _with_timeout(fn, seconds: int = 45):
    """Run fn() under a wall-clock budget so a stalled archive read can't hang the stdio
    response (a stuck read once silently wedged a remote sj_recall/sj_get — no repro, so this
    is a safety net, not a targeted fix). Returns fn()'s dict, or an error dict on timeout.
    A daemon thread is used because a blocking filesystem syscall can't be interrupted; on
    timeout we abandon the thread and return so the client isn't left waiting forever."""
    import threading
    box: dict = {}

    def _run():
        try:
            box["v"] = fn()
        except Exception as e:  # propagate real errors to the caller, don't mask as a timeout
            box["err"] = e

    t = threading.Thread(target=_run, daemon=True)
    t.start()
    t.join(seconds)
    if t.is_alive():
        return {"error": f"timed out after {seconds}s (archive read stalled)"}
    if "err" in box:
        raise box["err"]
    return box["v"]


def build_server():
    from mcp.server.fastmcp import FastMCP

    mcp = FastMCP("sjmcp")
    R = roots()

    @mcp.tool()
    def sj_list(type: str | None = None, host: str | None = None, project: str | None = None,
                since: str | None = None, until: str | None = None, limit: int = 50) -> dict:
        """List archived artifacts (transcripts, plans, memories) with metadata.

        Filters: type (transcript|plan|memory|log), host, project (substring), since/until
        (YYYY-MM-DD). Newest first. Use this to browse, then sj_get to pull one in.
        type=log browses the cross-machine session catalogue (one row per session, all hosts)."""
        return _with_timeout(lambda: core_list(type, host, project, since, until, limit))

    @mcp.tool()
    def sj_get(ref: str, format: str = "readable", turns: str | None = None,
               lines: str | None = None) -> dict:
        """Fetch an artifact (or a slice) to inject into context.

        ref: a sj:// URI, a session id (8 hex), or a path. format: 'readable' (default) or
        'raw' (the .jsonl). Slice with turns='5-10' or lines='1200-1300'."""
        return _with_timeout(lambda: core_get(ref, format, turns, lines))

    @mcp.tool()
    def sj_recall(query: str, host: str | None = None, project: str | None = None,
                  since: str | None = None, k: int = 8) -> dict:
        """Find past sessions/plans/memories matching a topic description.

        Runs a lexical prefilter and returns candidate files with matched snippets + line
        anchors; YOU rank them by reading the snippets, then sj_get the best match."""
        return _with_timeout(lambda: core_recall(query, host, project, since, k))

    @mcp.tool()
    def sj_search_within(ref: str, query: str, context: int = 2) -> dict:
        """Find where a topic appears *within* one session/plan/memory.

        Returns matching passages with line anchors and the enclosing turn number."""
        return _with_timeout(lambda: core_search_within(ref, query, context))

    @mcp.tool()
    def sj_status() -> dict:
        """Report which archive trees are reachable from this machine and their counts."""
        return core_status()

    # Resources: expose each artifact as a pickable resource with a human title, so Claude
    # Code's @-mention / resource picker shows meaningful, date-sorted names. Templates handle
    # read; concrete entries (added below) make them listable.
    from mcp.server.fastmcp.resources import FunctionResource
    from pydantic import AnyUrl

    def _register_concrete():
        for a in core_list(limit=10_000)["items"]:
            uri = _uri_for(a)
            if not uri:
                continue
            title = _title_for(a)
            path = a["path"]
            mcp.add_resource(FunctionResource(
                uri=AnyUrl(uri), name=title, description=title, mime_type="text/markdown",
                fn=(lambda p=path: Path(p).read_text(errors="replace")),
            ))

    try:
        _register_concrete()
    except Exception as e:  # never let resource listing break the tools
        print(f"sjmcp: resource registration skipped: {e}", file=sys.stderr)

    @mcp.resource("sj://transcript/{host}/{project}/{stem}")
    def _transcript(host: str, project: str, stem: str) -> str:
        return _read_template(R, "transcript", host=host, project=project, stem=stem)

    @mcp.resource("sj://plan/{host}/{stem}")
    def _plan(host: str, stem: str) -> str:
        return _read_template(R, "plan", host=host, stem=stem)

    @mcp.resource("sj://memory/{project}/{name}")
    def _memory(project: str, name: str) -> str:
        return _read_template(R, "memory", project=project, name=name)

    return mcp


# ── resource URI helpers ───────────────────────────────────────────────────────────────────


def _uri_for(a: dict) -> str | None:
    t = a["type"]
    if t == "transcript":
        stem = Path(a["path"]).stem
        return f"sj://transcript/{a.get('host','')}/{a.get('project','')}/{stem}"
    if t == "plan":
        stem = Path(a["path"]).stem
        return f"sj://plan/{a.get('host','')}/{stem}"
    if t == "memory":
        return f"sj://memory/{a.get('project','')}/{Path(a['path']).stem}"
    return None


def _title_for(a: dict) -> str:
    t = a["type"]
    if t == "transcript":
        return f"{a.get('topic','?')} — {a.get('date','')} · {a.get('host','')}"
    if t == "plan":
        return f"plan: {a.get('topic','?')} — {a.get('date','')} · {a.get('host','')}"
    return f"memory: {a.get('topic','?')} · {a.get('project','')}"


def _read_template(r: Roots, kind: str, **kw) -> str:
    if kind == "transcript" and r.chats:
        p = r.chats / kw["host"] / "readable" / kw["project"] / f"{kw['stem']}.md"
    elif kind == "plan" and r.chats:
        p = r.chats / kw["host"] / "plans" / f"{kw['stem']}.md"
    elif kind == "memory" and r.memory:
        p = r.memory / kw["project"] / f"{kw['name']}.md"
    else:
        return f"(unavailable: {kind})"
    p = _confined(p, r)
    return p.read_text(errors="replace") if p and p.exists() else f"(not found: {kind})"


def _resolve_uri(uri: str, r: Roots) -> Path | None:
    m = re.match(r"^sj://(transcript|plan|memory)/(.+)$", uri)
    if not m:
        return None
    kind, rest = m.group(1), m.group(2).split("/")
    try:
        if kind == "transcript" and r.chats and len(rest) >= 3:
            host, project, stem = rest[0], rest[1], "/".join(rest[2:])
            return _confined(r.chats / host / "readable" / project / f"{stem}.md", r)
        if kind == "plan" and r.chats and len(rest) >= 2:
            return _confined(r.chats / rest[0] / "plans" / f"{'/'.join(rest[1:])}.md", r)
        if kind == "memory" and r.memory and len(rest) >= 2:
            return _confined(r.memory / rest[0] / f"{'/'.join(rest[1:])}.md", r)
    except (OSError, IndexError):
        return None
    return None


# ── entrypoints ────────────────────────────────────────────────────────────────────────────


def _selftest():
    r = roots()
    print("== status =="); print(json.dumps(core_status(r=r), indent=2))
    print("\n== list transcripts (5) =="); print(json.dumps(core_list(type="transcript", limit=5, r=r), indent=2))
    print("\n== recall 'extend scrubjay with an MCP server' =="); print(json.dumps(core_recall("extend scrubjay with an MCP server", k=4, r=r), indent=2))
    print("\n== list logs (catalogue, 5) =="); print(json.dumps(core_list(type="log", limit=5, r=r), indent=2))
    print("\n== recall 'VERONA foolbox' (log-only / cross-machine pointer) =="); print(json.dumps(core_recall("VERONA foolbox attack", k=4, r=r), indent=2))
    # search within the known transcript for 'mcp'
    rec = core_recall("read and understand the scrubjay project", k=1, r=r)
    if rec["results"]:
        ref = rec["results"][0]["path"]
        sw = core_search_within(ref, "mcp", context=1, r=r)
        print(f"\n== search_within {Path(ref).name} for 'mcp' =="); print(json.dumps({k: v for k, v in sw.items() if k != "passages"}, indent=2)); print("first 3 passages:", json.dumps(sw.get("passages", [])[:3], indent=2))


def main():
    if "--selftest" in sys.argv:
        _selftest(); return
    build_server().run()


if __name__ == "__main__":
    main()
