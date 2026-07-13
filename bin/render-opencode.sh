#!/usr/bin/env bash
# Render an opencode session export (`opencode export <sid>`) as a human-readable Markdown
# conversation — the opencode counterpart of bin/render-transcript.sh, and deliberately the SAME
# output shape: a `# <title>` line, a `_N turns_` line, then `## User` / `## Assistant` blocks with
# the tool stream folded into the assistant's turn (call input, then its output).
#
# That sameness is the point. The readable/ tree is the one layer every harness shares, so /sjrecall
# and /sjbrowse search Claude and opencode sessions side by side without knowing the difference —
# and mcp/sjmcp_server.py reads the turn count straight off the `_N turns_` line.
#
#   usage: render-opencode.sh <export.json>   > out.md
#
# The export is one JSON document: { info: {id, title, directory, …},
#                                    messages: [ { info: {role, …}, parts: [ … ] } ] }
# Parts we render: text (unless synthetic/ignored — that is opencode's injected context, not the
# conversation) and tool (name + input, then the completed output). reasoning/snapshot/step-* are
# dropped, matching the Claude renderer's treatment of thinking and meta records.
set -uo pipefail
src="${1:?usage: render-opencode.sh <export.json>}"
command -v jq >/dev/null 2>&1 || { echo "(jq unavailable — cannot render $src)"; exit 0; }
[ -f "$src" ] || { echo "(export not found: $src)"; exit 0; }

jq -r '
  def hdr($r): if $r == "user" then "## User" else "## Assistant" end;
  def fence($lang; $body): "```" + $lang + "\n" + ($body | rtrimstr("\n")) + "\n```";

  # a tool part: name + input (a shell command verbatim, anything else as JSON), then its output
  def render_tool(p):
    ((p.state.input // {}) as $in
     | "**→ " + (p.tool // "tool") + "**\n\n"
       + (if ($in.command? // null) != null then fence("bash"; $in.command)
          else fence("json"; ($in | tojson)) end)
       + (if (p.state.status? == "completed") and ((p.state.output // "") != "")
          then "\n\n**⎿ output:**\n\n" + fence("text"; p.state.output)
          elif (p.state.status? == "error")
          then "\n\n**⎿ error:**\n\n" + fence("text"; (p.state.error // "failed"))
          else "" end));

  [ .messages[]?
    | (.info.role // "assistant") as $role
    | ( [ .parts[]?
          | if .type == "text" and (.synthetic | not) and (.ignored | not)
              then (.text // "")
            elif .type == "tool" then render_tool(.)
            else empty end ] | join("\n\n") ) as $t
    | select(($t | gsub("\\s"; "")) != "")
    | {role: $role, text: $t}
  ] as $turns
  | ( [ $turns[] | select(.role == "user") | .text ][0] // .info.title // "(no prompt)" ) as $topic
  | ($topic | gsub("\\s+"; " ") | .[0:80]) as $title
  | "# " + $title + "\n\n_" + ($turns | length | tostring) + " turns_\n"
    + ( reduce $turns[] as $f ( {out: [], last: ""};
          if $f.role == .last
          then .out[-1] += "\n\n" + $f.text
          else .out += [ "\n" + hdr($f.role) + "\n\n" + $f.text ] | .last = $f.role
          end )
        | .out | join("") )
' "$src"
