# Harness roadmap

What is left to do per harness. The contract these phases implement is in
[`README.md`](README.md); the seam itself is done (`bin/adapters/`, `bin/sync-config.sh`,
harness-blind `ship-transcript.sh` / `log-session.sh` / `sj-resume.sh`).

| | claude | opencode | codex |
|---|---|---|---|
| relay sessions to the archive | ✅ | ✅ | ✅ |
| readable rendering (cross-harness search) | ✅ | ✅ | ✅ |
| read the archive from inside (sjmcp + `/sj*`) | ✅ | ✅ | ⬜ P3 |
| session hand-off, **same harness** | ✅ | ✅ (auto-`import`) | ⬜ P2 (harder than it looked) |
| session hand-off, **cross-harness** | 🟡 carry-over only — see the open issue below | | |
| config sync *into* the harness | ✅ | ⬜ P3 | ⬜ P3 |

---

# OPEN ISSUE — true cross-harness session translation

**Status: not implemented, and deliberately not faked.**

Today a hand-off between *different* harnesses (a Claude session resumed in opencode, or the
reverse) does **not** produce a native session. `bin/sj-resume.sh` detects the source harness
(`sjh_detect`), sees that it differs from the target, and carries the **conversation** over instead:
it renders the source session's readable Markdown and prints a command that starts a *new* session
seeded with it (`sjh_context_cmd`). You keep the content; you lose the session id, the tool-call
history, and — for Claude — `/rewind`.

That is a floor, not a ceiling. The real thing is **translation**: rewrite the session into the
target harness's own record format so its native resume adopts it, tool history and all.

### Why it isn't done

It is a format-to-format transform between three genuinely different models, and each direction has
its own trap:

* **Claude → opencode.** Feasible, and the most valuable direction. `opencode import` already accepts
  exactly the export shape we archive (`{info, messages: [{info, parts}]}`) and re-homes it onto the
  current project, so a translated Claude transcript would become a *real* resumable opencode
  session. The open question is **id validation**: opencode ids are `ses_`/`msg_`/`prt_` + base62 and
  are decoded through an Effect `Schema` on import (`packages/opencode/src/cli/cmd/import.ts`).
  Establish whether synthesized ids pass that schema before committing to this.
* **opencode → Claude.** Needs a synthesized `uuid` per record *and* the `parentUuid` chain that
  Claude threads a conversation with — plus `tool_use`/`tool_result` pairing by `call_id`. Doable,
  fiddlier, and easy to get subtly wrong in a way that only shows up as a broken `/resume`.
* **codex ↔ anything.** Blocked behind codex P2 anyway (codex resolves sessions through its own
  index, so even a *native* file dropped into `~/.codex/sessions/` may be invisible to it).

Both directions are lossy on tool internals no matter what — a Claude `Bash` tool_use and an opencode
`bash` tool part carry different metadata, and neither harness will honour the other's file-history
snapshots. So translation buys *native resume*, not fidelity.

### Decide before building

Is native resume across harnesses actually worth it, or is carry-over enough? In practice "give the
new agent the whole conversation as context" is what people mean 90% of the time, and it works today
in every direction. Build translation only if continuing the *same session id* with its tool history
turns out to matter in real use.

### If it is built

Add `sjh_translate_from <src-harness> <file> <out>` to the adapter contract — the **target** adapter
owns the transform, because it is the one that knows what it can ingest. `bin/sj-resume.sh` would
then try translation first and fall back to the carry-over path above when the source harness has no
translator. The carry-over path stays either way: it is the only thing that works when a translator
does not exist.

---

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
