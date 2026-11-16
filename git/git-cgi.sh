#!/bin/sh
# CGI run by fcgiwrap for /repository/git/github.com/<owner>/<repo>/(info/refs|git-upload-pack).
# Keeps one bare clone per public GitHub repo and serves it with `git http-backend`.
# Anonymous only: no credential is ever sent upstream and no 401 is ever returned.
set -u
. /tmp/git-cache.env
export PATH=/usr/bin:/usr/sbin:/bin:/sbin   # GNU timeout: busybox's does not kill git-remote-https
export HOME=/cache LC_ALL=C GIT_TERMINAL_PROMPT=0 GIT_ASKPASS='' SSH_ASKPASS='' \
       GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

log() { printf 'git-cache: repo=%s %s\n' "${owner:-?}/${repo:-?}" "$*" >&2; }

reply() {
  log "status=$1 msg=\"$2\""
  printf 'Status: %s\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\n\r\n%s\n' "$1" "$2"
  exit 0
}

# ---- parse and validate the path (nginx already restricted it to this shape) ----
p=${PATH_INFO#/github.com/}
owner=${p%%/*}; rest=${p#*/}
repo=${rest%%/*}; svc=${rest#*/}
repo=${repo%.git}
# GitHub names are case-insensitive; one cache entry per repo.
owner=$(printf '%s' "$owner" | tr 'A-Z' 'a-z')
repo=$(printf '%s' "$repo" | tr 'A-Z' 'a-z')
for part in "$owner" "$repo"; do
  case $part in ''|.*|-*|*..*|*[!a-z0-9._-]*) reply 404 "invalid repository path" ;; esac
done
case "${REQUEST_METHOD:-}:$svc" in
  GET:info/refs)
    [ "${QUERY_STRING:-}" = "service=git-upload-pack" ] || reply 403 "only git-upload-pack is served" ;;
  POST:git-upload-pack) ;;
  *) reply 405 "only git fetch/clone is served" ;;
esac
case ${GIT_PROTOCOL:-} in ''|version=[0-9]) ;; *) unset GIT_PROTOCOL ;; esac

root=/cache
dir=$root/github.com/$owner
M=$dir/$repo.git
L=$dir/$repo.git.lock          # beside the mirror, so deleting a mirror never deletes a held lock
D=$dir/$repo.git.down          # last failed first-clone attempt
url=$GIT_CACHE_UPSTREAM/$owner/$repo.git
scheme=${GIT_CACHE_UPSTREAM%%://*}

# git against upstream: bounded time, no credentials, one protocol.
up() {
  t=$1; shift
  timeout -k 5 "$t" git -c credential.helper= -c core.askPass= \
    -c protocol.allow=never -c "protocol.$scheme.allow=always" \
    -c fetch.recurseSubmodules=false "$@"
}
mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
age() { echo $(( $(date +%s) - $(mtime "$1") )); }
upfail() { log "event=$1 rc=$rc err=\"$(printf '%s' "$err" | tr '\n' ' ')\""; }
# GitHub answers 401 for private and missing repos alike; with prompts off git says this.
# Removes the given paths (and the owner directory, if now empty) before replying 404.
gone() {
  printf '%s' "$err" | grep -q 'could not read Username' || return 0
  [ $# -eq 0 ] || rm -rf "$@"
  rmdir "$dir" 2>/dev/null
  reply 404 "repository not found or not public"
}
down() {
  touch "$D"
  reply 502 "upstream unavailable, no cached copy"
}

cold_clone() {
  free_kb=$(df -Pk "$root" | awk 'NR==2 {print $4}')
  [ "$free_kb" -ge $((GIT_CACHE_MIN_FREE_MB * 1024)) ] || reply 503 "cache disk full"
  # A short probe first: git has no connect timeout, and a clone against an
  # unreachable upstream otherwise hangs for minutes before failing.
  rc=0; err=$(up 10 ls-remote "$url" HEAD 2>&1 >/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    gone "$L" "$D"
    upfail probe-failed
    down
  fi
  tmp=$M.tmp.$$
  # Time bounds what one repo can cost; the total-size roll-off bounds the disk.
  rc=0; err=$(up "$GIT_CACHE_CLONE_SECONDS" clone --bare --quiet "$url" "$tmp" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -rf "$tmp"
    gone "$L" "$D"
    upfail clone-failed
    case $rc in 124|137) reply 504 "clone took longer than ${GIT_CACHE_CLONE_SECONDS}s" ;; esac
    down
  fi
  # gc runs from the eviction job under the lock, never inside a request's timeout.
  git -C "$tmp" config gc.auto 0
  git -C "$tmp" config http.getanyfile false
  touch "$tmp/last-fetch"
  rm -rf "$M" "$D"   # a half-deleted mirror would otherwise swallow the mv
  mv "$tmp" "$M"
  event=clone
}

refresh() {
  # Stamped before the attempt, so a failing upstream is retried at most once per window.
  touch "$M/last-fetch"
  rc=0
  err=$(up 10 -C "$M" fetch --quiet --prune "$url" \
          '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    gone "$M" "$L" "$D"
    event=stale
    upfail refresh-failed
    return 0
  fi
  # Follow a default-branch change (master -> main): `?ref`-less sources clone HEAD,
  # and --prune has just deleted the branch an old HEAD pointed at.
  head=$(up 10 ls-remote --symref "$url" HEAD 2>/dev/null | sed -n 's|^ref: \(refs/heads/[^[:space:]]*\)[[:space:]]*HEAD$|\1|p')
  if [ -n "$head" ] && [ "$head" != "$(git -C "$M" symbolic-ref HEAD 2>/dev/null)" ] &&
     git -C "$M" show-ref --verify --quiet "$head"; then
    git -C "$M" symbolic-ref HEAD "$head"
    log "event=head-moved head=$head"
  fi
  event=refresh
}

mkdir -p "$dir"
event=hit
if [ "$svc" = info/refs ]; then
  if [ ! -f "$M/HEAD" ]; then
    # A first clone that just failed is not retried by every waiter in turn.
    [ "$(age "$D")" -lt "$GIT_CACHE_REFRESH_SECONDS" ] && reply 502 "upstream unavailable, no cached copy"
    exec 9>"$L"
    flock -w 330 9 || reply 503 "busy, retry"
    if [ ! -f "$M/HEAD" ]; then
      [ "$(age "$D")" -lt "$GIT_CACHE_REFRESH_SECONDS" ] && reply 502 "upstream unavailable, no cached copy"
      cold_clone
    fi
  elif [ "$(age "$M/last-fetch")" -ge "$GIT_CACHE_REFRESH_SECONDS" ]; then
    exec 9>"$L"
    # Someone else refreshing: serve what is there rather than queue behind them.
    if flock -n 9; then refresh; else event=stale; fi
  fi
  touch "$M/last-access"
  exec 9>&-
  log "event=$event"
else
  [ -f "$M/HEAD" ] || reply 404 "repository not cached; retry the clone"
fi

export GIT_PROJECT_ROOT=$root GIT_HTTP_EXPORT_ALL=1 PATH_INFO="/github.com/$owner/$repo.git/$svc"
exec git http-backend
