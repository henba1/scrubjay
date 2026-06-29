# Plan: `dcmcp` — make the dotclaude archive queryable from inside a session

> Status: **Phase 1 implemented** (`mcp/dcmcp_server.py`, `commands/dc{recall,find,browse}.md`,
> registration in `bin/claude-sync.sh`). Phases 2 (HTTP-over-WG) and 3 (embedding rerank) remain
> proposals. This doc keeps the full design + rationale; the build itself is described here and in
> the README's "Query the archive (MCP)" section.

## 1. The problem (restated)

Everything dotclaude relays — transcripts (`.jsonl` + `readable/`), plans, `history.jsonl`,
tasks, and cross-machine `memory/` — already lands on the NAS, sorted by host/project/date with
meaningful slugged filenames. But there is **no read path back into a live session**. To reuse a
past conversation you have to (a) remember which machine you had it on, (b) hand-walk the
filesystem, (c) open files by eye. The user's own worked example: finding the earlier
"extend dotclaude with an MCP server" chat meant remembering it was on **henpi** (not snellius),
then locating `henpi/readable/dotclaude/2026-06-24_read-and-understand-the-dotclaude-projec__01793445.md`
and scrolling to line 1248. That friction is the whole target.

## 2. Verdict on the MCP idea — yes, with a sharper shape

**MCP is the right primitive.** It is the one interface Claude Code natively exposes for
"external data + actions," and it maps cleanly onto the three use cases:

| MCP primitive | Surfaces in Claude Code as | Our use |
|---|---|---|
| **Tools** (model-invokable) | callable functions / `/dc*` wrappers | search & recall (use cases ii, iii) |
| **Resources** (user-pickable) | `@server:uri` mentions + `/mcp` resource picker | "point to *this* transcript/plan/memory" (use case i) |
| **Prompts** (user-invokable) | `/mcp__<server>__<name>` slash commands | the guided `/dcmcp*` entry points |

So the user's two sketches both fit: the "dropdown of file types → date-sorted files" is
**resources** (a templated URI tree the picker walks); the "describe a topic → semantic match"
is a **tool** (`dc_recall`). Use case iii ("find a topic *within* a conversation") is a second
tool (`dc_search_within`) returning turn/line anchors — exactly the "line 1248" the user wanted.

### The sharper shape (where I'd diverge from the naive build)

Three opinionated refinements, each pulling the design toward dotclaude's existing grain:

1. **Don't build an embedding/vector pipeline first — let the model do the semantics.**
   The corpus is tiny: **~24 MB, ~39 readable transcripts, 45 `.jsonl`, 9 plans, 12 memory
   files.** At that scale a vector DB is overkill, and — more importantly — *any* hosted
   embedding API (Voyage/OpenAI) would mean shipping sensitive transcript text to a third party,
   which **violates dotclaude's founding rule** ("anything sensitive goes straight to your own
   NAS, never a third party"). A *local* embedder (sentence-transformers / Ollama
   `nomic-embed-text`) keeps that rule but adds a heavy moving part on a Raspberry Pi. The
   leaner, better-aligned design: the MCP tool does a fast **lexical prefilter** (ripgrep over
   `readable/` + `logs/` + `memory/` + filename/date/topic metadata) and returns ranked
   candidate snippets with anchors; **Claude — already in the loop — does the semantic ranking**
   by reading the candidates. Zero embedding infra, fully local, and it leverages the frontier
   model that's already there. Local embeddings become an *optional* Phase 3 only if lexical
   recall proves too blunt.

