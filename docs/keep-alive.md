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

## Using it

Start an agent exactly as before:

```sh
cd ~/code/widget-api
claude                       # now inside tmux session sj-claude-widget-api
```

| To… | Do |
|---|---|
| leave it running on purpose | `Ctrl-b` then `d` (detach), or close the terminal |
| see what's running here | `~/.scrubjay/scrubjay/bin/sj-keep.sh ls` (or `tmux ls`) |
| go back in | `tmux attach -t sj-claude-widget-api` |
| switch between kept sessions while attached | `Ctrl-b` then `s`, pick one |
| scroll back through output | `Ctrl-b` then `[`, arrows or PgUp, `q` to leave (or turn the mouse on, below) |
| end it | quit the agent as usual; the session closes with it |

Things that are worth knowing:

- **Session names.** A session is named `sj-<harness>-<folder>`. A second agent in the same folder
  gets `-2`, `-3` …, never the first one's session. After a detach, the reattach command is
  printed.
- **Only interactive launches are wrapped.** `claude -p`, `claude --bg`, `claude mcp …`,
  `opencode serve`, `opencode run`, `codex exec`, `--version` and other subcommands run directly.
  So does anything launched without a terminal (scripts, pipes, cron) or from inside tmux, so an
  existing tmux habit is left alone.
- **Your environment comes along.** The agent sees the variables of the shell you launched it
  from, even when the tmux server was started days earlier with different ones.
- **It never blocks a launch.** With no tmux installed, or a tmux that can't start a session, you
  get one line on stderr and the agent runs unprotected, as before.
- **Any other agent, by hand:** `~/.scrubjay/scrubjay/bin/sj-keep.sh -- pi`.

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
- **a click on the left** opens a menu of those sessions; choosing one switches to its tmux pane
  (one in a Neovim can't be switched to and is shown greyed out). "All tmux sessions" is tmux's own
  picker. The click needs `set -g mouse on`.

It is black and dim, and nothing on it stays put: the text drifts a cell every two minutes and its
grey breathes slowly, so an OLED screen doesn't burn it in. `SCRUBJAY_STATUS_DRIFT=off` keeps it
still; `SCRUBJAY_STATUS_MAX` (default 3) is how many related sessions it names.

`bin/onboard.sh` offers to add it; by hand, one line in `~/.tmux.conf`:

```sh
source-file "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/../tmux/scrubjay.conf"
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
