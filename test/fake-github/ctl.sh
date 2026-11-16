#!/bin/sh
# Test controls, run with `docker exec -u nginx`:
#   ctl advance <owner>/<repo>   new commit on main; prints its sha
#   ctl hide <owner>/<repo>      repo now answers 401, as if made private
#   ctl rename-default <owner>/<repo> <branch>   rename the default branch
set -eu
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com HOME=/tmp
case $1 in
  advance)
    w=$(mktemp -d)
    git clone -q "/repos/$2.git" "$w"
    date +%s%N > "$w/stamp"
    git -C "$w" add -A && git -C "$w" commit -qm "advance"
    git -C "$w" push -q origin main
    git -C "$w" rev-parse HEAD
    rm -rf "$w" ;;
  hide)
    mv "/repos/$2.git" "/repos/$2.hidden" ;;
  rename-default)
    git -C "/repos/$2.git" branch -m main "$3"
    git -C "/repos/$2.git" symbolic-ref HEAD "refs/heads/$3" ;;
  *) echo "usage: ctl advance|hide <owner>/<repo>" >&2; exit 2 ;;
esac
