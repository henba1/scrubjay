# Archive durability — NAS snapshots, not git history

scrubjay's [author-vs-record split](https://henba1.github.io/scrubjay/concepts/index.md) is the whole design in one sentence: **things you *author*** (config, memory) ride **git**, where history is the point; **records** (transcripts, plans, `readable/`, `history.jsonl`) ride **rsync/copy** to the NAS, where you want cheap append and no version bloat.

That raises a fair question: if the records don't live in git, how do you get them *back* after a fat-fingered `rm` or a corrupted write? The answer is the NAS's own filesystem, not git: **point-in-time snapshots** of `scrubjay-storage`.

Why not just put the archive in git?

Transcripts are large, append-only, and grow without bound. Committing them would balloon the repo, pack poorly, and buy you a history you'll never `git blame` — while snapshots give the same point-in-time recovery for near-free on a copy-on-write filesystem. Git is for the content you *edit*; snapshots are for the records you only ever *append*.

## Setup — run on the NAS, with root

`scrubjay-storage` lives on the box that holds the archive (the `local` backend's mount, or the `rsync-wg` receiver). Snapshotting is configured **there, with root** — so, like the `authorized_keys` line and the other receiver-side steps, it stays yours: onboard never does it. The helper is [`bin/sj-snapshot.sh`](https://github.com/henba1/scrubjay/blob/main/bin/sj-snapshot.sh).

```
# on the NAS, as root — auto-detects zfs or btrfs under the storage path
sudo bin/sj-snapshot.sh --now                 # take one snapshot now, prune to --keep
sudo bin/sj-snapshot.sh --schedule            # install a systemd timer (default: hourly, keep 48)
sudo bin/sj-snapshot.sh --list                # list scrubjay-* snapshots
sudo bin/sj-snapshot.sh --dry-run --now       # print what it would do, touch nothing
```

Flags: `--path <dir>` (defaults to `$SCRUBJAY_LOCAL_CHATS` or `/mnt/nas1/scrubjay-storage`), `--keep N`, `--oncalendar <systemd spec>`.

For the cleanest snapshots, put `scrubjay-storage` on **its own** btrfs subvolume or zfs dataset so it can be snapshotted (and rolled back) independently of everything else on the NAS. If it's on ext4 or any non-CoW filesystem, `sj-snapshot.sh` says so and points you at LVM snapshots or restic instead of failing silently.

## Restore

Restore is destructive and filesystem-specific, so `sj-snapshot.sh --restore <snap>` **prints** the exact commands rather than running them — review, then run them yourself:

- **zfs** — `zfs rollback -r <dataset>@<snap>` (discards everything since), or `zfs clone` the snapshot elsewhere and copy out just what you need.
- **btrfs** — the read-only snapshot is a full tree under `.scrubjay-snapshots/`; `rsync` the files you want back into place.

## Snapshots are not a backup

A snapshot lives on the **same disk** as the archive — it protects against accidental deletion and corruption, not against disk failure. For that, replicate snapshots **off the box**: `zfs send | ssh`, [`btrbk`](https://digint.ch/btrbk/), or `restic` to another machine or object store. scrubjay doesn't automate off-box replication — set it up with whatever you already use for the rest of the NAS.
