# Same nginx the mirror stack already pins; config is baked in, so a new image
# digest is the only way config changes and compose recreates the container.
FROM nginx:1.31.10-alpine@sha256:7fc0fb4af7bf006aeb31aea88069976060f8f0a0a86b667126742cc17f4e31ae

RUN install -d -o 101 -g 101 /cache
COPY nginx.conf /etc/nginx/nginx.conf

USER 101:101
EXPOSE 8080
VOLUME /cache
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["nginx", "-g", "daemon off;"]