2. **Mirror the existing transport split (local vs WG), don't ignore it.** The full archive only
   exists on the **NAS (henpi)**. A laptop/snellius has locally only: cross-machine `memory/`
   (the shared clone), `logs/*.log` (one-liners, all hosts), and *its own* live transcripts —
   **not** the aggregated `readable/` tree. The relay already solved exactly this asymmetry with
   a `local` backend (NAS mounted) and an `rsync-wg` backend (everyone else). The MCP server
   should reuse that mental model: **stdio/local first** (henpi reads the mounted archive),
   **HTTP-over-WG second** (other machines reach henpi's server). Granting every machine raw
   read access to the archive would also undo the relay's deliberate *write-only* (`rrsync -wo`)
   property; a single read endpoint on the NAS keeps read-access centralized and revocable.

3. **Bundle it in this app repo, registered by `claude-sync.sh` — not a 4th repo.** It's
   machinery, not data, so it belongs with the other machinery and stays public-able. Wiring it
   in via sync (the way `settings.json` and `commands/` already are) means it propagates to every
   machine with zero extra onboarding, configured from the same `~/.config/dotclaude/config`
   pointers. A standalone repo would only earn its keep if we wanted to publish the server for
   non-dotclaude users — not a goal.

**One-sentence design:** *a lean, fully-local MCP server that reads the same storage the relay
writes, exposes records as pickable resources + a lexical-prefilter recall tool, lets the
in-session model do the semantic ranking, and rides the local-vs-WG split the relay already
established.*

## 3. Architecture

```
                 ┌─────────────────────────── henpi (NAS mounted) ───────────────────────────┐
                 │  /media/hendrik/NAS1/dotclaude-storage/                                     │
                 │     <host>/readable/<project>/<date>_<topic>__<sid8>.md   (human render)    │
                 │     <host>/<slug>/<session>.jsonl                         (canonical)       │
                 │     <host>/plans/<date>_<topic>.md                                          │
                 │     <host>/history.jsonl                                                    │
                 │     memory/<project>/<name>.md                            (cross-machine)   │
                 │     hosts/<host>/chats.index.json  (via dotclaude-data)   (catalogue)       │
                 │                              ▲                                              │
                 │            reads (no writes) │                                              │
                 │                    ┌─────────┴──────────┐                                   │
                 │   Phase 1 (stdio)  │  dcmcp server      │  Phase 2: also binds HTTP on the  │
                 │   local Claude  ◄──┤  (uv run / Node)   ├──► WG iface  → remote machines    │
                 │                    └────────────────────┘     (snellius, laptops) connect   │
                 └─────────────────────────────────────────────────────────────────────────────┘
```

- **Read-only, always.** The server never writes to the archive. (No new privacy surface beyond
  read access, which is why it lives on the NAS box and is reached over WG, not handed out.)
- **Config from the existing pointer.** Reuse `DOTCLAUDE_LOCAL_CHATS` (storage root),
  `DOTCLAUDE_MEMORY` (memory clone), `DOTCLAUDE_DATA` (for `logs/` + `chats.index.json`). On a
  machine without the archive, the server simply reports the trees it *can* see (memory, logs,
  own transcripts) and degrades gracefully.
- **Metadata is already free.** Filenames encode `date`, `topic` (slugified first prompt), and
  `sid8`; `chats.index.json` gives per-project session counts/sizes/last-date; readable files
  carry a `# <topic>` H1 and a `_N turns_` line. No indexing build step needed for Phase 1.

## 4. Command / capability surface

### Tools (model-invokable; the engine)

| Tool | Input | Returns | Backed by |
|---|---|---|---|
| `dc_list` | `type?`, `host?`, `project?`, `since?/until?`, `limit?` | structured rows: host, project, date, topic, sid, type, path, turns, size | filesystem scan + `chats.index.json` |
| `dc_recall` | `query` (free text), `host?`, `project?`, `since?`, `k?` | ranked candidate sessions: topic, host, date, path, **matched snippets**, anchors | ripgrep prefilter over `readable/`+`plans/`+`memory/` **and the `logs/` session catalogue**, then metadata/score sort (model reranks) |
| `dc_search_within` | `id`/`path`, `query`, `context?` | matching passages with **turn # + line anchors** and surrounding context | ripgrep `-n` over one readable file (+ map to `.jsonl` turn) |
| `dc_get` | `id`/`path`, `format?` (`readable`\|`raw`), `turns?`/`lines?` slice | the artifact (or a slice) as text, ready to inject into context | direct file read; slice by turn/line |

Design notes:
- `dc_recall` returns *candidates with snippets*, not a single answer — the in-session model
  reads the snippets and picks/asks. That's the "semantic" step, done by the model, no embeddings.
- **The `logs/<host>.log` catalogue is folded into recall as a topic index** (it carries one line
  per session — first-prompt/topic, cwd, date, full uuid — across *all* machines, including
  sessions whose transcript never reached this archive). A log topic-hit keys onto the transcript
  when one exists here (so a session surfaces even if only its first prompt matched, not its body —
  and the result is enriched with the exact `cwd`); when no transcript is local it stands alone as
  a `type:log` **pointer** (host/cwd/date + "recall it on this host"). That's what makes recall
  useful on a *partial-archive* machine (snellius/laptops) — the catalogue is complete even when
  the `readable/` tree isn't. `dc_list type=log` browses the catalogue directly. (`"(no text)"`
  sessions are filtered.)
