#!/bin/sh
# Run every 10 minutes by the entrypoint. Removes leftover temp clones and mirrors
# unused for GIT_CACHE_EVICT_DAYS, then the least recently used mirrors while the
# cache is over GIT_CACHE_MAX_TOTAL_MB or the disk is under GIT_CACHE_MIN_FREE_MB,
# then gives each remaining mirror a `git gc --auto`. A mirror whose lock is held
# (being cloned or refreshed) is skipped. Ends with one summary line.
set -u
. /tmp/git-cache.env
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
export HOME=/cache GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
root=/cache/github.com
mkdir -p "$root"
evicted=0

# Runs "$@" on a mirror while holding its lock; does nothing if the lock is busy.
locked() {
  m=$1; shift
  (
    exec 9>"$m.lock"
    flock -n 9 || exit 1
    "$@"
  )
}
evict() {
  if locked "$1" rm -rf "$1"; then
    evicted=$((evicted + 1))
    printf 'git-cache: repo=%s event=evict reason=%s\n' "${1#"$root"/}" "$2" >&2
  fi
}
used_kb() { du -sk "$root" | cut -f1; }
free_kb() { df -Pk "$root" | awk 'NR==2 {print $4}'; }
over() { [ "$(used_kb)" -gt $((GIT_CACHE_MAX_TOTAL_MB * 1024)) ] || [ "$(free_kb)" -lt $((GIT_CACHE_MIN_FREE_MB * 1024)) ]; }

find "$root" -mindepth 2 -maxdepth 2 -name '*.git.tmp.*' -mmin +60 -exec rm -rf {} +

# Lists go through a file, not a pipe, so `evicted` is counted in this shell.
find "$root" -mindepth 3 -maxdepth 3 -name last-access -mtime +"$GIT_CACHE_EVICT_DAYS" > /tmp/evict.list
while read -r f; do evict "${f%/last-access}" unused; done < /tmp/evict.list

if over; then
  for d in "$root"/*/*.git; do
    [ -d "$d" ] && printf '%s %s\n' "$(stat -c %Y "$d/last-access" 2>/dev/null || echo 0)" "$d"
  done | sort -n | cut -d' ' -f2 > /tmp/evict.list
  while read -r m; do
    over || break
    evict "$m" size
  done < /tmp/evict.list
fi

# Mirrors keep gc.auto=0 so a request's 10s fetch never starts a repack.
for m in "$root"/*/*.git; do
  [ -f "$m/HEAD" ] && locked "$m" git -C "$m" -c gc.auto=6700 gc --auto --quiet
done

printf 'git-cache: event=sweep mirrors=%s used_mb=%s free_mb=%s evicted=%s\n' \
  "$(find "$root" -mindepth 2 -maxdepth 2 -name '*.git' -type d | wc -l)" \
  "$(( $(used_kb) / 1024 ))" "$(( $(free_kb) / 1024 ))" "$evicted" >&2
