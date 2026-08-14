#!/usr/bin/env bash
# disk_diag.sh - READ-ONLY disk usage diagnostic for Ubuntu
#
# Walks the biggest folders, and prints ONLY a list of the biggest files.
# Only reads (df, find, docker inspect/ps/images).
# Never creates, edits, deletes, or prunes anything. No temp files.
#
# How it works:
#   at each level it ranks the folders by size, follows the -i largest,
#   collects the files it passes, and repeats until -d levels (or the bottom).
#   Then it prints the -n largest files it saw. Folders are never printed.
#
# Usage:
#   sudo ./disk_diag.sh [PATH] [options]
#
#   -i, --iterate N    at each level, follow only the N largest folders (default 3)
#   -d, --depth N      stop drilling after N levels (default: no limit)
#   -n, --top N        how many of the largest files to print (default 40)
#   -c, --container N  largest files to print per running container (default 10)
#   -q, --quiet        only the file lists, skip df and docker summaries
#   -h, --help         show this help
#
# Examples:
#   sudo ./disk_diag.sh /var -i 5 -n 20
#   sudo ./disk_diag.sh / -i 2 -d 6

set -uo pipefail

SCAN_ROOT="/"
BRANCHES=3
MAXDEPTH=0
TOP=40
CTOP=10
QUIET=0

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--iterate)   BRANCHES="${2:?}"; shift 2 ;;
    -d|--depth)     MAXDEPTH="${2:?}"; shift 2 ;;
    -n|--top)       TOP="${2:?}";      shift 2 ;;
    -c|--container) CTOP="${2:?}";     shift 2 ;;
    -q|--quiet)     QUIET=1;           shift   ;;
    -h|--help)      usage; exit 0 ;;
    -*)             echo "unknown option: $1" >&2; exit 1 ;;
    *)              SCAN_ROOT="$1";    shift   ;;
  esac
done

section() { printf '\n\n========== %s ==========\n' "$1"; }
note()    { printf '  (%s)\n' "$1"; }

[ "$(id -u)" -ne 0 ] && printf '!! Not root: some folders and Docker may be unreadable. Try: sudo %s\n' "$0"

