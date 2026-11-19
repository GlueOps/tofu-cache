# Same nginx the mirror stack already pins; config is baked in, so a new image
# digest is the only way config changes and compose recreates the container.
FROM nginx:1.31.9-alpine@sha256:fb4658584bd9a916ffb6f6e365f97c25cfdb2923801f551ea08356e695f14ff7

RUN install -d -o 101 -g 101 /cache
COPY nginx.conf /etc/nginx/nginx.conf

USER 101:101
EXPOSE 8080
VOLUME /cache
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["nginx", "-g", "daemon off;"]
