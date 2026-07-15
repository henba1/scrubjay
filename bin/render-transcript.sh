#!/usr/bin/env bash
# Render a Claude transcript .jsonl as a human-readable Markdown conversation / session log:
# user + assistant text turns, plus the full tool stream — each tool call shows its input
# (Bash commands verbatim, other tools as JSON) and the tool's output is rendered inline.
# Tool calls + their results are folded into the assistant action stream so each user prompt
# is followed by one continuous "text → command → output → …" block. Thinking and system/meta
# lines are still dropped. Consecutive same-role turns are merged.
#   usage: render-transcript.sh <transcript.jsonl>   > out.md
set -uo pipefail
src="${1:?usage: render-transcript.sh <transcript.jsonl>}"
command -v jq >/dev/null 2>&1 || { echo "(jq unavailable — cannot render $src)"; exit 0; }
[ -f "$src" ] || { echo "(transcript not found: $src)"; exit 0; }

jq -rs '
  def hdr($r): if $r=="user" then "## User" else "## Assistant" end;
  def keepstr($s): ($s|type)=="string" and ((($s|startswith("<")) or ($s|startswith("Caveat"))) | not);
  def fence($lang; $body): "```" + $lang + "\n" + ($body|rtrimstr("\n")) + "\n```";
  # a tool_use call: name + its input (Bash command verbatim, else compact JSON)
  def render_call(u):
    "**→ " + (u.name // "tool") + "**\n\n"
    + (if (u.input.command) then fence("bash"; u.input.command)
       else fence("json"; (u.input // {} | tojson)) end);
  # a tool_result: its output text (string or text blocks), as a plain fenced block
  def render_result(r):
    ( if (r.content|type)=="string" then r.content
      else [ r.content[]? | select(.type=="text") | .text ] | join("\n") end ) as $o
    | "**⎿ " + (if r.is_error then "error" else "output" end) + ":**\n\n" + fence("text"; $o);
  [ .[]
    | if .type=="user" then
        ( .message.content as $c
          | if ($c|type)=="string"
            then (if keepstr($c) then {role:"user", text:$c} else empty end)
            # array content carrying tool_result(s) = tool output → assistant action stream
            elif ([ $c[]? | select(.type=="tool_result") ] | length) > 0
            then ( [ $c[]? | select(.type=="tool_result") | render_result(.) ] | join("\n\n") )
                 | {role:"assistant", text:.}
            else ( [ $c[]? | select(.type=="text") | .text | select(keepstr(.)) ] | join("\n\n") ) as $t
                 | (if ($t|gsub("\\s";"")) != "" then {role:"user", text:$t} else empty end)
            end )
      elif .type=="assistant" then
        ( [ .message.content[]?
            | if .type=="text" then .text
              elif .type=="tool_use" then render_call(.)
              else empty end ] | join("\n\n") ) as $t
        | (if ($t|gsub("\\s";"")) != "" then {role:"assistant", text:$t} else empty end)
      else empty end
  ] as $turns
  | ([ $turns[] | select(.role=="user") | .text ][0] // "(no prompt)") as $topic
  | ($topic | gsub("\\s+";" ") | .[0:80]) as $title
  # count the rendered blocks, not the pre-merge records: consecutive same-role turns and folded
  # tool output collapse into one block, and that block count is what sjmcp reports as session size.
  | ( reduce $turns[] as $f ( {out:[], last:""};
        if $f.role == .last
        then .out[-1] += "\n\n" + $f.text
        else .out += [ "\n" + hdr($f.role) + "\n\n" + $f.text ] | .last = $f.role
        end )
      | .out ) as $blocks
  | "# " + $title + "\n\n_" + ($blocks | length | tostring) + " turns_\n"
    + ( $blocks | join("") )
' "$src"
