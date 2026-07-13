# Harness roadmap

What is left to do per harness. The contract these phases implement is in
[`README.md`](README.md); the seam itself is done (`bin/adapters/`, `bin/sync-config.sh`,
harness-blind `ship-transcript.sh` / `log-session.sh` / `sj-resume.sh`).

| | claude | opencode | codex |
|---|---|---|---|
| relay sessions to the archive | ✅ | ✅ | ⬜ P1 |
| readable rendering (cross-harness search) | ✅ | ✅ | ⬜ P1 |
| read the archive from inside (sjmcp + `/sj*`) | ✅ | ✅ | ⬜ P3 |
| session hand-off (`/sjresume`) | ✅ | 🟡 two-step (stage, then `opencode import`) | ⬜ P2 |
| config sync *into* the harness | ✅ | ⬜ P3 | ⬜ P3 |

---

## codex

Codex is the cheap one where opencode was expensive, and vice versa: its hook system is
deliberately Claude-shaped, its transcript is already JSONL on disk, and `codex resume` reads a
file — but its config is **TOML**, where scrubjay's whole settings story is a jq merge.

### What is already known (verified against the docs/source, July 2026)

* **Hooks.** `~/.codex/hooks.json`, or inline `[hooks]` in `~/.codex/config.toml`. A command hook is
  `{"type": "command", "command": "...", "timeout": 600}`. Every hook gets JSON on **stdin** with
  `session_id`, `transcript_path` (nullable), `cwd`, `hook_event_name`, `model`, `turn_id` — i.e.
  *the same payload `hooks/log-session.sh` already parses*.
* **Events.** `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`,
  `PreCompact`, `PostCompact`, `SubagentStart`, `SubagentStop`, `Stop`. There is **no SessionEnd** —
  `Stop` fires at the end of each *turn*, so codex needs the same publish-every-turn approach the
  opencode bridge uses, not Claude's publish-once.
* **Sessions.** `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` — JSONL, one `RolloutItem`
  per line (assistant messages, tool calls, command executions, file changes, approvals). Prompt
  history is `~/.codex/history.jsonl`.
* **Resume.** `codex resume <session-id>`, `codex resume --last`, or
  `codex -c experimental_resume=<path>`. It reads a file on disk — so hand-off is a drop-in.
* **Config.** `~/.codex/config.toml` (TOML), `AGENTS.md` for instructions, custom prompts (slash
  commands) as markdown in `~/.codex/prompts/`, MCP servers as `[mcp_servers.<name>]` tables.
  Project-local `.codex/config.toml` *ignores* provider/telemetry keys (`notify`, `model_providers`,
  `profile`, …) — those must go in the user-level file.

### Verify first (needs a real codex install — do not guess)

1. **The rollout record schema.** The renderer and the topic extractor are the only real work in P1,
   and both need actual `RolloutItem`/`ResponseItem` lines. Capture one rollout and read it.
2. **Is `transcript_path` populated** on `SessionStart` and `Stop`, and does it point at the rollout?
   (It is documented as nullable.) If it is null, derive the newest rollout for the cwd instead.
3. **Do `~/.codex/prompts/*.md` support `$ARGUMENTS` / `$1` and `` !`shell` `` injection?** The
   opencode command generator (`_sjh_oc_commands`) assumes both; codex may support neither, in which
   case the shell-injecting commands (`/sjlog`, `/sjsync`, `/sjmemory`) need a different shape.
4. **The `[mcp_servers]` schema** — `command` + `args` + `env`, and whether stdio is the default.

### P1 — write path

* `bin/adapters/codex.sh`:
  * `sjh_config_dir` → `${CODEX_HOME:-~/.codex}`; `sjh_transcript_ext` → `jsonl`;
    `sjh_session_handle` → first 8 (ids are UUIDs).
  * `sjh_session_slug` → `sjh_slug(cwd)`. **Not** the transcript's parent dir — that is `…/07/`, a
    date, not a project.
  * `sjh_session_topic` / `sjh_session_cwd` / `sjh_render` → new, over the rollout schema.
    `bin/render-codex.sh` must emit the **same** Markdown shape as the other two renderers
    (`# title`, `_N turns_`, `## User` / `## Assistant`, folded tool stream) — that shared shape is
    what makes `/sjrecall` work across harnesses.
  * `sjh_extra_artifacts` → `~/.codex/history.jsonl` → `history.jsonl`. (No plans/tasks/file-history
    equivalents to ship.)
  * `sjh_apply_config` → install the hooks (below). Config sync proper is P3.