- `dc_get` is the actual context-injection primitive (use case i's payload, and the follow-through
  after a recall hit). Slicing keeps a 329-turn transcript from blowing the context window.
- All four take optional `host`/`project`/`since` so "I had it on henpi a couple weeks ago about
  X" narrows fast.

### Resources (user-pickable via `@` / `/mcp` picker; use case i)

Expose the archive as a **resource template** so the picker walks it like the user's imagined
cascading dropdown:

```
dc://transcript/{host}/{project}/{date}_{topic}__{sid8}     title: "<topic> — <date> · <host>"
dc://plan/{host}/{date}_{topic}                             title: "plan: <topic> — <date> · <host>"
dc://memory/{project}/{name}                                title: "memory: <name> · <project>"
```

- `resources/list` enumerates the leaves with human `title`s (topic + date + host) so the picker
  shows meaningful names, sorted by date — exactly the requested UX. Templates +
  the completion API give the host→project→date narrowing.
- Honest limitation to set expectations: Claude Code's resource UX is **`@`-mention autocomplete
  + the `/mcp` resource list**, not a literal multi-level dropdown widget. It's the same
  *select-a-file* outcome, reached by typing/filtering rather than clicking through menus.

### Prompts → the `/dcmcp*` entry points

Native MCP prompts appear as `/mcp__<server>__<name>`. To get the clean `/dc*` names the user
asked for (and match the existing `/dcsync`, `/dclog` family), ship **thin native
`commands/dc*.md`** wrappers that instruct Claude to call the tools — same pattern the repo
already uses. Proposed:

| Command (native wrapper) | Mirrors user's | Behaviour |
|---|---|---|
| `/dcrecall <topic>` | `/dcmcp_recall` | call `dc_recall`, show top matches, offer to `dc_get` the chosen one into context |
| `/dcfind <topic> in <session>` | "topic within a conversation" | call `dc_search_within`, return anchored passages |
| `/dcbrowse [type]` | `/dcmcp` | call `dc_list` filtered by type/host/project/date; user picks; `dc_get` it |

(If you prefer the menu-first feel, `/dcbrowse` with no args asks "type? (transcript / plan /
memory)" then lists — a prompt-driven approximation of the cascading dropdown.)

## 5. Setup & packaging

### Language & runtime — recommend **Python via `uv run --script`** (PEP 723 single file)

- `uv` is already installed on henpi; a single self-contained `mcp/dcmcp_server.py` with inline
  deps (`# /// script` block, deps = `mcp[cli]`) launches with `uv run --script` — **no venv to
  manage, no `node_modules`**, one file. Very much the dotclaude single-file/minimal grain.
- The official **Python SDK / FastMCP** decorators (`@mcp.tool`, `@mcp.resource(uri_template)`,
  `@mcp.prompt`) make the four tools + resource template ~a few hundred lines. JSONL/metadata
  parsing is pleasant in Python.
- *Alternative considered:* Node + `@modelcontextprotocol/sdk` (node/npx already present, no
  install). Equally fine; I lean Python for the single-file-with-deps ergonomics. **Open
  decision — see §7.**
- ripgrep (`rg`) is the prefilter engine; fall back to `grep -r` if absent. (Confirm `rg` on
  henpi during build.)

### Registration — done by `claude-sync.sh`, user scope

