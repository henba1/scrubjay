// SPDX-License-Identifier: FSL-1.1-ALv2
// Copyright (c) 2026 Hendrik Baacke. See LICENSE.

/**
 * scrubjay in opencode's TUI: its /sj* commands drawn in scrubjay blue, apart from ordinary turns.
 *
 * opencode's TUI plugins draw into fixed slots, not into the transcript, so a past message cannot be
 * recoloured (the Claude Code mod, mods/scrubjay-ui, can). What this draws instead:
 *   session_prompt_right  `◆ scrubjay /sjtable head=10` while that command's turn runs
 *   sidebar_content       the session's /sj* commands so far, newest last
 *
 * Registered in tui.json's `plugin` array by bin/adapters/opencode.sh. opencode compiles a .tsx
 * plugin with Solid itself and supplies solid-js and @opentui/solid, so nothing is installed.
 */

/** @jsxImportSource @opentui/solid */
import { For, Show, createSignal } from "solid-js"

const SJ_BLUE = "#4f8ff7"
const KEEP = 8 // sidebar rows per session

type Ran = { name: string; args: string }

const tui = async (api: any) => {
  const [running, setRunning] = createSignal<Record<string, Ran | undefined>>({})
  const [history, setHistory] = createSignal<Record<string, Ran[]>>({})

  api.event.on("command.executed", (ev: any) => {
    const { name, arguments: args, sessionID } = ev.properties ?? {}
    if (typeof name !== "string" || !/^sj[a-z]+$/.test(name)) return
    const ran = { name, args: String(args ?? "").trim() }
    setRunning((r) => ({ ...r, [sessionID]: ran }))
    setHistory((h) => ({ ...h, [sessionID]: [...(h[sessionID] ?? []), ran].slice(-KEEP) }))
  })
  api.event.on("session.idle", (ev: any) => {
    const sid = ev.properties?.sessionID
    setRunning((r) => ({ ...r, [sid]: undefined }))
  })

  const line = (r: Ran) => `/${r.name}${r.args ? ` ${r.args}` : ""}`

  api.slots.register({
    order: 50,
    slots: {
      session_prompt_right(_ctx: any, props: { session_id: string }) {
        return (
          <Show when={running()[props.session_id]}>
            {(r: () => Ran) => (
              <text fg={SJ_BLUE}>
                <b>◆ scrubjay</b> {line(r())}
              </text>
            )}
          </Show>
        )
      },
      sidebar_content(_ctx: any, props: { session_id: string }) {
        return (
          <Show when={(history()[props.session_id] ?? []).length > 0}>
            <box>
              <text fg={SJ_BLUE}>
                <b>◆ scrubjay</b>
              </text>
              <For each={history()[props.session_id] ?? []}>
                {(r: Ran) => <text fg={SJ_BLUE}>{line(r)}</text>}
              </For>
            </box>
          </Show>
        )
      },
    },
  })
}

export default { id: "scrubjay-tui", tui }
