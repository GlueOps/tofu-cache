#!/usr/bin/env bash
# End-to-end test of both images behind Caddy, with clients that can reach only
# the mirror. Providers come from the real registries; modules from a fake GitHub.
# Needs only Docker. Exit status is the number of failed checks (0 = pass).
set -euo pipefail
cd "$(dirname "$0")"
export COMPOSE_PROJECT_NAME="tce2e$RANDOM"
OUT=out/$COMPOSE_PROJECT_NAME
mkdir -p "$OUT"

fails=0
log()   { printf '%s %s\n' "$(date -u +%T)" "$*"; }
pass()  { log "PASS $1"; }
fail()  { log "FAIL $1"; fails=$((fails + 1)); }
check() { local d=$1; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
dc()    { docker compose --progress quiet "$@"; }
cid()   { dc ps -aq "$1"; }
mark()  { sleep 1; date -u +%Y-%m-%dT%H:%M:%SZ; }
logs_since() { docker logs --since "$2" "$(cid "$1")" 2>&1; }
# Runs a client command, keeping its output in $OUT/<name>.log.
client() { local name=$1 svc=$2; shift 2; dc run --rm -T "$svc" "$@" >"$OUT/$name.log" 2>&1 || true; cat "$OUT/$name.log"; }
has()   { grep -qE "$1" <<<"$2"; }
lacks() { ! grep -qE "$1" <<<"$2"; }
signed3() { [ "$(grep -cE 'Installed .* \((signed|self-signed)' <<<"$1")" -eq 3 ]; }
# Every provider block in the lock file has hashes for more platforms than this one.
all_platforms() { awk '/^provider/ {p=$2} /"zh:/ {n[p]++} END {if (length(n) != 3) exit 1; for (k in n) if (n[k] < 5) exit 1}' <<<"$1"; }
healthy() {
  local s
  for _ in $(seq 1 30); do
    s=$(docker inspect -f '{{.State.Health.Status}}' "$(cid "$1")")
    [ "$s" = healthy ] && return 0
    sleep 1
  done
  return 1
}
egress() { docker network "$1" "${COMPOSE_PROJECT_NAME}_egress" "$(cid "$2")"; }
fake()   { docker exec -u nginx "$(cid fake-github)" ctl "$@"; }
git_cache() { docker exec "$(cid git)" sh -c "$1"; }
cleanup() { dc --profile client down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "TASK: e2e test of the tofu-cache images (project $COMPOSE_PROJECT_NAME, output in test/e2e/$OUT)"
dc --profile client build -q
dc up -d --wait
for _ in $(seq 1 30); do
  docker exec "$(cid caddy)" test -f /data/caddy/pki/authorities/local/root.crt && break
  sleep 1
done

log "STATUS phase 1/7: cold install through the mirror"
t=$(mark)
out=$(client cold client init main)
check "cold: tofu init succeeds" has 'OpenTofu has been successfully initialized' "$out"
check "cold: all 3 providers install signed" signed3 "$out"
check "cold: lock file has hashes for all platforms" all_platforms "$out"
check "cold: all three git modules installed (tag, branch, default branch)" test "$(grep -cE '^(tagged|branch|default)$' <<<"$out")" -eq 3
p=$(logs_since providers "$t")
check "cold: GitHub release files fetched through the cache" has '^200 MISS .*"/repository/tofu/dl/github/' "$p"
check "cold: releases.hashicorp.com files fetched through the cache" has '^200 MISS .*"/repository/tofu/dl/hashicorp/' "$p"
check "cold: module repo cloned into the git cache" has 'acme/mod event=clone' "$(logs_since git "$t")"

log "STATUS phase 2/7: warm install is served from cache"
t=$(mark)
out=$(client warm client init main)
check "warm: tofu init succeeds" has 'OpenTofu has been successfully initialized' "$out"
p=$(logs_since providers "$t")
check "warm: every release file is a cache HIT" lacks '^[0-9]+ (MISS|EXPIRED|-) .*"/repository/tofu/dl/' "$p"
check "warm: no new clone" lacks 'event=clone' "$(logs_since git "$t")"
out=$(client oldest client-oldest init main)
check "warm: oldest supported tofu (1.8.11) installs signed through the mirror" signed3 "$out"

log "STATUS phase 3/7: upstream outage, after restarting both caches"
egress disconnect providers
egress disconnect git
dc stop fake-github >/dev/null 2>&1
dc restart providers git >/dev/null 2>&1
check "outage: providers cache starts with no internet" healthy providers
check "outage: git cache starts with no internet" healthy git
# Without a tmpfs /tmp the previous run's fcgiwrap socket survives a restart.
plain=$(docker run -d --network none "${COMPOSE_PROJECT_NAME}-git")
sleep 2; docker restart "$plain" >/dev/null; sleep 3
check "restart: git cache recovers without a tmpfs /tmp" \
  docker exec "$plain" wget -q -O /dev/null http://127.0.0.1:8080/healthz
docker rm -f "$plain" >/dev/null
sleep 4   # past the git refresh window, so a refresh is attempted and fails
t=$(mark)
out=$(client outage client init main)
check "outage: tofu init still succeeds (providers from cache, modules stale)" has 'OpenTofu has been successfully initialized' "$out"
check "outage: module served stale" has 'acme/mod event=stale' "$(logs_since git "$t")"
s=$(date +%s)
out=$(client never-cached client git ls-remote https://github.com/acme/other.git)
check "outage: never-cached repo fails with a clear message" has 'upstream unavailable, no cached copy' "$out"
check "outage: ...and fails fast (<40s)" test $(( $(date +%s) - s )) -lt 40
# Many clients at once on a repo that can't be cloned: one probe, the rest answered
# from the failure stamp instead of each waiting out its own probe.
s=$(date +%s)
for i in 1 2 3 4 5 6; do client "burst-$i" client git ls-remote https://github.com/acme/other.git >/dev/null & done
wait
check "outage: 6 concurrent requests for an uncloneable repo all fail" \
  test "$(cat "$OUT"/burst-*.log | grep -c 'upstream unavailable, no cached copy')" -eq 6
check "outage: ...within one probe's time (<25s), not one after another" test $(( $(date +%s) - s )) -lt 25
if [ "${E2E_SLOW:-}" = 1 ]; then
  sleep 125   # past the 2m version-list TTL
  t=$(mark)
  out=$(client outage-stale client init main)
  check "outage (slow): tofu init succeeds after the API cache expired" has 'OpenTofu has been successfully initialized' "$out"
  check "outage (slow): expired version lists served STALE" has '^200 STALE .*/versions"' "$(logs_since providers "$t")"
fi

log "STATUS phase 4/7: private repos, moving refs, repos that turn private"
egress connect providers
egress connect git
dc start fake-github >/dev/null 2>&1
reachable=no
for _ in $(seq 1 30); do
  if git_cache 'wget -q -O /dev/null "http://fake-github:8080/acme/mod.git/info/refs?service=git-upload-pack"'; then
    reachable=yes; break
  fi
  sleep 1
done
check "upstream back: git cache reaches the fake GitHub again" test "$reachable" = yes
out=$(client private client git ls-remote https://github.com/private/secret.git)
check "private: repo answers 'not found or not public'" has 'repository not found or not public' "$out"
h=$(client private-headers client headers '/repository/git/github.com/private/secret.git/info/refs?service=git-upload-pack')
check "private: HTTP 404, never 401" has 'HTTP/[0-9.]+ 404' "$h"
check "private: no WWW-Authenticate through Caddy" lacks '[Ww][Ww][Ww]-[Aa]uthenticate' "$h"
h=$(git_cache "wget -S -O /dev/null 'http://127.0.0.1:8080/repository/git/github.com/private/secret.git/info/refs?service=git-upload-pack' 2>&1 || true")
check "private: the git cache itself sends no WWW-Authenticate (clients never offer credentials)" lacks '[Ww][Ww][Ww]-[Aa]uthenticate' "$h"
check "private: no lock file or directory left behind" git_cache 'test ! -e /cache/github.com/private'
before=$(client ref-before client git ls-remote https://github.com/acme/mod.git refs/heads/main | cut -f1)
new=$(fake advance acme/mod)
sleep 4
after=$(client ref-after client git ls-remote https://github.com/acme/mod.git refs/heads/main | cut -f1)
check "moving ref: main moves to the new commit after the refresh window" test "$after" = "$new" -a "$before" != "$new"
t=$(mark)
mixed=$(client mixed-case client git ls-remote https://github.com/ACME/Mod refs/heads/main | cut -f1)
check "case: ACME/Mod (no .git) is the same cached repo" test "$mixed" = "$new"
check "case: ...without a second clone" lacks 'event=clone' "$(logs_since git "$t")"
client rename-cache client git ls-remote https://github.com/acme/rename.git >/dev/null
fake rename-default acme/rename trunk
sleep 4
out=$(client rename client git ls-remote --symref https://github.com/acme/rename.git HEAD)
check "default branch: renamed upstream (main -> trunk), the cache follows" has '^ref: refs/heads/trunk' "$out"
client vanish-cache client git ls-remote https://github.com/acme/vanish.git >/dev/null
fake hide acme/vanish
sleep 4
out=$(client vanish client git ls-remote https://github.com/acme/vanish.git)
check "turned private: answers 'not found or not public'" has 'repository not found or not public' "$out"
check "turned private: cached copy deleted" git_cache 'test ! -e /cache/github.com/acme/vanish.git'

log "STATUS phase 5/7: clone time limit, disk floor and eviction"
out=$(client big client git ls-remote https://github.com/acme/big.git)
check "time limit: clone over the limit refused" has 'clone took longer than 8s' "$out"
check "time limit: nothing left on disk" git_cache 'test -z "$(ls -d /cache/github.com/acme/big.git /cache/github.com/acme/big.git.tmp.* 2>/dev/null)"'
git_cache 'sed -i "s/^GIT_CACHE_MIN_FREE_MB=.*/GIT_CACHE_MIN_FREE_MB=999999999/" /tmp/git-cache.env'
out=$(client diskfull client git ls-remote https://github.com/acme/free.git)
check "disk floor: no new clone below the free-disk floor" has 'cache disk full' "$out"
sweep=$(git_cache 'git-cache-evict' 2>&1)
check "disk floor: the sweep evicts to make room" has 'event=evict reason=size' "$sweep"
check "sweep: logs a summary line" has 'event=sweep mirrors=[0-9]+ used_mb=[0-9]+ free_mb=[0-9]+ evicted=[0-9]+' "$sweep"
git_cache 'sed -i "s/^GIT_CACHE_MIN_FREE_MB=.*/GIT_CACHE_MIN_FREE_MB=2048/" /tmp/git-cache.env'
client refill-mod client git ls-remote https://github.com/acme/mod.git >/dev/null
git_cache 'touch -d "@$(( $(date +%s) - 61 * 86400 ))" /cache/github.com/acme/mod.git/last-access && git-cache-evict'
check "eviction: repo unused for 61 days removed" git_cache 'test ! -e /cache/github.com/acme/mod.git'
client lru-a client git ls-remote https://github.com/acme/other.git >/dev/null
client lru-b client git ls-remote https://github.com/acme/mod.git >/dev/null
# The eviction log goes to this exec's stderr, not the container log.
order=$(git_cache 'touch -d "@$(( $(date +%s) - 3600 ))" /cache/github.com/acme/other.git/last-access
           sed -i "s/^GIT_CACHE_MAX_TOTAL_MB=.*/GIT_CACHE_MAX_TOTAL_MB=0/" /tmp/git-cache.env && git-cache-evict' 2>&1 |
        grep -oE 'repo=acme/[a-z]+\.git event=evict reason=size' | cut -d' ' -f1 | tr '\n' ' ' || true)
check "size roll-off: least recently used goes first" test "$order" = "repo=acme/other.git repo=acme/mod.git "

log "STATUS phase 6/7: refused requests"
st() { client "status-$1" client status "$2"; }
check "refused: git push (receive-pack)" test "$(st push '/repository/git/github.com/acme/mod.git/info/refs?service=git-receive-pack')" = 403
check "refused: path traversal" test "$(st dotdot '/repository/git/github.com/acme/..%2f..%2fetc/info/refs?service=git-upload-pack')" = 404
check "refused: non-release github.com path" test "$(st archive '/repository/tofu/dl/github/acme/mod/archive/main.zip')" = 404
check "refused: non-provider release asset" test "$(st asset '/repository/tofu/dl/github/acme/mod/releases/download/v1.0.0/tool_linux_amd64.zip')" = 404
check "refused: non-provider file in a provider repo" test "$(st notes '/repository/tofu/dl/github/opentofu/terraform-provider-random/releases/download/v3.9.1/notes.txt')" = 404
check "refused: non-provider file on releases.hashicorp.com" test "$(st hc '/repository/tofu/dl/hashicorp/terraform-provider-null/3.2.4/vault_1.0_linux_amd64.zip')" = 404
check "refused: registry not on the list" test "$(st reg '/repository/tofu/evil.example.com/v1/providers/a/b/versions')" = 404
check "refused: module registry API (modules.v1 stays upstream)" test "$(st modules '/repository/tofu/registry.opentofu.org/v1/modules/a/b/c/versions')" = 404

log "STATUS phase 7/7: container lifecycle"
s=$(date +%s)
docker stop "$(cid git)" >/dev/null
check "lifecycle: git cache stops cleanly on docker stop (<5s)" test $(( $(date +%s) - s )) -lt 5
check "lifecycle: ...with exit code 0, not SIGKILL" test "$(docker inspect -f '{{.State.ExitCode}}' "$(cid git)")" = 0
out=$(timeout 30 docker run --rm --read-only --tmpfs /tmp --tmpfs /cache:mode=0755 "${COMPOSE_PROJECT_NAME}-git" 2>&1 || true)
check "lifecycle: git cache refuses to start on an unwritable /cache" has '/cache is not writable' "$out"

log "RESULT: $fails failed check(s)"
exit "$fails"