`claude-sync.sh` already merges `settings.json` and links `commands/`; add a step that registers
the server into the **user scope** (`~/.claude.json`, available across all projects) idempotently.
Two equivalent mechanisms — pick during build:

```sh
# stdio, henpi (local archive). Env carries the same pointers the rest of dotclaude uses.
claude mcp add --scope user \
  --env DOTCLAUDE_LOCAL_CHATS="$DOTCLAUDE_LOCAL_CHATS" \
  --env DOTCLAUDE_MEMORY="$DOTCLAUDE_MEMORY" \
  --transport stdio dcmcp -- uv run --script "$APP/mcp/dcmcp_server.py"
```

```jsonc
// or write the entry directly (claude-sync already edits JSON with jq):
// ~/.claude.json → "mcpServers": {
"dcmcp": {
  "type": "stdio",
  "command": "uv",
  "args": ["run", "--script", "${HOME}/.dotclaude/dotclaude/mcp/dcmcp_server.py"],
  "env": { "DOTCLAUDE_LOCAL_CHATS": "...", "DOTCLAUDE_MEMORY": "..." }
}
```

Phase 2 (remote machines) registers an HTTP endpoint instead:
```sh
claude mcp add --scope user --transport http dcmcp http://<henpi-wg-ip>:<port>/mcp
```
The WG tunnel is the auth boundary (consistent with the relay trusting its WG peer); optionally
add a static bearer token in `headers`. The server binds **only** to the WG interface IP.

### Gating

Only register when there's something to serve / a backend that makes sense — e.g. register the
stdio server when `DOTCLAUDE_LOCAL_CHATS` resolves to a real dir (henpi), register the HTTP client
entry when a `DOTCLAUDE_MCP_REMOTE` pointer is set (other machines). Mirrors how the transcript
backend is chosen by env today.

## 6. Phased build — delegatable task slabs

Each slab is sized for one sub-agent. Order matters only across phases; within a phase they're
mostly independent.

**Phase 1 — local stdio MCP (delivers all 3 use cases where the corpus lives, on henpi)**
- **Slab A — server skeleton + `dc_list`/`dc_get`.** Single-file FastMCP server; storage-root
  discovery from env with graceful degradation; filesystem scan + `chats.index.json` join;
  filename→metadata parser (date/topic/sid); `dc_get` with `readable|raw` + turn/line slicing.
- **Slab B — `dc_recall` + `dc_search_within`.** ripgrep prefilter + ranking; snippet extraction;
  readable-line ↔ jsonl-turn anchor mapping; `rg`→`grep` fallback.
- **Slab C — resources.** Resource template(s) + `resources/list` with human `title`s; completion
  for host/project narrowing.
- **Slab D — `claude-sync.sh` registration** (user scope, idempotent, env-passing) + `mcp/`
  layout + `.gitignore`/onboard touchpoints.
- **Slab E — native `commands/dcrecall.md`, `dcfind.md`, `dcbrowse.md`** wrappers + README section.

**Phase 2 — remote machines reach henpi's archive (the snellius case)**
- **Slab F — HTTP transport + WG-iface bind + optional bearer token**; `DOTCLAUDE_MCP_REMOTE`
  pointer; client-side `claude mcp add --transport http` in sync; a small systemd/user-service or
  `pull-and-mirror`-style keepalive on henpi so the server is up when a remote session connects.
- **Slab G — docs:** a `docs/transport-mcp.{dot,svg}` diagram in the style of the existing
  transport diagrams; README "Query the archive" section.

### Snellius integration — concrete changes (logged 2026-06-29, NOT yet built)

Snellius (the SURF HPC) is the motivating remote: it holds **only its own** live transcripts +
the shared `memory/` clone + `logs/` — **not** the aggregated archive (which lives only on the
NAS/henpi). Running Phase-1 stdio dcmcp *on snellius* would therefore recall only snellius's own
chats + memory, never the cross-machine archive. To recall the whole corpus it must reach henpi.
The actual delta from Phase 1:

