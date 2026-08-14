#!/usr/bin/env bash
# disk_diag.sh - READ-ONLY disk usage diagnostic for Ubuntu
#
# Only reads (df, du, find, docker inspect/ps/images).
# Never creates, edits, deletes, or prunes anything. No temp files.
#
# Usage:
#   sudo ./disk_diag.sh [PATH] [options]
#
#   -i, --iterate N    at each level, follow only the N largest dirs (default 3)
#   -d, --depth N      how many levels deep to drill (default 4)
#   -f, --files N      biggest files to show per directory (default 3)
#   -t, --top N        rows for flat lists: containers, images, volumes (default 40)
#       --all-files    also hunt the biggest single files disk-wide (SLOW)
#   -h, --help         show this help
#
# Examples:
#   sudo ./disk_diag.sh /var -i 5
#   sudo ./disk_diag.sh / -i 2 -d 6

set -uo pipefail

SCAN_ROOT="/"
BRANCHES=3
MAXDEPTH=4
FILES_PER_DIR=3
TOP=40
ALL_FILES=0

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--iterate)   BRANCHES="${2:?}";      shift 2 ;;
    -d|--depth)     MAXDEPTH="${2:?}";      shift 2 ;;
    -f|--files)     FILES_PER_DIR="${2:?}"; shift 2 ;;
    -t|--top)       TOP="${2:?}";           shift 2 ;;
    --all-files)    ALL_FILES=1;            shift   ;;
    -h|--help)      usage; exit 0 ;;
    -*)             echo "unknown option: $1" >&2; exit 1 ;;
    *)              SCAN_ROOT="$1";         shift   ;;
  esac
done

EXCLUDES=(--exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run
          --exclude=/snap --exclude=/mnt --exclude=/media)

section() { printf '\n\n========== %s ==========\n' "$1"; }
note()    { printf '  (%s)\n' "$1"; }

[ "$(id -u)" -ne 0 ] && printf '!! Not root: some folders and Docker may be unreadable. Try: sudo %s\n' "$0"

# --------------------------------------------------------------- tree_scan()
# One du pass over the path, then walk down following only the
# largest $BRANCHES directories at each level.
tree_scan() {
  local root="${1%/}"; [ -z "$root" ] && root="/"
  [ -d "$root" ] || { note "not a directory: $1"; return; }

  du -x -B1 "${EXCLUDES[@]}" "$root" 2>/dev/null | awk -F'\t' \
    -v root="$root" -v nbr="$BRANCHES" -v maxd="$MAXDEPTH" -v nfil="$FILES_PER_DIR" '
    function dirname(p,   i) {
      if (p == "/") return ""
      i = length(p)
      while (i > 1 && substr(p, i, 1) != "/") i--
      return (i == 1) ? "/" : substr(p, 1, i - 1)
    }
    function human(b,   u, i) {
      split("B K M G T P", u, " ")
      i = 1
      while (b >= 1024 && i < 6) { b /= 1024; i++ }
      return sprintf("%.1f%s", b, u[i])
    }
    function pad(d,   s, i) { s = ""; for (i = 0; i < d; i++) s = s "  "; return s }
    function row(size, depth, path) { printf "%9s  %s%s\n", human(size), pad(depth), path }
    # quote a path for safe use inside a shell command
    function shq(s,   q, out, i, c) {
      q = sprintf("%c", 39); out = q
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        out = out ((c == q) ? q "\\" q q : c)
      }
      return out q
    }
    function showfiles(d, depth,   cmd, line, f) {
      if (nfil < 1) return
      cmd = "find " shq(d) " -maxdepth 1 -type f -printf " shq("%s\t%p\n") \
            " 2>/dev/null | sort -rn | head -n " nfil
      while ((cmd | getline line) > 0) {
        split(line, f, "\t")
        row(f[1], depth + 1, f[2])
      }
      close(cmd)
    }
    function walk(d, depth,   n, arr, i, k, best, bi, used) {
      showfiles(d, depth)
      if (depth >= maxd) return
      n = split(kids[d], arr, "\n")
      for (k = 0; k < nbr; k++) {
        bi = 0; best = -1
        for (i = 1; i <= n; i++) {
          if (arr[i] == "" || (i in used)) continue
          if (sz[arr[i]] > best) { best = sz[arr[i]]; bi = i }
        }
        if (bi == 0) return
        used[bi] = 1
        row(sz[arr[bi]], depth + 1, arr[bi])
        walk(arr[bi], depth + 1)
      }
    }
    { sz[$2] = $1
      if ($2 != root) { p = dirname($2); kids[p] = kids[p] $2 "\n" } }
    END {
      if (!(root in sz)) { print "  (nothing readable here)"; exit }
      row(sz[root], 0, root)
      walk(root, 0)
    }'
}

