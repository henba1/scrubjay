#!/usr/bin/env bash
# Render a Claude transcript .jsonl as a clean, human-readable Markdown conversation:
# user + assistant text turns; tool calls collapsed to one-line "→ <tool>" notes; thinking,
# tool results, and system/meta lines dropped. Consecutive same-role turns are merged.
#   usage: render-transcript.sh <transcript.jsonl>   > out.md
set -uo pipefail
src="${1:?usage: render-transcript.sh <transcript.jsonl>}"
command -v jq >/dev/null 2>&1 || { echo "(jq unavailable — cannot render $src)"; exit 0; }
[ -f "$src" ] || { echo "(transcript not found: $src)"; exit 0; }

jq -rs '
  def hdr($r): if $r=="user" then "## User" else "## Assistant" end;
  def keepstr($s): ($s|type)=="string" and ((($s|startswith("<")) or ($s|startswith("Caveat"))) | not);
  [ .[]
    | if .type=="user" then
        ( .message.content as $c
          | if ($c|type)=="string"
            then (if keepstr($c) then {role:"user", text:$c} else empty end)
            else ( [ $c[]? | select(.type=="text") | .text ] | join("\n\n") ) as $t
                 | (if ($t|gsub("\\s";"")) != "" then {role:"user", text:$t} else empty end)
            end )
      elif .type=="assistant" then
        ( [ .message.content[]?
            | if .type=="text" then .text
              elif .type=="tool_use" then "→ " + (.name // "tool")
              else empty end ] | join("\n\n") ) as $t
        | (if ($t|gsub("\\s";"")) != "" then {role:"assistant", text:$t} else empty end)
      else empty end
  ] as $turns
  | ([ $turns[] | select(.role=="user") | .text ][0] // "(no prompt)") as $topic
  | ($topic | gsub("\\s+";" ") | .[0:80]) as $title
  | "# " + $title + "\n\n_" + ($turns | length | tostring) + " turns_\n"
    + ( reduce $turns[] as $f ( {out:[], last:""};
          if $f.role == .last
          then .out[-1] += "\n\n" + $f.text
          else .out += [ "\n" + hdr($f.role) + "\n\n" + $f.text ] | .last = $f.role
          end )
        | .out | join("") )
' "$src"