1. **Transport — two candidates; lean SSH-stdio.**
   - **(A) HTTP-over-WG:** henpi runs dcmcp as a long-lived HTTP server bound *only* to its WG IP;
     snellius registers `claude mcp add --transport http http://<henpi-wg-ip>:<port>/mcp`.
     Cost: a new always-on listener + a keepalive service (systemd `--user`) + a new network auth
     surface (bearer token even on WG).
   - **(B) SSH-stdio (reuse the existing channel):** snellius registers a *stdio* server whose
     command SSHes into henpi over WG and runs the server there —
     `claude mcp add -s user dcmcp -- ssh <henpi-relay-alias> uv run --script <app>/mcp/dcmcp_server.py`.
     No new listener, no HTTP auth; rides the exact SSH-over-WG path (`:63772`) the relay already
     uses. **Preferred** — it matches §2 point 2 (read access stays centralized + revocable on
     henpi) and keeps the dotclaude grain (one channel, no new daemon).
2. **Account — must NOT reuse the write-only relay receiver.** The relay's receiver account is
   locked to `rrsync -wo` (write-only, forced command); it cannot read. SSH-stdio (B) needs a
   **separate read-only forced-command** key/account on henpi whose `command=` execs *only*
   `dcmcp_server.py` (with the `DOTCLAUDE_*` env baked into the wrapper) — so a compromised snellius
   key can read the archive but run nothing else, and the grant is revocable independently of the
   write path. HTTP (A) sidesteps the account but adds the listener+token instead.
3. **`claude-sync.sh` gating — add a remote branch.** `register_mcp()` today gates on
   `DOTCLAUDE_LOCAL_CHATS` being a real dir (henpi-only) and registers the local stdio server.
   Add: *else if* `DOTCLAUDE_MCP_REMOTE` is set (snellius's host config), register the remote
   entry instead — the `ssh … uv run --script` stdio command (B) or the `--transport http` URL (A).
   Same idempotent remove-then-add pattern.
4. **Config pointer.** New `DOTCLAUDE_MCP_REMOTE` in `hosts/snellius/...` config: either the henpi
   relay SSH alias (B) or the `http://<wg-ip>:<port>/mcp` URL (A). Mirrors how the transcript
   *backend* is chosen by env today.
5. **What snellius does NOT need.** In both models the server still runs **on henpi** (where the
   archive is) — snellius needs only `ssh` (B) or just the HTTP client (A), **not** `uv` or the
   archive mount. That dodges the HPC module/`uv`-on-login-node friction entirely.
6. **Reachability is already proven.** Snellius → henpi outbound SSH over WG works today (the relay
   ships transcripts that way); HPC blocks *inbound* to snellius, which is fine since both transport
   options are snellius-initiated. No new firewall holes.
7. **Optional dual-mode.** Snellius could *also* keep a local stdio dcmcp for its own chats+memory
   and add the remote for the aggregate — but two servers is confusing; prefer the single henpi
   server serving the whole archive (snellius's own transcripts are already in it after relay).

**Phase 3 — optional, only if lexical recall proves too blunt**
- **Slab H — local embedding rerank.** Ollama `nomic-embed-text` (or sentence-transformers) on
  henpi; precompute embeddings into a sidecar index refreshed on relay; `dc_recall` reranks the
  lexical candidates by cosine. Stays fully local; no third party. Gated behind a flag so the
  zero-dependency path remains the default.

## 7. Decisions (locked 2026-06-28)

1. **Runtime:** **Python + `uv run --script`** (single-file `mcp/dcmcp_server.py`, PEP 723 inline
   deps). ✓
2. **Recall engine:** **ripgrep prefilter + model reranks** now (zero deps, fully local). The
   local-embedding rerank option is deferred and sketched separately in
   [`docs/dcmcp-embedding-rerank.md`](dcmcp-embedding-rerank.md) (hardware needs + coarse plan). ✓
3. **Scope:** **Phase 1 only** — henpi, local stdio, full archive. Phase 2 (HTTP-over-WG) and
   Phase 3 (embeddings) are documented but not built yet. ✓
4. **Command names:** **`/dcrecall` `/dcfind` `/dcbrowse`** native wrappers (match the `/dcsync`
   `/dclog` family). ✓

→ **Build target = Phase 1, slabs A–E** in §6. Phase 2/3 slabs are out of scope for now.
