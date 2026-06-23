# logs/ — session history

One file per machine (`<host>.log`), appended by the `SessionEnd` hook
(`hooks/log-session.sh`, fires once when a session ends) — **one line per Claude Code
session**:

```
2026-06-23 20:45 | snellius | /gpfs/home2/jvrijn/code/VERONA | "add L2 attack to the foolbox example" | session=a65fb7ea-...
```

Fields: `timestamp | host | cwd | "first user prompt (topic)" | session=<id>`.

- **One line per session** — written once when the session ends, so the file is one row
  per chat, not per message.
- **Auto-committed + pushed** by the hook (just this file), so every machine's history
  is browseable from any clone — answers *"I had a chat about X somewhere — where?"*
  via `grep`:

  ```sh
  grep -i foolbox logs/*.log
  ```

The full transcript still lives only on its host (`~/.claude/projects/<slug>/`); this is
just the searchable pointer. Set `DOTCLAUDE_LOG_NOGIT=1` to append without git.
