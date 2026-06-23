# Project rule template: VERONA + private debug repo

> Reusable `CLAUDE.local.md` snippet. Copy into a project root as `CLAUDE.local.md`
> and adapt the {{PLACEHOLDERS}} for the current machine/project. Machine-specific
> paths are tokenized so Claude can re-tailor them per host (see hosts/<machine>/env.md).

## Debug & experiment artifacts live in a separate private repo

Do **not** commit debugging/scratch scripts, SLURM job scripts, or experiment run
data to the main repo. Things that belong elsewhere:
`results_*` output dirs, `_dbg_*.py`, `_job_*.sh`, `_slurm_*.out`, ad-hoc probes.

They belong in the personal **private** repo:

- Working dir: `{{DEBUG_REPO_DIR}}`  (e.g. `/gpfs/home2/jvrijn/code/verona-foolbox-debug`)
- GitHub: `{{DEBUG_REPO}}` (private)
- Registered as the git remote **`debug`** (a pointer, not a mirror).

### Workflow
- Put new debug scripts / run data under the debug repo (`scripts/`, `experiments/`,
  `logs/`) and commit/push there.
- Keep the main working tree clean — only commit real package / PR deliverables.
- ⚠️ Do **not** `git push debug <branch>` from the main repo — separate history.

## Cluster / run conventions
- SLURM: partition **`{{SLURM_PARTITION}}`** with `--account={{SLURM_ACCOUNT}}`.
- Python env: `{{CONDA_ENV}}`.
- Run in-dev package with `PYTHONPATH={{REPO_DIR}}` so it imports the working checkout.
