# Keeping agents alive

Close the terminal an agent runs in (or lose the SSH connection to it) and the agent dies with
it, mid-turn. The terminal hangs up, the shell passes the hang-up on, and Claude Code, opencode or
codex exits wherever it was. scrubjay can run interactive agents inside
[tmux](https://github.com/tmux/tmux/wiki) instead. Then a dropped connection only *detaches* you,
the agent keeps working, and you attach again later from any terminal.

## Setup

You need two things: **tmux** on the machine the agent runs on, and the setting that turns this on.

```sh
sudo apt install tmux        # Debian/Ubuntu/Raspberry Pi OS; brew install tmux, dnf, pacman …
echo ': "${SCRUBJAY_KEEP:=ssh}"' >> ~/.config/scrubjay/config
```

You also need the [shell integration](handoff.md#from-a-terminal-claude-resume-sid). Its `claude`,
`opencode` and `codex` functions route a launch through `bin/sj-keep.sh`. `bin/onboard.sh` asks
about both, and `/sjdoctor` reports what's missing, with the install command for your system.

| `SCRUBJAY_KEEP` | Effect |
|---|---|
| `off` (default) | agents run as before |
| `ssh` | wrap when the shell came in over SSH. That's where sessions get lost, and the recommended setting |
| `always` | wrap whenever you're not already inside tmux |

### Why tmux isn't bundled

tmux is a distro package with its own security updates, built per architecture and per OS.
Shipping a copy would mean scrubjay owning those updates for Linux on arm64 and x86-64, WSL and
macOS. Every package manager already carries it, and most servers and HPC login nodes have it
installed. So scrubjay treats it like `rsync` or `uv`: an optional dependency it detects, reports
and tells you how to install, never something it installs as root for you.

## Finding and resuming sessions: `sj`

**`sj` is the way to find a session and get back into it**, wherever it runs. It is a shell function
from the [shell integration](handoff.md#from-a-terminal-claude-resume-sid) (`bin/sj.sh`; without the
integration, run `~/.scrubjay/scrubjay/bin/sj.sh` by path).

```sh
sj ls                  # every agent on every machine: host, sid, state, idle, tmux session, folder, topic
sj attach <name|sid8>  # back into a running one: tmux here, or ssh -t <host> tmux attach there
sj resume <sid8>       # continue one, by whichever path fits, and it says which
```

```text
HOST       SID      STATE    IDLE    TMUX                           FOLDER               TOPIC
laptop     9eaf6b3c working  0m      sj-claude-widget-api*          widget-api           Retry backoff fix
laptop     7499b331 idle     4h35m   sj-claude-widget-api-2         widget-api           Rate limiter tests
nas        8051500c idle     4h24m   as of 18:00                    infra                Cert renewal
laptop     f7b8250f reaped   1h29m   -                              docs-site            Docs rewrite
* attached   as of: a relayed snapshot from that host's last publish, its process not checked

stopped by sj-reap (its screen was saved first):
  2026-11-14 20:55 f7b8250f sj-claude-docs-site          idle 1d6h                sj resume f7b8250f
```

States: `working` (mid-turn), `waiting` (at a permission prompt), `idle` (its turn is over), `ended`
(closed cleanly), `exited` (the process went without saying so, or its pane is held open after a
crash), `reaped` (stopped by [the reaper](#stray-agents-are-reaped)). Rows from this machine come
from the harness's process registry and tmux, as `sj-reap.sh` reads them. Rows from other machines
come from the leases they relay into the archive with each publish, the ones `/sjview` shows, so they
say **as of** when that host last published: sj can't ask a process on another machine whether it
is still there. A machine with no filesystem view of the archive (`rsync-wg`) shows only itself.
Ended and exited sessions are listed for a day (`SCRUBJAY_SJ_RECENT`, seconds).

`sj resume <sid8>` takes the first of these that applies:

1. **Running here in tmux:** it attaches. A fresh resume would load the conversation into a second
   process, and the two would diverge.
2. **Running on another machine** (its last relayed lease says so): it asks whether to attach there
   over ssh or hand it off anyway, warning that the copy there won't see the new turns.
3. **Stopped, transcript here:** `cd <its folder> && claude --resume <sid>`.
4. **Not on this machine:** the [cross-machine hand-off](handoff.md), `claude resume <sid>`.

It won't start a second copy of a live session without `--force`, and that includes one running here
outside tmux, in a plain terminal you can't attach to. An ambiguous prefix lists the candidates.

**Other machines are reached by their SSH alias.** When the scrubjay host name is also a `Host`
alias in `~/.ssh/config`, that works as it is. Otherwise name it, e.g.
`SCRUBJAY_SSH_HOSTS="nas=nas-lan laptop=laptop.wg"` in `~/.config/scrubjay/config`. With neither, sj
prints the command to run on that machine instead of guessing. Attaching there asks that machine's
own `sj where <sid>` which tmux session holds it, so it needs a current scrubjay there too.

What it wraps, if you'd rather type them: `tmux attach -t <name>`, `claude -c` / `claude --resume
<sid>`, `claude resume <sid>` and `/sjresume` (hand-off), and `sj-reap.sh ls` / `sj-keep.sh ls`
(what runs here). An `sj` command, alias or function of your own wins: the integration doesn't define
one then, and `bin/sj.sh` still works by path.

## Using it

Start an agent exactly as before:

```sh
cd ~/code/widget-api
claude                       # now inside tmux session sj-claude-widget-api
```

| To… | Do |
|---|---|
| leave it running on purpose | `Ctrl-b` then `d` (detach), or close the terminal |
| see what's running, here and elsewhere | `sj ls` |
| go back in | `sj attach sj-claude-widget-api` (or its sid8; plain `tmux attach -t …` works too) |
| switch between kept sessions while attached | `Ctrl-b` then `s`, pick one |
| scroll back through output | `Ctrl-b` then `[`, arrows or PgUp, `q` to leave (or turn the mouse on, below) |
| end it | quit the agent as usual; the session closes with it |

Things that are worth knowing:

- **Session names.** A session is named `sj-<harness>-<folder>`. A second agent in the same folder
  gets `-2`, `-3` …, never the first one's session. After a detach, the reattach command is
  printed.
- **Resuming offers the agent that is still running.** `claude -c`/`--continue`/`-r`/`--resume`,
  `opencode -c`/`--session` and `codex resume` first look for a detached session of that harness
  started in this folder. That is usually the agent you left, still working, so you are asked
  `attach to it instead of starting a second copy? [Y/n]`. Enter attaches. `n`, or no answer at
  all, starts a new session as before. A second copy would reload the conversation from disk,
  missing whatever the first one did after you left, and both would keep writing to the same
  transcript.
- **Only interactive launches are wrapped.** `claude -p`, `claude --bg`, `claude mcp …`,
  `opencode serve`, `opencode run`, `codex exec`, `--version` and other subcommands run directly.
  So does anything launched without a terminal (scripts, pipes, cron) or from inside tmux, so an
  existing tmux habit is left alone.
- **Your environment comes along.** The agent sees the variables of the shell you launched it
  from, even when the tmux server was started days earlier with different ones.
- **It never blocks a launch.** With no tmux installed, or a tmux that can't start a session, you
  get one line on stderr and the agent runs unprotected, as before.
- **Any other agent, by hand:** `~/.scrubjay/scrubjay/bin/sj-keep.sh -- pi`.

### Stray agents are reaped

A kept agent costs a few hundred MB for as long as it runs, also when you never come back to it, and
a small box that runs out of memory resets. So `bin/sj-reap.sh` runs from cron every 15 minutes
(onboarding installs it with `SCRUBJAY_KEEP` on; by hand: `sj-reap.sh install`) and stops strays:

| Stray | When |
|---|---|
| detached and idle | warned at 12 h (`reap.log`, once), stopped at 24 h |
| a duplicate copy of one conversation (a resume while the first copy ran on) | 30 min after that copy's last own activity; the attached copy, else one outside tmux, else the newest, is kept |
| idle while memory is short (RAM available < 15 % or swap > 70 % used) | at 12 h, oldest first, until it isn't |
| an empty pane: the agent already exited (an OOM killer, a crash) and sj-keep holds its last screen open for you to read | after 1 h without output (`SCRUBJAY_REAP_EMPTY_AFTER`); the screen goes to `~/.scrubjay/run/reaped/<session>-<time>.txt` first |

Before it stops one, it saves what only the running process holds:

1. The tmux pane's screen and scrollback, including a prompt you typed but never sent. It goes to
   `<sid>/reaped-<time>.txt` beside the transcript, so the relay carries it with the session.
2. It publishes the session the way `/sjlog` does, since SessionEnd won't fire.
3. It sends SIGTERM, then SIGKILL after 30 s, and closes the pane.
4. It writes a line to `~/.scrubjay/run/reap.log` with the command to resume. With
   `SCRUBJAY_REAP_NOTIFY=<command>` set, that command gets the same line.

Never stopped: anything outside an `sj-*` session, an attached session, a turn in progress, a
permission prompt, a background shell still running, or a session whose transcript, subagents or
background tasks were written to recently. Idle time counts from the transcript's last *record*, not
the file's mtime, which other tools touch.

```sh
~/.scrubjay/scrubjay/bin/sj-reap.sh ls             # every agent here: idle age and verdict
~/.scrubjay/scrubjay/bin/sj-reap.sh run --dry-run  # what the next run would do
```

`SCRUBJAY_REAP=warn` only logs. `off` turns it off.

### Optional: a friendlier tmux

tmux works without a config file. Two settings make it feel more like a normal terminal:

```sh
cat >> ~/.tmux.conf <<'EOF'
set -g mouse on              # scroll wheel and click-to-select, instead of Ctrl-b [
set -g history-limit 50000   # more scroll-back than the 2000-line default
EOF
```

If Shift+Enter doesn't insert a newline in Claude Code inside tmux, type `\` then Enter instead.

### The status bar

tmux's own bar says little about an agent: `[sj-claude-w` and `0:bash*` on bright green. scrubjay
ships one that says what the agent in the pane is doing, and what else runs in its project:

```text
 widget ⎇ main · a1b2c3d4 · ● working 2m   ┊  ◐ 9f8e7d6c feat/retry 5s · ○ 77aa0c1e gk 1m      Retry backoff · 18:40 · Mon 9 Nov · henpi
```

- **left:** this pane's session: its project (the git repository) ⎇ branch · session id · its state
  and since when. `●` working, `◐` waiting for your answer (a permission prompt), `○` idle.
- **then, after `┊`:** the project's other sessions on this machine, the most recent first. A
  session in a subfolder or another worktree of the repo is the same project; its branch is shown
  when it differs. One running in GreyKnight's agent pane says `gk`, in another Neovim `nvim`. More
  than fit: `+n`.
- **right:** the session's title, time, date and host. On a narrow terminal the bar drops things to
  fit, related sessions first, then the date.
- **a click on a related session** switches to its tmux pane (tmux 3.4 and later). **A click
  elsewhere on the left** opens a menu of those sessions, which works on any tmux: choosing one
  switches to it (one in a Neovim can't be switched to and is shown greyed out). "All tmux sessions"
  is tmux's own picker. Clicks need `set -g mouse on`.

It is black and dim, and nothing on it stays put: the text drifts a cell every two minutes and its
grey breathes slowly, so an OLED screen doesn't burn it in. `SCRUBJAY_STATUS_DRIFT=off` keeps it
still; `SCRUBJAY_STATUS_MAX` (default 3) is how many related sessions it names.

`bin/onboard.sh` offers to add it; by hand, one line in `~/.tmux.conf`:

```sh
source-file "$HOME/.claude/hooks/../tmux/scrubjay.conf"   # tmux expands $HOME; with CLAUDE_CONFIG_DIR, its path
```

Where the information comes from: each harness's own registry of running sessions (Claude Code's
`~/.claude/sessions/`, via `bin/sj-live.sh`), the leases for the waiting state, and the process tree
for where a session runs. It is read at most every eight seconds, however many clients look.

## Limits

- **It protects against the terminal going away, not the machine.** A reboot, power cut or a
  laptop going to sleep still stops the agent. For agents that must outlive you closing a laptop,
  run them on a machine that stays up and reach it over SSH. That's the case this is built for.
- **HPC clusters:** a login alias often round-robins between several login nodes. tmux sessions
  live on the node that started them, so reattach with that node's own name. Some clusters also
  kill long-running processes on login nodes; check the site's policy.
- **Harness-native alternatives exist for one harness each:** `claude --bg` plus `claude attach`,
  and `opencode serve` plus `opencode attach`. They work alongside this, and `sj-keep` leaves them
  alone (they're never wrapped).
