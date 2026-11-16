#!/bin/sh
# Answers like github.com: anonymous access to a private or missing repo is a 401.
set -u
p=${PATH_INFO#/}
owner=${p%%/*}; rest=${p#*/}; repo=${rest%%/*}
case $repo in *.git) ;; *) repo=$repo.git ;; esac
if [ "$owner" = private ] || [ ! -d "/repos/$owner/$repo" ]; then
  printf 'Status: 401\r\nWWW-Authenticate: Basic realm="GitHub"\r\nContent-Type: text/plain\r\n\r\nunauthorized\n'
  exit 0
fi
export GIT_PROJECT_ROOT=/repos GIT_HTTP_EXPORT_ALL=1 PATH_INFO="/$owner/$repo/${rest#*/}"
exec git http-backend
