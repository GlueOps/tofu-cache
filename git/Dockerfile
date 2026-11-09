# Same nginx base the mirror stack pins, plus git tooling. git-daemon is the
# package that ships `git http-backend`; flock is util-linux's (busybox's has no -w).
FROM nginx:1.31.6-alpine@sha256:d10753d9289b8e3f884386351f73554ce72b631378949deddd75e83ee296c427

# Unpinned on purpose: Alpine removes superseded versions, so =x.y pins break rebuilds.
# The base digest fixes the Alpine branch; each release build takes its current patches.
# hadolint ignore=DL3018
RUN apk add --no-cache git git-daemon fcgiwrap coreutils flock tini \
 && install -d -o 101 -g 101 /cache
COPY nginx.conf /etc/nginx/nginx.conf
COPY --chmod=0755 git-cgi.sh /usr/local/bin/git-cgi.sh
COPY --chmod=0755 git-cache-evict.sh /usr/local/bin/git-cache-evict
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

# git and the mirrors share one uid, or git refuses them as "dubious ownership".
USER 101:101
ENV HOME=/cache
EXPOSE 8080
VOLUME /cache
# The nginx base stops with SIGQUIT, which the entrypoint shell ignores: every stop
# would wait out the 10s timeout and end in SIGKILL.
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