* Register the lifecycle in `~/.codex/hooks.json`: `SessionStart` → `hooks/sync-session.sh`,
  `Stop` → `hooks/log-session.sh`, both with `SCRUBJAY_HARNESS=codex` in the command. Because `Stop`
  is per-turn, add the same dedupe the opencode bridge has (skip when the transcript hasn't changed
  since the last ship) — otherwise the `git` backend commits once per turn.
* Because the payload matches Claude's, `hooks/log-session.sh` should need **no changes at all**.
  That is the test of whether the Phase 0 seam was cut in the right place.

### P2 — hand-off (nearly free; do it with P1)

`codex resume` reads a rollout file, so `sj-resume.sh` works as-is: it fetches, rewrites the foreign
machine's absolute paths, and validates (the JSONL line-count + `jq -c` check already applies).
Only the adapter's placement functions are new:

* `sjh_project_dir` → `~/.codex/sessions/<YYYY>/<MM>/<DD>/` (today's dir; codex finds a session by
  id, not by path, so the date dir only has to exist).
* `sjh_resume_cmd` → `codex resume <sid>`.
* `sjh_import_side` → no-op (nothing sidecar to restore).

Caveat to check: the archived file is named `<sid>.jsonl`, but codex names rollouts
`rollout-<ts>-<uuid>.jsonl`. If codex indexes sessions by **filename** rather than by reading the
file, the staged copy must be renamed to that pattern — establish which before writing P2.

### P3 — config sync + MCP (the TOML problem)

* **The blocker:** `settings.base.json` + host overlay is a `jq` merge, and codex config is TOML.
  Either (a) add a tiny TOML merge helper (`uv run --script` with `tomlkit` — `uv` is already a hard
  dependency for sjmcp), or (b) ship a whole per-host `config.toml` from the data repo and give up
  on base+overlay merging. (a) is more work but keeps one config model across harnesses; prefer it.
* MCP: write `[mcp_servers.sjmcp]` into `config.toml` — same local/remote split as the other two
  adapters (`uv run --script mcp/sjmcp_server.py` on the archive host; `ssh <target>` on a client).
* Commands: generate `~/.codex/prompts/*.md` from `commands/`, the same way `_sjh_oc_commands`
  generates opencode's — *if* verification (3) says the syntax carries over. Factor the generator
  out of `bin/adapters/opencode.sh` into a shared helper at that point, rather than copy-pasting it.
* Instructions: `AGENTS.md` symlink from the data repo (shared with opencode's, once P3 lands there).

---

## opencode — remaining

* **Config sync into opencode** (P3): `AGENTS.md`, `agents/`, and a base+host `opencode.json` merge
  from the data repo. Needs the data-repo layout change (`claude-md/` → `harness/{claude,opencode}/`
  with a shared `AGENTS.md`) plus a migration in `bin/sj-migrate.sh`.
* **Automatic import on hand-off** (P4): `sj-resume.sh` currently stages the rewritten export into
  an inbox and prints `opencode import … && opencode --session …`. It could run the import itself —
  but only when the target project is the cwd, since `opencode import` re-homes the session onto the
  *current* project. Worth a `--import` flag rather than doing it silently.
* **Personal commands** from the data repo (`claude-md/commands/`) are not translated into opencode's
  command dir — only the app's `/sj*` family is.

## Open, both

* `bin/claude-index-chats.sh` and `bin/backfill-*.sh` are still Claude-only (they walk
  `~/.claude/projects/`). Harmless — `log-session.sh` skips the index for other harnesses — but a
  backfill for opencode/codex sessions does not exist.
* `bin/onboard.sh` never asks which harnesses to sync; `SCRUBJAY_HARNESSES` has to be set by hand.
