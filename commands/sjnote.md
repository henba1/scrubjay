---
description: scrubjay — write a durable note (analysis, briefing, rationale) to the cross-machine store
argument-hint: [what to capture | /path/to/existing/file] [topic=…]
allowed-tools: Bash(bash:*), mcp__sjmcp__sj_list
---
The user wants a written artefact kept **durably**, not dropped in the session scratchpad. Notes
live in the cross-machine store (`<memory>/<project>/notes/`), so they survive the session, reach
every machine, and can be edited later — but they are **not** loaded into future sessions unless
someone asks for them.

Request: **$ARGUMENTS**

## Which mode you are in

- **Retrospective** — the user names something already in this conversation ("the licensing
  analysis above"). Write that up now.
- **Prospective** — the user invokes `/sjnote` before the work exists, or with a task ("work out
  how the FSL changes Document B"). Do the work, then write it up. Treat the invocation as
  standing for the rest of the session: further durable artefacts go here, **not** to the
  scratchpad under `/tmp`.
- **Promotion** — the argument is a path to a file that already exists. Pass it through with
  `--from`; do not rewrite its content.

## Writing it

Compose the note, then pipe it in:

```sh
bash ~/.claude/hooks/../bin/sj-note.sh --topic "fsl impact on document b" <<'EOF'
# FSL impact on Document B
…
EOF
```

or, to promote an existing file:
`bash ~/.claude/hooks/../bin/sj-note.sh --from /path/to/file --topic "…"`.
The script names the file, backlinks it to this session, updates the one-line `notes/` pointer in
`MEMORY.md`, and publishes immediately. It prints the path — report that path back.

**Prose: neutral and concise.** Scientific register — state the finding and the reasoning that
supports it; drop the framing, the recap of what was asked, and the closing summary. Structure with
headings and short paragraphs. Start the note with a single `#` heading (it becomes the topic when
`--topic` is absent). Write it to be read in six months by someone who was not in this conversation:
say what was decided and why, not what the conversation felt like.

## What a note is not

A note is **not** a memory. A memory is a one-line fact that belongs in `MEMORY.md` and is loaded
into every future session; a note is a document that is retrieved on demand. If what the user wants
saved is a durable *preference* or *fact*, write a memory instead and say so.

Notes are read back with `/sjrecall`, `/sjbrowse note`, or `sj_list(type="note")` — do not build a
listing here.