# ---------------------------------------------------------------- filesystems
section "1. Filesystem space (which disk is full?)"
df -hT -x tmpfs -x devtmpfs -x squashfs 2>/dev/null

section "2. Inode usage (a disk can be 'full' with tiny files)"
df -ih -x tmpfs -x devtmpfs -x squashfs 2>/dev/null

# ----------------------------------------------------------------- host tree
section "3. Space hogs under $SCAN_ROOT"
note "following the $BRANCHES largest dirs per level, $MAXDEPTH levels deep, $FILES_PER_DIR files each"
tree_scan "$SCAN_ROOT"

if [ "$ALL_FILES" -eq 1 ]; then
  section "4. Biggest single files anywhere under $SCAN_ROOT"
  note "full-disk scan - this is the slow one"
  find "$SCAN_ROOT" -xdev -type f -printf '%s\t%p\n' 2>/dev/null \
    | sort -rn | head -n "$TOP" \
    | awk -F'\t' '{ c = "numfmt --to=iec " $1; c | getline h; close(c)
                    printf "%9s  %s\n", h, $2 }'
fi

section "5. Deleted-but-still-open files (space held by running programs)"
note "these free up only when the listed process restarts"
lsof -nP 2>/dev/null | awk '/deleted/ { printf "%9.1fM  pid=%s %s %s\n", $8/1048576, $2, $1, $9 }' \
  | sort -rn | head -n 15 || note "lsof not installed"

# -------------------------------------------------------------------- docker
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then

  section "6. Docker totals"
  docker system df

  section "7. Containers by size (writable layer + virtual)"
  printf '%-13s %-13s %-26s %s\n' "WRITABLE" "VIRTUAL" "NAME" "IMAGE"
  docker ps -as --format '{{.Size}}|{{.Names}}|{{.Image}}' 2>/dev/null \
    | awk -F'|' '{ split($1, s, /\(virtual /); w = s[1]; v = s[2]
                   gsub(/\)/, "", v); gsub(/ +$/, "", w)
                   printf "%-13s %-13s %-26s %s\n", w, v, $2, $3 }' \
    | sort -rh | head -n "$TOP"

  section "8. Images by size"
  docker images --format '{{.Size}}|{{.Repository}}:{{.Tag}}|{{.ID}}' 2>/dev/null \
    | sort -rh | awk -F'|' '{ printf "%9s  %-45s %s\n", $1, $2, $3 }' | head -n "$TOP"

  section "9. Volumes by size"
  for v in $(docker volume ls -q 2>/dev/null); do
    mp=$(docker volume inspect -f '{{.Mountpoint}}' "$v" 2>/dev/null)
    [ -d "$mp" ] && du -sh "$mp" 2>/dev/null | awk -v n="$v" '{ printf "%9s  %s\n", $1, n }'
  done | sort -rh | head -n "$TOP"

  section "10. Space hogs inside each running container"
  note "read from the host writable layer - no docker exec, nothing runs inside"
  for cid in $(docker ps -q 2>/dev/null); do
    cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | tr -d '/')
    upper=$(docker inspect -f '{{ index .GraphDriver.Data "UpperDir" }}' "$cid" 2>/dev/null)
    printf '\n--- container: %s (%s) ---\n' "$cname" "$cid"
    if [ -n "$upper" ] && [ -d "$upper" ]; then
      tree_scan "$upper"
    else
      note "writable layer unreadable (need root, or non-overlay2 storage driver)"
    fi
    lf=$(docker inspect -f '{{.LogPath}}' "$cid" 2>/dev/null)
    printf '    log file: '
    if [ -f "$lf" ]; then du -h "$lf" 2>/dev/null | awk '{ print $1 "  " $2 }'; else echo "n/a"; fi
  done
else
  section "6-10. Docker"
  note "docker not installed or not reachable - skipped"
fi

printf '\n\nDone. Nothing was modified.\n'
