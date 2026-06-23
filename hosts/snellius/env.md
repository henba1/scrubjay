# Host: snellius

Snellius HPC cluster (SURF). Stable host name `snellius` — note `hostname -s` returns
transient login-node names (`int6`, `int5`, …), so the host identity is pinned via
`~/.config/dotclaude/host` (written by `bin/claude-register-host.sh`).

## System
- OS: Linux (RHEL 9 / `5.14.x` el9 kernel)
- Filesystem: home on `gpfs` — `/gpfs/home2/jvrijn`
- Code lives under `/gpfs/home2/jvrijn/code/`

## Python / envs
- Primary conda env: `/gpfs/home2/jvrijn/miniforge3/envs/verona_jair`
- Project-specific (foolbox debug): conda env at the same miniforge prefix
- Run in-development VERONA with `PYTHONPATH=/gpfs/home2/jvrijn/code/VERONA`
  (the editable install points at a different checkout, `VERONA_rs_rd`).

## SLURM
- Partition: `staging` (32 CPU cores/node), `--account=ulsei14922`
- ⚠️ The account has **no budget on `rome`** — do not submit there.

## Claude Code notes
- Config applied from this repo via `bin/claude-sync.sh` (host = `snellius`).
- `defaultMode` is `acceptEdits` here (see `hosts/snellius/claude/settings.json`).
