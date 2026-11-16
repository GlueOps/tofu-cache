# The OpenTofu image refuses to be a base image (ONBUILD exit 1), so the binary is
# copied out of it. `tofu` is a named build context set in compose.yaml, which
# also picks the version (a FROM stage would run the ONBUILD trigger).
FROM alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f
# hadolint ignore=DL3018
RUN apk add --no-cache git ca-certificates
# hadolint ignore=DL3022
COPY --from=tofu /usr/local/bin/tofu /usr/local/bin/tofu
COPY --chmod=0755 client.sh /usr/local/bin/tofu-client
COPY fixtures /fixtures
ENTRYPOINT ["/usr/local/bin/tofu-client"]