# ------------------------------------------------------------------- scan()
# $1 = path, $2 = how many files to print.
#
# Pass 1: one `find` streams every file size, and folder totals are summed
#         up the parent chain. Nothing is printed.
# Pass 2: walk down from the root following the -i biggest folders, and
#         read the files sitting directly in each folder visited.
#
# Only the N biggest files are ever held in memory, so `sort` never runs on
# the full list and never spills to a temp file.
scan() {
  local root="${1%/}"; [ -z "$root" ] && root="/"
  local want="$2"
  [ -d "$root" ] || { note "not a directory: $1"; return; }

  find "$root" -xdev -type f -printf '%s\t%p\n' 2>/dev/null \
    | awk -F'\t' -v root="$root" -v nbr="$BRANCHES" -v maxd="$MAXDEPTH" -v top="$want" '
      function human(b,   u, i) {
        split("B K M G T P", u, " ")
        i = 1
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        return sprintf("%.1f%s", b, u[i])
      }
      # quote a path for safe use inside a shell command
      function shq(s,   q, out, i, c) {
        q = sprintf("%c", 39); out = q
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          out = out ((c == q) ? q "\\" q q : c)
        }
        return out q
      }
      function bubble(i,   ts, tp) {
        while (i > 1 && fsz[i-1] < fsz[i]) {
          ts = fsz[i-1]; fsz[i-1] = fsz[i]; fsz[i] = ts
          tp = fpa[i-1]; fpa[i-1] = fpa[i]; fpa[i] = tp
          i--
        }
      }
      function push(size, path) {
        if (nf < top)             { nf++; fsz[nf] = size; fpa[nf] = path; bubble(nf) }
        else if (size > fsz[top]) { fsz[top] = size; fpa[top] = path;     bubble(top) }
      }
      # read the files sitting directly in this folder
      function collect(d,   cmd, line, f) {
        cmd = "find " shq(d) " -maxdepth 1 -type f -printf " shq("%s\t%p\n") " 2>/dev/null"
        while ((cmd | getline line) > 0) { split(line, f, "\t"); push(f[1] + 0, f[2]) }
        close(cmd)
        visited++
      }
      function walk(d, depth,   n, arr, i, k, best, bi, used) {
        collect(d)
        if (maxd > 0 && depth >= maxd) return
        n = split(kids[d], arr, "\n")
        for (k = 0; k < nbr; k++) {
          bi = 0; best = -1
          for (i = 1; i <= n; i++) {
            if (arr[i] == "" || (i in used)) continue
            if (dsz[arr[i]] > best) { best = dsz[arr[i]]; bi = i }
          }
          if (bi == 0) return
          used[bi] = 1
          walk(arr[bi], depth + 1)
        }
      }
      BEGIN { base = (root == "/") ? "" : root }
      {
        # pass 1: add this file size to every parent folder
        size = $1 + 0
        rel = substr($2, length(base) + 1)
        n = split(rel, comp, "/")
        dsz[root] += size
        cur = base; prev = root
        for (k = 2; k <= n - 1 && (maxd < 1 || k - 1 <= maxd); k++) {
          cur = cur "/" comp[k]
          dsz[cur] += size
          if (!((prev SUBSEP cur) in seen)) {
            seen[prev SUBSEP cur] = 1
            kids[prev] = kids[prev] cur "\n"
          }
          prev = cur
        }
      }
      END {
        if (!(root in dsz)) { print "  (no readable files here)"; exit }
        walk(root, 0)                      # pass 2
        if (nf == 0) { print "  (no files found in the folders visited)"; exit }
        for (j = 1; j <= nf; j++) printf "%10s  %s\n", human(fsz[j]), fpa[j]
        printf "  (%d files listed, from %d folders visited)\n", nf, visited
      }'
}

# --------------------------------------------------------------- filesystems
if [ "$QUIET" -eq 0 ]; then
  section "Filesystem space (which disk is full?)"
  df -hT -x tmpfs -x devtmpfs -x squashfs 2>/dev/null

  section "Inode usage (a disk can be 'full' with tiny files)"
  df -ih -x tmpfs -x devtmpfs -x squashfs 2>/dev/null
fi

# ----------------------------------------------------------------- host scan
section "Biggest $TOP files under $SCAN_ROOT"
scan "$SCAN_ROOT" "$TOP"

# -------------------------------------------------------------------- docker
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then

  if [ "$QUIET" -eq 0 ]; then
    section "Docker totals"
    docker system df

    section "Containers by size (writable layer + virtual)"
    printf '%-13s %-13s %-26s %s\n' "WRITABLE" "VIRTUAL" "NAME" "IMAGE"
    docker ps -as --format '{{.Size}}|{{.Names}}|{{.Image}}' 2>/dev/null \
      | awk -F'|' '{ split($1, s, /\(virtual /); w = s[1]; v = s[2]
                     gsub(/\)/, "", v); gsub(/ +$/, "", w)
                     printf "%-13s %-13s %-26s %s\n", w, v, $2, $3 }' \
      | sort -rh
  fi

  section "Biggest $CTOP files inside each running container"
  note "read from the host writable layer - no docker exec, nothing runs inside"
  for cid in $(docker ps -q 2>/dev/null); do
    cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | tr -d '/')
    upper=$(docker inspect -f '{{ index .GraphDriver.Data "UpperDir" }}' "$cid" 2>/dev/null)
    printf '\n--- container: %s (%s) ---\n' "$cname" "$cid"
    if [ -n "$upper" ] && [ -d "$upper" ]; then
      scan "$upper" "$CTOP"
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
  [ "$QUIET" -eq 0 ] && { section "Docker"; note "docker not installed or not reachable - skipped"; }
fi

printf '\n\nDone. Nothing was modified.\n'
