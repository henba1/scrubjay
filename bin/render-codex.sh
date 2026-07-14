#!/usr/bin/env bash
# Render a Codex CLI rollout (~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl) as a
# human-readable Markdown conversation — the codex counterpart of bin/render-transcript.sh and
# bin/render-opencode.sh, and deliberately the SAME output shape: a `# title` line, a `_N turns_`
# line, then `## User` / `## Assistant` blocks with the tool stream folded into the assistant's turn.
#
# That sameness is what lets /sjrecall and /sjbrowse search Claude, opencode and codex sessions side
# by side, and what mcp/sjmcp_server.py reads the turn count off.
#
#   usage: render-codex.sh <rollout.jsonl>   > out.md
#
# The schema (codex-rs/protocol/src/{protocol,models}.rs): every line is a RolloutLine —
#   {"timestamp": …, "type": "<variant>", "payload": {…}}
# We render only `response_item` payloads, which are Responses-API items:
#   message              role user|assistant, content[] of input_text / output_text
#   function_call        name + `arguments` (a JSON *string*, not an object) + call_id
#   function_call_output output: a plain string OR an array of content items
#   local_shell_call     an exec action, for models that use the shell tool directly
# reasoning / session_meta / turn_context / event_msg / compacted are dropped — they are thinking
# and bookkeeping, the same cut the Claude renderer makes.
set -uo pipefail
src="${1:?usage: render-codex.sh <rollout.jsonl>}"
command -v jq >/dev/null 2>&1 || { echo "(jq unavailable — cannot render $src)"; exit 0; }
[ -f "$src" ] || { echo "(rollout not found: $src)"; exit 0; }

jq -rs '
  def hdr($r): if $r == "user" then "## User" else "## Assistant" end;
  def fence($lang; $body): "```" + $lang + "\n" + ($body | rtrimstr("\n")) + "\n```";

  # codex runs shell tools as {"command": ["bash", "-lc", "<script>"], …} — show the script itself,
  # not the argv wrapper, so a rendered codex session reads like a rendered Claude one.
  def shell_script($cmd):
    if ($cmd | type) == "array" and ($cmd | length) >= 3 and $cmd[0] == "bash" and $cmd[1] == "-lc"
    then $cmd[2]
    elif ($cmd | type) == "array" then ($cmd | join(" "))
    else ($cmd | tostring) end;

  # `arguments` is a JSON string on the wire; a tool whose args carry a command gets a bash fence.
  def render_call($name; $args):
    ($args | if type == "string" then (fromjson? // null) else . end) as $a
    | "**→ " + ($name // "tool") + "**\n\n"
      + (if ($a | type) == "object" and ($a.command? // null) != null
         then fence("bash"; shell_script($a.command))
         else fence("json"; (($a // $args) | tojson)) end);

  def output_text($o):
    if ($o | type) == "string" then $o
    elif ($o | type) == "array" then ([ $o[] | .text? // empty ] | join("\n"))
    else ($o | tojson) end;

  [ .[]
    | select(.type == "response_item") | .payload
    | if .type == "message" then
        ( [ .content[]? | select(.type == "input_text" or .type == "output_text") | .text ]
          | join("\n\n") ) as $t
        | (if .role == "user" then
             # drop codex-injected context (<environment_context>, <user_instructions>, …)
             (if ($t | gsub("\\s"; "")) != "" and ($t | startswith("<") | not)
              then {role: "user", text: $t} else empty end)
           else
             (if ($t | gsub("\\s"; "")) != "" then {role: "assistant", text: $t} else empty end)
           end)
      elif .type == "function_call" then
        {role: "assistant", text: render_call(.name; .arguments)}
      elif .type == "local_shell_call" then
        {role: "assistant", text: render_call("shell"; (.action // {}))}
      elif .type == "function_call_output" then
        (output_text(.output) | select((. | gsub("\\s"; "")) != "")
         | {role: "assistant", text: ("**⎿ output:**\n\n" + fence("text"; .))})
      elif .type == "custom_tool_call" then
        {role: "assistant", text: render_call((.name // "tool"); (.input // {}))}
      elif .type == "custom_tool_call_output" then
        (output_text(.output) | select((. | gsub("\\s"; "")) != "")
         | {role: "assistant", text: ("**⎿ output:**\n\n" + fence("text"; .))})
      else empty end
  ] as $turns
  | ([ $turns[] | select(.role == "user") | .text ][0] // "(no prompt)") as $topic
  | ($topic | gsub("\\s+"; " ") | .[0:80]) as $title
  | "# " + $title + "\n\n_" + ($turns | length | tostring) + " turns_\n"
    + ( reduce $turns[] as $f ( {out: [], last: ""};
          if $f.role == .last
          then .out[-1] += "\n\n" + $f.text
          else .out += [ "\n" + hdr($f.role) + "\n\n" + $f.text ] | .last = $f.role
          end )
        | .out | join("") )
' "$src"
