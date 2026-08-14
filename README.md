# disk_diag.sh

A read-only disk usage diagnostic for Ubuntu machines.

It answers the question **"what is eating my disk?"** — on the host and inside
Docker containers — without changing a single byte.

---

## Safety first

The script **never writes anything**. No temp files, no logs, no cleanup, no
`docker prune`. Every command it runs is read-only:

| Command | What it reads |
|---|---|
| `df` | free space and inode counts |
| `du` | directory sizes |
| `find` | file sizes |
| `lsof` | open file handles |
| `docker ps` / `images` / `inspect` / `system df` | container metadata |

There is deliberately **no `docker exec`**. Container contents are read from the
host side, so nothing is started or run inside your containers.

---

## Install

```bash
chmod +x disk_diag.sh
```

No dependencies to install. Everything it uses ships with Ubuntu, except
`lsof`, which is optional — that one section is skipped if it's missing.

---

## Usage

```bash
sudo ./disk_diag.sh [PATH] [options]
```

Run it with `sudo`. Without root, protected folders and Docker are silently
skipped, and you get an incomplete picture.

### Options

| Option | Default | What it does |
|---|---|---|
| `-i, --iterate N` | 3 | At each level, follow only the N largest folders |
| `-d, --depth N` | 4 | How many levels deep to drill |
| `-f, --files N` | 3 | Biggest files to show per folder |
| `-t, --top N` | 40 | Rows in the flat lists (containers, images, volumes) |
| `--all-files` | off | Also hunt the biggest files disk-wide (slow) |
| `-h, --help` | — | Show help |

`PATH` defaults to `/`. Options can go before or after the path.

### Examples

```bash
sudo ./disk_diag.sh                    # whole machine, default settings
sudo ./disk_diag.sh /var -i 5          # scan /var, follow 5 folders per level
sudo ./disk_diag.sh / -i 2 -d 6        # narrow but deep
sudo ./disk_diag.sh /home --all-files  # include the full file hunt
sudo ./disk_diag.sh /var > report.txt  # save the output
```

---

## What the output shows

| Section | What it tells you |
|---|---|
| 1. Filesystem space | Which disk is actually full |
| 2. Inode usage | Whether millions of tiny files are the problem |
| 3. Space hogs | Drill-down tree of the biggest folders and files |
| 4. Biggest single files | Only with `--all-files` |
| 5. Deleted-but-open files | Space held hostage by running programs |
| 6. Docker totals | Overall image / container / volume / cache usage |
| 7. Containers by size | Writable layer and virtual size per container |
| 8. Images by size | Largest images |
| 9. Volumes by size | Largest named volumes |
| 10. Inside containers | Drill-down tree per running container, plus log size |

### Reading section 3

Indentation shows nesting. Sizes are on the left, largest first:

```
     3.8M  /srv
     3.7M    /srv/app
     2.9M      /srv/app/cache
     2.9M        /srv/app/cache/blob.bin
   884.0K      /srv/app/logs
```

Read it top to bottom and follow the indentation — that's the trail to the
space hog. Folder sizes include everything inside them, so a parent is always
at least as big as its children.

---

## Speed and system impact

CPU and memory stay low. The cost is **disk reading**.

The one unavoidable expense is a single full `du` pass over the path you give
it. This isn't something `-i` can shrink: to know a folder's size, `du` has to
read everything inside it. The `-i` and `-d` options control how much is
**printed**, not how much is read — they make the output readable, not the scan
faster.

To actually make it faster, give it a smaller path:

```bash
sudo ./disk_diag.sh /var    # instead of /
```

On a busy production machine, run it politely so real work stays fast:

```bash
sudo nice -n 19 ionice -c3 ./disk_diag.sh
```

`ionice -c3` means "only touch the disk when nothing else needs it."

Rough timings for section 3: seconds on a small VM, a few minutes on a large or
slow disk. Adding `--all-files` roughly doubles it, which is why it's off by
default. `docker ps -s` (section 7) is also slow when you have many containers.

---

## Common findings, and what to do next

The script only diagnoses — **you** decide what to remove. Frequent culprits:

- **`/var/lib/docker`** — old images and build cache. Review with
  `docker system df -v` before pruning anything.
- **Container log files** (shown in section 10) — a container logging in a loop
  can fill a disk. The fix is a log rotation limit in your Docker config.
- **`/var/log`** — check that `logrotate` is actually running.
- **Deleted-but-open files** (section 5) — the space returns when the listed
  process restarts. Deleting the file again won't help.
- **Full inodes with free space** (section 2) — usually a folder holding
  millions of small cache or session files.

---

## Limitations

- Docker section assumes the `overlay2` storage driver, the Ubuntu default.
  Other drivers still show totals, but the per-container tree is skipped.
- Only **running** containers are inspected in section 10.
- `-x` keeps the scan on one filesystem, so mounted drives are not followed.
  Scan them separately by passing their mount point as `PATH`.
- Sizes are disk usage, not apparent size, so sparse files and compressed
  filesystems can look smaller than expected.
- Podman and containerd are not supported.
