# Harness roadmap

What is left to do per harness. The contract these phases implement is in
[`README.md`](README.md); the seam itself is done (`bin/adapters/`, `bin/sync-config.sh`,
harness-blind `ship-transcript.sh` / `log-session.sh` / `sj-resume.sh`).

| | claude | opencode | codex |
|---|---|---|---|
| relay sessions to the archive | ✅ | ✅ | ✅ |
| readable rendering (cross-harness search) | ✅ | ✅ | ✅ |
| read the archive from inside (sjmcp + `/sj*`) | ✅ | ✅ | ⬜ P3 |
| session hand-off (`/sjresume`) | ✅ | 🟡 two-step (stage, then `opencode import`) | ⬜ P2 (harder than it looked) |
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

### ✅ P1 — write path (done)

`bin/adapters/codex.sh` + `bin/render-codex.sh`. Codex sessions are relayed to the archive, land in
the `logs/` catalogue, and are searchable from any harness.

The prediction held: **`hooks/log-session.sh` needed no codex-specific change at all.** The only
edit was harness-neutral — fall back to `sjh_find_live_transcript` when the payload carries no
transcript path — which is exactly the seam doing its job.

Settled while building it (all verified against `openai/codex`, July 2026):

* A rollout line is `{"timestamp", "type", "payload"}` (`RolloutLine`, flattened `RolloutItem`).
  Only `response_item` payloads are conversation: `message` (role + `content[]` of
  `input_text`/`output_text`), `function_call` (whose `arguments` is a JSON **string**),
  `function_call_output` (whose `output` is a string **or** an array of content items),
  `local_shell_call`, `custom_tool_call`. `session_meta` opens every rollout and carries the `cwd`.
* Codex injects `<environment_context>` / `<user_instructions>` as *user* messages, so the topic
  extractor drops user text opening with `<` — the same cut Claude's `<system-reminder>` needs.
* Shell calls arrive as `{"command": ["bash", "-lc", "<script>"]}`; the renderer unwraps the argv so
  a codex session reads like a Claude one.
* `hooks.json` takes `{"hooks": {"<Event>": [{"hooks": [{"type": "command", "command": …}]}]}}` —
  Claude's shape — plus a useful `"async": true`, which `Stop` uses so publishing never delays a turn.
* Per-turn `Stop` needs **no** ship dedupe: the git transport already skips a commit when content
  is unchanged, and the other transports are plain idempotent copies.

### P2 — hand-off INTO codex (harder than it looked)

The earlier plan assumed `codex resume` could be pointed at a file. It cannot:
**`experimental_resume` no longer exists**, and `codex resume <SESSION_ID>` resolves a session
through codex's own index (there is a `state_db` / session index alongside the rollout files). So
dropping a rewritten rollout into `~/.codex/sessions/YYYY/MM/DD/` is probably *not* enough for codex
to see it.

`bin/sj-resume.sh` therefore stages the rollout into an inbox and says plainly that hand-off is not
wired up, rather than printing a command that will not find the session. To finish it, establish —
against a real install — **how codex discovers a session it did not create**:

1. Does `codex resume <uuid>` fall back to scanning `sessions/**` when the id is absent from the
   index, or is the index authoritative?
2. If the index is authoritative: is it rebuildable (some `codex doctor` / re-index path — see
   `codex-rs/cli/src/doctor/thread_inventory.rs`), or must a row be inserted?
3. Does the filename have to match `rollout-<ts>-<uuid>.jsonl` for discovery? (Staging currently
   writes `<sid>.jsonl`, so if the name matters, the contract needs an `sjh_staged_name`.)

`codex-rs/external-agent-migration/src/sessions/` is worth reading first — it imports *other*
agents' sessions into codex, so it already solves this problem the supported way.

### P3 — config sync + MCP (the TOML problem)

Unchanged from the original plan, and still the blocker:

* `settings.base.json` + host overlay is a `jq` merge; codex config is TOML. Either (a) add a tiny
  TOML merge helper (`uv run --script` with `tomlkit` — `uv` is already a hard dependency for
  sjmcp), or (b) ship a whole per-host `config.toml` from the data repo and give up base+overlay
  merging. (a) is more work but keeps one config model across harnesses; prefer it.
* MCP: write `[mcp_servers.sjmcp]` into `config.toml` — same local/remote split as the other two
  adapters. **Verify the schema** (`command` + `args` + `env`; whether stdio is the default).
* Commands: generate `~/.codex/prompts/*.md` from `commands/` the way `_sjh_oc_commands` generates
  opencode's — **but first verify** that codex prompts support `$ARGUMENTS`/`$1` and `` !`shell` ``
  injection. If they don't, the shell-injecting commands (`/sjlog`, `/sjsync`, `/sjmemory`) need a
  different shape. Factor the generator out of `bin/adapters/opencode.sh` into a shared helper at
  that point, rather than copy-pasting it.
* Instructions: `AGENTS.md` symlink from the data repo (shared with opencode's, once P3 lands there).

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
