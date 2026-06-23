# Host: {{HOST}}

> Skeleton notes file for a machine. `bin/claude-register-host.sh` prefills the
> detected facts below; fill in the rest by hand. This is human-readable reference
> so you (and Claude) can browse and cross-tailor configs between machines.

## System
- OS: {{OS}}
- Filesystem / home: {{HOME}}
- Code lives under: <e.g. ~/code/>

## Python / envs
- Primary env: <conda/venv path or `system`>
- Notes: <activation quirks, PYTHONPATH needs, …>

## Job scheduler (if any)
- <SLURM/PBS partition + account, or "none">

## Claude Code notes
- `defaultMode`: <default | acceptEdits | plan> (set in `claude/settings.json`)
- Anything machine-specific Claude should know.
