#!/bin/sh
# Runs fcgiwrap and nginx under tini, exits if either dies (the restart policy
# brings the container back), and runs the eviction sweep every 10 minutes.
set -u

# Fail loudly: an unwritable /cache (e.g. a bind mount not owned by uid 101) would
# otherwise look healthy while every request fails.
if ! touch /cache/.write-test 2>/dev/null; then
  echo "git-cache: /cache is not writable by uid $(id -u); chown the volume to 101:101" >&2
  exit 1
fi
rm -f /cache/.write-test

# fcgiwrap does not hand its environment to the CGI, so settings go through a file.
cat > /tmp/git-cache.env <<EOF
GIT_CACHE_UPSTREAM=${GIT_CACHE_UPSTREAM:-https://github.com}
GIT_CACHE_REFRESH_SECONDS=${GIT_CACHE_REFRESH_SECONDS:-60}
GIT_CACHE_CLONE_SECONDS=${GIT_CACHE_CLONE_SECONDS:-300}
GIT_CACHE_MAX_TOTAL_MB=${GIT_CACHE_MAX_TOTAL_MB:-10240}
GIT_CACHE_MIN_FREE_MB=${GIT_CACHE_MIN_FREE_MB:-2048}
GIT_CACHE_EVICT_DAYS=${GIT_CACHE_EVICT_DAYS:-60}
EOF

# A socket left from a previous run (when /tmp is not a tmpfs) makes fcgiwrap fail
# to bind, which would turn every restart into a crash loop.
rm -f /tmp/fcgiwrap.sock
# Waiters for a first clone each hold a worker for up to ~11 minutes.
fcgiwrap -c 64 -s unix:/tmp/fcgiwrap.sock & fpid=$!
nginx -g 'daemon off;' & npid=$!

rc=1
trap 'rc=0; kill -QUIT "$npid" 2>/dev/null' TERM INT
# Polling, not `wait -n`: busybox's never returns when a child dies from a signal.
n=0; epid=
while kill -0 "$npid" 2>/dev/null && kill -0 "$fpid" 2>/dev/null; do
  n=$((n + 1))
  if [ "$n" -ge 600 ]; then
    n=0
    # Skip a sweep while the previous one is still running.
    if [ -z "$epid" ] || ! kill -0 "$epid" 2>/dev/null; then git-cache-evict & epid=$!; fi
  fi
  sleep 1 & wait $!
done
kill -QUIT "$npid" 2>/dev/null
while kill -0 "$npid" 2>/dev/null; do sleep 1 & wait $!; done
kill -TERM "$fpid" 2>/dev/null
wait
exit "$rc"
