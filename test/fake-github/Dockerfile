# Test-only stand-in for github.com's git smart HTTP, so outage, private-repo,
# moving-ref and size-cap behaviour are deterministic and never hit rate limits.
FROM nginx:1.31.6-alpine@sha256:d10753d9289b8e3f884386351f73554ce72b631378949deddd75e83ee296c427

# hadolint ignore=DL3018
RUN apk add --no-cache git git-daemon fcgiwrap
COPY nginx.conf /etc/nginx/nginx.conf
COPY --chmod=0755 fake-github.sh /usr/local/bin/fake-github.sh
COPY --chmod=0755 seed.sh /usr/local/bin/seed.sh
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 ctl.sh /usr/local/bin/ctl
# Owned by the fcgiwrap user, or git refuses the repos as "dubious ownership".
RUN /usr/local/bin/seed.sh && chown -R nginx:nginx /repos

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
