#!/usr/bin/env bash
# disk_diag.sh - READ-ONLY disk usage diagnostic for Ubuntu
#
# Lists the largest FILES on the host and inside running containers.
# Only reads (df, find, docker inspect/ps/images).
# Never creates, edits, deletes, or prunes anything. No temp files.
#
# Usage:
#   sudo ./disk_diag.sh [PATH] [options]
#
#   -n, --top N        how many largest files to print (default 40)
#   -c, --container N  largest files to print per running container (default 10)
#   -q, --quiet        only the file lists, skip df / docker summaries
#   -h, --help         show this help
#
# Examples:
#   sudo ./disk_diag.sh -n 20
#   sudo ./disk_diag.sh /var -n 15 -c 5

set -uo pipefail

SCAN_ROOT="/"
TOP=40
CTOP=10
QUIET=0

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--top)       TOP="${2:?}";  shift 2 ;;
    -c|--container) CTOP="${2:?}"; shift 2 ;;
    -q|--quiet)     QUIET=1;       shift   ;;
    -h|--help)      usage; exit 0 ;;
    -*)             echo "unknown option: $1" >&2; exit 1 ;;
    *)              SCAN_ROOT="$1"; shift  ;;
  esac
done

section() { [ "$QUIET" -eq 1 ] || printf '\n\n========== %s ==========\n' "$1"; }
head2()   { printf '\n\n========== %s ==========\n' "$1"; }
note()    { printf '  (%s)\n' "$1"; }

[ "$(id -u)" -ne 0 ] && printf '!! Not root: some folders and Docker may be unreadable. Try: sudo %s\n' "$0"

# -------------------------------------------------------------- top_files()
# $1 = path, $2 = how many rows.
# find streams every file; awk keeps only the N biggest in memory.
# No `sort` on the full list, so nothing ever spills to a temp file.
top_files() {
  local root="${1%/}"; [ -z "$root" ] && root="/"
  local want="$2"
  [ -d "$root" ] || { note "not a directory: $1"; return; }

  find "$root" -xdev -type f -printf '%s\t%p\n' 2>/dev/null \
    | awk -F'\t' -v top="$want" '
      function human(b,   u, i) {
        split("B K M G T P", u, " ")
        i = 1
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        return sprintf("%.1f%s", b, u[i])
      }
      function bubble(i,   ts, tp) {
        while (i > 1 && sz[i-1] < sz[i]) {
          ts = sz[i-1]; sz[i-1] = sz[i]; sz[i] = ts
          tp = pa[i-1]; pa[i-1] = pa[i]; pa[i] = tp
          i--
        }
      }
      {
        s = $1 + 0
        if (n < top)          { n++; sz[n] = s; pa[n] = $2; bubble(n) }
        else if (s > sz[top]) { sz[top] = s; pa[top] = $2; bubble(top) }
      }
      END {
        if (n == 0) { print "  (no readable files here)"; exit }
        for (i = 1; i <= n; i++) printf "%10s  %s\n", human(sz[i]), pa[i]
      }'
}

# --------------------------------------------------------------- filesystems
section "Filesystem space (which disk is full?)"
[ "$QUIET" -eq 1 ] || df -hT -x tmpfs -x devtmpfs -x squashfs 2>/dev/null

section "Inode usage (a disk can be 'full' with tiny files)"
[ "$QUIET" -eq 1 ] || df -ih -x tmpfs -x devtmpfs -x squashfs 2>/dev/null

# ---------------------------------------------------------------- host files
head2 "Top $TOP largest files under $SCAN_ROOT"
top_files "$SCAN_ROOT" "$TOP"

# -------------------------------------------------------------------- docker
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then

  section "Docker totals"
  [ "$QUIET" -eq 1 ] || docker system df

  section "Containers by size (writable layer + virtual)"
  if [ "$QUIET" -eq 0 ]; then
    printf '%-13s %-13s %-26s %s\n' "WRITABLE" "VIRTUAL" "NAME" "IMAGE"
    docker ps -as --format '{{.Size}}|{{.Names}}|{{.Image}}' 2>/dev/null \
      | awk -F'|' '{ split($1, s, /\(virtual /); w = s[1]; v = s[2]
                     gsub(/\)/, "", v); gsub(/ +$/, "", w)
                     printf "%-13s %-13s %-26s %s\n", w, v, $2, $3 }' \
      | sort -rh
  fi

  head2 "Top $CTOP largest files inside each running container"
  note "read from the host writable layer - no docker exec, nothing runs inside"
  for cid in $(docker ps -q 2>/dev/null); do
    cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | tr -d '/')
    upper=$(docker inspect -f '{{ index .GraphDriver.Data "UpperDir" }}' "$cid" 2>/dev/null)
    printf '\n--- container: %s (%s) ---\n' "$cname" "$cid"
    if [ -n "$upper" ] && [ -d "$upper" ]; then
      top_files "$upper" "$CTOP"
    else
      note "writable layer unreadable (need root, or non-overlay2 storage driver)"
    fi
    lf=$(docker inspect -f '{{.LogPath}}' "$cid" 2>/dev/null)
    if [ -f "$lf" ]; then
      printf '%10s  %s  <- container log\n' \
        "$(du -h "$lf" 2>/dev/null | cut -f1)" "$lf"
    fi
  done
else
  section "Docker"
  [ "$QUIET" -eq 1 ] || note "docker not installed or not reachable - skipped"
fi

printf '\n\nDone. Nothing was modified.\n'
