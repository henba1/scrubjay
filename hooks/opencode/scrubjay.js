/**
 * scrubjay — the opencode bridge.
 *
 * opencode has no lifecycle hooks, so this plugin is the SessionStart/SessionEnd that scrubjay
 * needs. It deliberately contains no logic of its own: it calls the same two hook scripts every
 * other harness calls, so there is exactly one implementation of "sync the config" and "publish the
 * session" to keep correct.
 *
 *   plugin load    -> hooks/sync-session.sh   (SessionStart: pull config + memory, apply, warn on a
 *                                              failed relay)
 *   session.idle   -> hooks/log-session.sh    (SessionEnd: log line, data-repo push, memory push,
 *                                              relay the session's records)
 *
 * WHY session.idle, and why that is fine: opencode never announces that a session ENDED — a killed
 * TUI sends nothing. session.idle fires whenever the agent goes quiet, i.e. after every turn. So we
 * publish repeatedly and idempotently instead of once at the end. The relay overwrites by path, and
 * we skip an export that is byte-identical to the one we last shipped, so the cost of the extra
 * fires is one `opencode export` per turn — and the payoff is that a crashed session is already
 * archived up to its last turn, which Claude's SessionEnd cannot promise.
 *
 * Registered by bin/adapters/opencode.sh, which puts THIS path (inside the app repo) into
 * opencode.json's `plugin` array — so `git pull` updates the bridge like any other scrubjay code.
 */

import { dirname, join } from "path"
import { fileURLToPath } from "url"
import { tmpdir } from "os"
import { unlink, writeFile } from "fs/promises"

// <app>/hooks/opencode/scrubjay.js -> <app>
const APP = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const HOOK_SYNC = join(APP, "hooks", "sync-session.sh")
const HOOK_LOG = join(APP, "hooks", "log-session.sh")

const ENV = { ...process.env, SCRUBJAY_HARNESS: "opencode" }

/** What we last shipped per session, so an idle that changed nothing is a no-op. */
const shipped = new Map()
/** Sessions with a publish in flight — idle can fire again while `opencode export` is running. */
const inflight = new Set()

export const id = "scrubjay"

export const ScrubjayPlugin = async ({ $, directory }) => {
  const sh = $.cwd(directory).env(ENV).quiet().nothrow()

  // SessionStart. Fire-and-forget: a slow NAS or a network hiccup must never delay the first
  // prompt, exactly as the Claude hook is allowed to run long without blocking the session.
  sh`bash ${HOOK_SYNC} < /dev/null`.catch(() => {})

  const publish = async (sessionID) => {
    if (process.env.SCRUBJAY_NOSHIP === "1") return
    if (inflight.has(sessionID)) return
    inflight.add(sessionID)
    let staged
    try {
      // The export IS the transcript: one JSON document that `opencode import` can read back.
      // No --sanitize — scrubjay archives the real conversation to the user's own storage, and a
      // redacted transcript would be worthless to resume from.
      const out = await sh`opencode export ${sessionID}`
      if (out.exitCode !== 0) return
      const text = out.stdout.toString()
      if (!text.trim()) return

      let parsed
      try {
        parsed = JSON.parse(text)
      } catch {
        return // a half-written export is not worth shipping
      }
      if (!parsed?.info?.id) return

      // Idle fires after every turn; only the ones that actually changed the session are worth a
      // relay (and, on the git backend, a commit).
      const fingerprint = `${text.length}:${Bun.hash(text)}`
      if (shipped.get(sessionID) === fingerprint) return

      staged = join(tmpdir(), `scrubjay-opencode-${sessionID}.json`)
      await writeFile(staged, text)

      // The same payload Claude Code hands a SessionEnd hook. `--detached` runs the work inline
      // rather than re-launching (we are not shutting down, so nothing is about to kill us).
      const payload = JSON.stringify({
        session_id: parsed.info.id,
        cwd: parsed.info.directory || directory,
        transcript_path: staged,
      })
      const res = await sh`printf %s ${payload} | bash ${HOOK_LOG} --detached`
      if (res.exitCode === 0) shipped.set(sessionID, fingerprint)
    } catch {
      // Best-effort, always: publishing must never take down the session it is recording.
    } finally {
      if (staged) await unlink(staged).catch(() => {})
      inflight.delete(sessionID)
    }
  }

  return {
    event: async ({ event }) => {
      if (event?.type === "session.idle") await publish(event.properties.sessionID)
    },
  }
}

// v2 plugin modules export `server`; older opencode picks up any exported plugin function. The
// loader takes the v2 shape first and returns, so exporting both cannot double-register.
export const server = ScrubjayPlugin
