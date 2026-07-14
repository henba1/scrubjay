/**
 * scrubjay — the opencode bridge.
 *
 * opencode has no lifecycle hooks, so this plugin is the SessionStart/SessionEnd that scrubjay
 * needs. It deliberately contains no logic of its own: it launches the same hook scripts every other
 * harness runs, so there is exactly one implementation of "sync the config" and "publish the
 * session" to keep correct.
 *
 *   plugin load    -> hooks/sync-session.sh    (SessionStart: pull config + memory, apply)
 *   session.idle   -> hooks/opencode/publish.sh (export the session, then the shared SessionEnd hook)
 *
 * WHY session.idle: opencode never announces that a session ENDED — a killed TUI sends nothing. idle
 * fires whenever the agent goes quiet, i.e. after every turn, so we publish repeatedly and
 * idempotently instead of once at the end (publish.sh fingerprints the export and skips an unchanged
 * one). That is strictly crash-safer than Claude's SessionEnd: a killed session is already archived
 * up to its last turn.
 *
 * WHY WE ONLY *LAUNCH*, NEVER AWAIT: in `opencode run`, opencode exits ~70ms after session.idle and
 * does not wait for plugin event handlers. Anything we await here — an export takes ~1s — is killed
 * mid-flight and the session is silently lost. publish.sh detaches itself (setsid) and outlives us.
 *
 * Registered by bin/adapters/opencode.sh, which puts THIS path (inside the app repo) into
 * opencode.json's `plugin` array — so `git pull` updates the bridge like any other scrubjay code.
 */

import { dirname, join } from "path"
import { fileURLToPath } from "url"

// <app>/hooks/opencode/scrubjay.js -> <app>
const APP = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const HOOK_SYNC = join(APP, "hooks", "sync-session.sh")
const HOOK_PUBLISH = join(APP, "hooks", "opencode", "publish.sh")

// publish.sh shells out to `opencode export`, and opencode is not necessarily on PATH — its
// installer puts it in ~/.opencode/bin, which a desktop launcher or non-login shell may never have
// sourced. A plugin runs INSIDE opencode's own (Bun-compiled) binary, so process.execPath already
// points at it. Pass that down; keep the bare name only as a fallback.
const OPENCODE = /opencode/.test(process.execPath || "") ? process.execPath : "opencode"

const ScrubjayPlugin = async ({ directory }) => {
  const env = { ...process.env, SCRUBJAY_HARNESS: "opencode", SCRUBJAY_OPENCODE_BIN: OPENCODE }

  // Launch and forget. `unref` + ignored stdio so opencode never waits on us, and never dies on our
  // account either — publish.sh re-launches itself detached anyway.
  const launch = (args) => {
    try {
      Bun.spawn(args, { cwd: directory, env, stdio: ["ignore", "ignore", "ignore"] }).unref()
    } catch {
      // Best-effort, always: the bridge must never take down the session it is recording.
    }
  }

  // SessionStart.
  launch(["bash", HOOK_SYNC])

  return {
    event: async ({ event }) => {
      if (event?.type !== "session.idle") return
      const sessionID = event.properties?.sessionID
      if (sessionID) launch(["bash", HOOK_PUBLISH, sessionID, directory])
    },
  }
}

// The plugin's ONLY export, and it must be the default: opencode's loader reads `mod.default` and
// expects an object carrying `server()` (packages/opencode/src/plugin/shared.ts: readV1Plugin). With
// no default it falls back to a legacy path that iterates EVERY named export and throws
// "Plugin export is not a function" on the first one that isn't — which a stray `export const id`
// string duly did, taking the whole plugin down with it.
//
// One default export satisfies both paths and registers exactly once: the legacy loader's
// getServerPlugin() unwraps an object's .server too, so an older opencode still finds it.
export default { id: "scrubjay", server: ScrubjayPlugin }
