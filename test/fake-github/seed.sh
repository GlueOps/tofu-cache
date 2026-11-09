#!/bin/sh
# Builds the fake GitHub's repositories under /repos/<owner>/<repo>.git.
set -eu
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

module() {
  owner=$1 repo=$2
  w=$(mktemp -d)
  git -C "$w" init -q -b main
  cat > "$w/main.tf" <<'EOF'
output "greeting" {
  value = "hello"
}
EOF
  git -C "$w" add -A && git -C "$w" commit -qm "initial"
  git -C "$w" tag v1.0.0
  mkdir -p "/repos/$owner"
  git clone -q --bare "$w" "/repos/$owner/$repo.git"
  git -C "/repos/$owner/$repo.git" config http.receivepack false
  rm -rf "$w"
}

module acme mod
module acme vanish
module acme other
module acme rename
module acme free
module private secret

# Served slowly (see nginx.conf), so cloning it outlasts the test's clone time limit.
w=$(mktemp -d)
git -C "$w" init -q -b main
head -c 3000000 /dev/urandom > "$w/blob"
git -C "$w" add -A && git -C "$w" commit -qm "big"
git clone -q --bare "$w" /repos/acme/big.git
rm -rf "$w"
