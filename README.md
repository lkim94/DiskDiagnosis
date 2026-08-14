# disk_diag.sh

A read-only disk usage diagnostic for Ubuntu machines.

It answers **"which files are eating my disk?"** — on the host and inside
running Docker containers — without changing a single byte.

The output is a plain list. Size on the left, full path on the right, biggest
first. No folder tree, no noise.

```
========== Biggest 8 files under / ==========
    441.8M  /opt/pw-browsers/chromium-1194/chrome-linux/chrome
    291.6M  /opt/pw-browsers/chromium_headless_shell-1194/.../headless_shell
    241.1M  /home/claude/.cache/puppeteer/chrome/.../chrome
    136.9M  /usr/lib/x86_64-linux-gnu/libLLVM.so.20.1
    134.2M  /usr/lib/jvm/java-21-openjdk-amd64/lib/modules
  (8 files listed, from 506 folders visited)
```

---

## How it finds them

It doesn't list every file on the disk. It follows the space:

1. Read every file size once, and add each one up the folder chain, so every
   folder has a total.
2. Start at the top. Rank the folders by size, and step into the `-i` largest.
3. Record the files sitting in each folder it steps into.
4. Repeat until `-d` levels deep, or until it runs out of folders.
5. Print the `-n` largest files it recorded.

Folder sizes are only used to steer the walk — they are never printed.

**The trade-off:** a big file inside a folder that lost the `-i` cut will not
appear. Raise `-i` to widen the search. The closing line tells you how many
folders were visited, so you can tell how wide the net was.

---

## Safety first

The script **never writes anything**. No temp files, no logs, no cleanup, no
`docker prune`. Every command it runs is read-only:

| Command | What it reads |
|---|---|
| `df` | free space and inode counts |
| `find` | file sizes |
| `du` | container log file size |
| `docker ps` / `images` / `inspect` / `system df` | container metadata |

Two details worth knowing:

- There is deliberately **no `docker exec`**. Container files are read from the
  host side, so nothing is started or run inside your containers.
- The top-N pick happens inside `awk`, not `sort`. On a disk with millions of
  files, `sort` would spill to temp files — which would be a write. Instead only
  the N biggest files are ever held in memory.

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
| `-i, --iterate N` | 3 | At each level, follow only the N largest folders |
| `-d, --depth N` | no limit | Stop drilling after N levels |
| `-n, --top N` | 40 | How many of the largest files to print |
| `-c, --container N` | 10 | Largest files to print per running container |
| `-q, --quiet` | off | Only the file lists — skip `df` and Docker summaries |
| `-h, --help` | — | Show help |

`PATH` defaults to `/`. Options can go before or after the path.

### Examples

```bash
sudo ./disk_diag.sh                  # whole machine, 40 files
sudo ./disk_diag.sh /var -n 20       # only look under /var
sudo ./disk_diag.sh -i 6             # widen the search
sudo ./disk_diag.sh -i 2 -d 5        # narrow and shallow, fastest to read
sudo ./disk_diag.sh -n 15 -q         # short and bare
sudo ./disk_diag.sh > report.txt     # save the output
```

`-n` sets how long the list is. `-i` and `-d` set how wide and deep the search
was that produced it.

---

## What the output shows

| Section | What it tells you |
|---|---|
| Filesystem space | Which disk is actually full |
| Inode usage | Whether millions of tiny files are the problem |
| Biggest N files | The main answer |
| Docker totals | Overall image / container / volume / cache usage |
| Containers by size | Writable layer and virtual size per container |
| Biggest N files per container | Same search inside each running container, plus its log file |

With `-q`, only the file lists are printed.

---

## Speed and system impact

CPU stays low. Memory is bounded by `-n` and `-d`, not by disk size. The cost is
**disk reading**: one pass over the path you give it.

`-i`, `-d` and `-n` shape the search, not the initial read. Folder sizes can't be
known without reading everything inside them first. To make the scan itself
faster, give it a smaller path:

```bash
sudo ./disk_diag.sh /var    # instead of /
```

On a busy production machine, run it politely so real work stays fast:

```bash
sudo nice -n 19 ionice -c3 ./disk_diag.sh
```

`ionice -c3` means "only touch the disk when nothing else needs it."

Rough timing: under ten seconds on a small VM, a few minutes on a large or slow
disk. `docker ps -s` is also slow with many containers — `-q` skips it.

With no `-d`, a running total is tracked for every folder on the scanned path,
so memory grows with the number of folders. Setting `-d` bounds it.

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
- A big file in a folder that lost the `-i` cut is not listed. Raise `-i`.
- Space held by deleted-but-still-open files is not shown. If `df` says full but
  the list doesn't explain it, check `sudo lsof -nP | grep deleted`.
- Docker section assumes the `overlay2` storage driver, the Ubuntu default.
- Only **running** containers are inspected.
- `-xdev` keeps the scan on one filesystem, so mounted drives are not followed.
  Scan them separately by passing their mount point as `PATH`.
- Sizes are apparent file sizes, so sparse files can look bigger than the space
  they really use.
- Podman and containerd are not supported.
