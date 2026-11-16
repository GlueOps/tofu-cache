#!/bin/sh
# Configures tofu and git the way the CD action does, against the test mirror.
#   tofu-client init <fixture>      tofu init on /fixtures/<fixture>
#   tofu-client git <args>          git with the module rewrite applied
#   tofu-client status <path>       HTTP status of https://repo.example.test<path>
#   tofu-client headers <path>      response headers of the same
set -eu
M=https://repo.example.test

cat /etc/ssl/certs/ca-certificates.crt /caddy/caddy/pki/authorities/local/root.crt > /tmp/ca.crt
export SSL_CERT_FILE=/tmp/ca.crt GIT_SSL_CAINFO=/tmp/ca.crt

for reg in registry.opentofu.org registry.terraform.io; do
  cat <<EOF
host "$reg" {
  services = {
    "providers.v1" = "$M/repository/tofu/$reg/v1/providers/"
    "modules.v1"   = "https://$reg/v1/modules/"
  }
}
EOF
done > "$HOME/.terraformrc"
git config --global url."$M/repository/git/github.com/".insteadOf https://github.com/

cmd=$1; shift
case $cmd in
  init)
    w=$(mktemp -d)
    cp -r "/fixtures/$1/." "$w"
    cd "$w"
    tofu version | head -1
    tofu init -input=false -no-color
    echo "== lock"; cat .terraform.lock.hcl
    echo "== modules"; ls .terraform/modules ;;
  git)
    exec git "$@" ;;
  status)
    wget -q -S -O /dev/null --no-check-certificate "$M$1" 2>&1 | grep -oE 'HTTP/[0-9.]+ [0-9]{3}' | tail -1 | cut -d' ' -f2 ;;
  headers)
    wget -q -S -O /dev/null --no-check-certificate "$M$1" 2>&1 || true ;;
esac
