# AGENTS.md

Two container images that cache OpenTofu/Terraform providers and GitHub-hosted
modules for the GlueOps mirror stack (`GlueOps/sonartype-installer` deploys them
behind Caddy). See README.md for behaviour and usage.

## Repo map

```
providers/        nginx config + Dockerfile: registry API + release-file cache
git/              nginx + fcgiwrap + git-cgi.sh (bare mirrors, git http-backend),
                  git-cache-evict.sh (10-minute sweep), entrypoint.sh (tini, polls both)
test/e2e/         run.sh (the suite), compose.yaml, Caddy with the installer's routes,
                  a tofu client image and fixtures
test/fake-github/ git smart-HTTP stand-in for github.com (401s, ctl advance|hide)
.github/workflows ci (lint incl. actionlint, e2e; nightly), release-please,
                  container_image (publish every push by SHA; v* tags = releases), cleanup_images (nightly GHCR prune)
```

## Build and test (Docker only)

The same commands CI runs (`.github/workflows/ci.yml`):

```bash
bash test/e2e/run.sh
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d \
  --severity=warning git/*.sh test/fake-github/*.sh test/e2e/run.sh test/e2e/client/client.sh
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 -shellcheck=
for f in providers/Dockerfile git/Dockerfile test/fake-github/Dockerfile test/e2e/client/Dockerfile test/e2e/caddy/Dockerfile; do
  docker run --rm -i hadolint/hadolint:v2.14.0@sha256:27086352fd5e1907ea2b934eb1023f217c5ae087992eb59fde121dce9c9ff21e < "$f"
done
```

Locally the Docker daemon may be on the host (devcontainer): keep the checkout under
`/workspaces/glueops`. The suite itself uses no bind mounts.

## Rules

- Conventional Commits; release-please cuts one version for both images. Base-image
  and dependency bumps are `fix:` (a `chore:` never ships).
- Pin every image by tag@digest and every action by SHA. No `latest` tag.
- Any behaviour change gets a check in `test/e2e/run.sh`.
- Never return 401 or `WWW-Authenticate` from the git cache: git would then offer
  the client's credentials. Never send credentials upstream from either image.

## Landmines

- **nginx: a `proxy_set_header` inside a location drops every one set at http
  level.** All of them live at http level in `providers/nginx.conf`. One in a location
  silently lets `Accept-Encoding` through, the registry answers gzip, `sub_filter`
  does nothing, and tofu downloads straight from GitHub while still succeeding.
- **`sub_filter` only on the download-JSON location.** It must include
  `application/octet-stream` (registry.opentofu.org's JSON type), so on a file route
  it would rewrite bytes inside provider zips.
- **The redirect allow-list is an `if` in `@dl_follow`, not a `map`**: a map is
  evaluated once per request, so hop 2 would reuse hop 1's verdict.
- **busybox vs GNU in the git image.** busybox `timeout` does not kill
  git-remote-https (use GNU, from coreutils); busybox `flock` has no `-w` (use
  util-linux `flock`); busybox `wait -n` never returns for a signalled child (the
  entrypoint polls).
- **`git-http-backend` comes from the `git-daemon` package**, not `git`.
- **git refuses repos owned by another uid** ("dubious ownership"): nginx, fcgiwrap,
  git and `/cache` all run as 101.
- **fcgiwrap does not pass its environment to the CGI**: settings reach
  git-cgi.sh through `/tmp/git-cache.env`, written by the entrypoint.
- **A private GitHub repo is detected by stderr text** (`could not read Username`,
  with `GIT_TERMINAL_PROMPT=0`, `LC_ALL=C`); git exits 128 for every failure.
- **Never start background work from the CGI.** A child inherits fcgiwrap's stderr
  pipe (the response doesn't finish until it exits) and fd 9 (the repo lock stays
  held). Eviction runs only from the entrypoint's sweep.
- **The nginx base image sets `STOPSIGNAL SIGQUIT`**, which the busybox entrypoint
  ignores; the git image overrides it to SIGTERM or every stop ends in SIGKILL.
- **`clone --bare` fixes HEAD at clone time.** Refresh re-reads upstream's default
  branch (`ls-remote --symref`); `--prune` would otherwise leave HEAD on a deleted
  branch and `?ref`-less modules install empty.
- **Mirrors carry `gc.auto=0`**: a fetch's auto-gc inside the 10s timeout gets killed
  on big repos. The sweep runs `gc --auto` under the lock instead.
- **bash: a word `case` inside `$( … )` breaks parsing**, even as an argument (`$(client case …)`).
- **release-please must use the GitHub App token.** A tag pushed with GITHUB_TOKEN
  doesn't trigger other workflows, so a release would publish no images.
- **A cold clone needs the `ls-remote` probe first**: git has no connect timeout,
  and a clone against an unreachable host hangs ~300s.
- **The OpenTofu image cannot be a base image** (`ONBUILD RUN exit 1`) and BuildKit
  does not expand variables in `COPY --from`: the test client copies `tofu` from a
  named build context set in compose.yaml.

## Decisions

Settled; don't re-raise in review.

- `host` blocks, not `network_mirror`: the network mirror protocol has no support for
  provider signatures (also: single-platform lock hashes, a translator to own).
  Verified across OpenTofu 1.8–1.13 + main and Terraform 1.14–1.17 (README).
- Public-only and anonymous: no auth on the caches, no credentials or GitHub token
  upstream. Private HTTPS module sources erroring through the cache is accepted.
- HTTPS only; no SSH.
- Paths, not hostnames: `/repository/tofu/` and `/repository/git/` on the existing
  mirror hosts.
- `modules.v1` stays upstream; only the git clones are cached.
- Git: refresh at most every 60s; serve the last copy on any failure except 401;
  401 deletes. No GitHub token, even for rate limits.
- Limits: per repo by time only (5 min clone, 10s refresh), no per-repo size cap.
  Disk: git 10 GB total, provider files 10 GB; least recently used rolls off;
  anything unused for 60 days is evicted.
- Download JSON cached 1 day, version lists 2 minutes.
- One repo, two images, one shared version: a release restarts both containers
  (~1s, caches survive). Accepted.
- Deferred: per-client rate limiting, cache-hit columns in mirror-stats.
- Not in the e2e suite: the `@dl_follow` 502 for a redirect to an unlisted host (real
  GitHub can't be made to send one); verified by hand 2026-11-09. Git LFS is unsupported.
