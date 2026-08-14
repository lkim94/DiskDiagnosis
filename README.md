# disk_diag.sh

A read-only disk usage diagnostic for Ubuntu machines.

It answers one question — **which files are eating my disk?** — on the host and
inside running Docker containers, without changing a single byte.

The output is a flat list: size on the left, full path on the right, biggest
first.

```
      4.2G  /var/lib/docker/overlay2/9f3c.../diff/data/dump.sql
      1.8G  /var/log/journal/8a1e.../system.journal
    922.4M  /home/deploy/releases/2024-11-03/assets.tar
```

---

## Safety first

The script **never writes anything**. No temp files, no logs, no cleanup, no
`docker prune`. Every command it runs is read-only:

| Command | What it reads |
|---|---|
| `df` | free space and inode counts |
| `find` | file sizes |
| `docker ps` / `images` / `inspect` / `system df` | container metadata |

Two details worth knowing:

- There is deliberately **no `docker exec`**. Container files are read from the
  host side, so nothing is started or run inside your containers.
- The top-N selection happens inside `awk`, not `sort`. On a disk with millions
  of files, `sort` would spill to temp files on disk — which would be a write.
  Instead only the N biggest files are ever held in memory.

---

## Install

```bash
chmod +x disk_diag.sh
```

Nothing to install. Everything it uses ships with Ubuntu.

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
| `-n, --top N` | 40 | How many largest files to print |
| `-c, --container N` | 10 | Largest files to print per running container |
| `-q, --quiet` | off | Only the file lists — skip the `df` and Docker summaries |
| `-h, --help` | — | Show help |

`PATH` defaults to `/`. Options can go before or after the path.

### Examples

```bash
sudo ./disk_diag.sh                  # whole machine, 40 files
sudo ./disk_diag.sh -n 15            # just the 15 biggest
sudo ./disk_diag.sh /var -n 20       # only look under /var
sudo ./disk_diag.sh -n 25 -q         # bare list, nothing else
sudo ./disk_diag.sh > report.txt     # save the output
```

---

## What the output shows

| Section | What it tells you |
|---|---|
| Filesystem space | Which disk is actually full |
| Inode usage | Whether millions of tiny files are the problem |
| Top N largest files | The main answer |
| Docker totals | Overall image / container / volume / cache usage |
| Containers by size | Writable layer and virtual size per container |
| Top N files per container | Biggest files each running container has written, plus its log file |

With `-q`, only the file lists are printed.

---

## Speed and system impact

CPU and memory stay low — memory is bounded by N, not by disk size. The cost is
**disk reading**: one pass over the path you give it, reading file sizes.

The `-n` option controls how much is **printed**, not how much is read. To make
the scan itself faster, give it a smaller path:

```bash
sudo ./disk_diag.sh /var    # instead of /
```

On a busy production machine, run it politely so real work stays fast:

```bash
sudo nice -n 19 ionice -c3 ./disk_diag.sh
```

`ionice -c3` means "only touch the disk when nothing else needs it."

Rough timing: seconds on a small VM, a few minutes on a large or slow disk.
`docker ps -s` is also slow when you have many containers — `-q` skips it.

---

## Common findings, and what to do next

The script only diagnoses — **you** decide what to remove. Frequent culprits:

- **Container log files** — a container logging in a loop can fill a disk. The
  fix is a log rotation limit in your Docker config, not deleting the file.
- **Files under `/var/lib/docker`** — old image layers and build cache. Review
  with `docker system df -v` before pruning anything.
- **`/var/log`** — check that `logrotate` is actually running.
- **Old release or backup archives** in a deploy folder.
- **Full inodes with free space** — millions of small files. The file list won't
  show this one; check the inode section instead.

---

## Limitations

- **Files only.** It won't tell you that a folder holds a million small files —
  that shows up as full inodes, not as a big file.
- Space held by deleted-but-still-open files is not shown. If `df` says full but
  the file list doesn't explain it, check `sudo lsof -nP | grep deleted`.
- Docker section assumes the `overlay2` storage driver, the Ubuntu default.
- Only **running** containers are inspected.
- `-xdev` keeps the scan on one filesystem, so mounted drives are not followed.
  Scan them separately by passing their mount point as `PATH`.
- Sizes are apparent file sizes, so sparse files can look bigger than the space
  they really use.
- Podman and containerd are not supported.
