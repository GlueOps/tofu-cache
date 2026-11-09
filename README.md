# tofu-cache

Pull-through caches that keep `tofu init` working when GitHub is slow, rate-limiting
or down. Two images, released together under one version:

| Image | Caches | Served at |
| --- | --- | --- |
| `ghcr.io/glueops/tofu-cache-providers` | providers from `registry.opentofu.org` and `registry.terraform.io`: the registry API and the release files it points at (GitHub releases, `releases.hashicorp.com`) | `/repository/tofu/` |
| `ghcr.io/glueops/tofu-cache-git` | modules: anonymous clones of public `github.com` repos (registry modules resolve to these too) | `/repository/git/` |

They run in the GlueOps mirror stack behind Caddy (TLS, credential stripping), so
the public URLs are `https://repo.gpkg.io/repository/tofu/…` and
`https://repo.gpkg.io/repository/git/…`. No `.tf` file, `source =` line or lock file
changes to use them.

## Using it

### CI

The [OpenTofu CD action](https://github.com/GlueOps/github-actions-opentofu-continuous-delivery)
configures both caches when `TOFU_MIRROR_URL` is set (opt-in; unset means no change).

### Laptops

Add to `~/.tofurc` (or `~/.terraformrc`):

```hcl
host "registry.opentofu.org" {
  services = {
    "providers.v1" = "https://repo.gpkg.io/repository/tofu/registry.opentofu.org/v1/providers/"
    "modules.v1"   = "https://registry.opentofu.org/v1/modules/"
  }
}
host "registry.terraform.io" {
  services = {
    "providers.v1" = "https://repo.gpkg.io/repository/tofu/registry.terraform.io/v1/providers/"
    "modules.v1"   = "https://registry.terraform.io/v1/modules/"
  }
}
```

`modules.v1` must be listed: a `host` block replaces service discovery for that
registry entirely. For modules, rewrite GitHub URLs for tofu's git only, not your
everyday `git push`:

```bash
tofu() {
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0='url.https://repo.gpkg.io/repository/git/github.com/.insteadOf' \
  GIT_CONFIG_VALUE_0='https://github.com/' \
  command tofu "$@"
}
```

Through the cache, `init` still prints `Installed hashicorp/aws v… (signed, key ID …)`.
To bypass both for one run: comment out the `host` blocks and use `command tofu`.

### What is not cached

- **Private repositories.** The caches are public and anonymous: no credential is
  ever sent upstream. A private HTTPS module source through the git cache fails with
  `repository not found or not public`. Opt that repo out of the mirror.
- Module registry lookups (`modules.v1`) go straight to the registry; only the git
  clone they lead to is cached.
- Providers whose download URL is on a host other than GitHub releases or
  `releases.hashicorp.com` download directly (works, uncached).
- Git LFS: module repos that need LFS objects fail through the git cache.

## Why `host` blocks, not `network_mirror`

OpenTofu and Terraform document `provider_installation { network_mirror { … } }` for
mirrors, and we tested it. We use a `host` block instead because **the provider
network mirror protocol has no support for provider signatures**: its responses carry
only archive URLs and hashes, with nowhere to put `SHA256SUMS`, its signature or the
signing keys. Through a network mirror tofu can only report `(verified checksum)`
against hashes the mirror hands it; it never checks the provider author's GPG
signature. A `host` block keeps the normal registry protocol, so every install is
verified exactly as a direct one (`signed, key ID …`).

Two smaller reasons: through a network mirror, `init` without a lock file records
hashes for the local platform only, so a lock file made on a Mac fails on Linux CI;
and the mirror side needs a translator from the registry API to the mirror format.

`host` blocks are not on the current CLI configuration doc pages but work in every
version we tested: OpenTofu 1.8.11, 1.9.4, 1.10.10, 1.11.14, 1.12.12, 1.13.9,
1.13.0-rc1 and `main` (1.14.0-dev), and Terraform 1.14.9 through 1.17.1 and
1.17.0-rc2 (2026-11-09). If a release ever drops them, opting out restores direct
downloads.

## How each cache behaves

### Providers

| Request | Cached for | When upstream fails |
| --- | --- | --- |
| `…/v1/providers/<ns>/<type>/versions` | 2 minutes (new releases appear within 2m) | last copy served |
| `…/<version>/download/<os>/<arch>` (rewritten to point at the file routes below) | 1 day | last copy served |
| release zips, `SHA256SUMS`, `.sig` | until unused for 60 days | last copy served |

Release files have their own 10 GB zone; over that, the least recently used go first.
GitHub's redirect to its CDN is followed by the cache, never by the client; each hop
must be a known GitHub asset host. Only those two registries and only provider files
are served: release files named `terraform-provider-*` (how every registry download
JSON names them) on GitHub and releases.hashicorp.com, so the mirror can't be used to serve arbitrary release assets.

If a maintainer ever replaces a release file after publishing it, tofu reports a
checksum mismatch; purge that entry (see Operating).

### Modules (git)

| Situation | Result |
| --- | --- |
| first request for a repo | short reachability probe (10s), then a bare clone (heads and tags, max 5 min); clients asking meanwhile wait for it |
| cached, refreshed less than 60s ago | served from the cache |
| older | fetched from GitHub first (max 10s, default branch followed), then served |
| refresh fails for any reason but 401 (down, timeout, 5xx, rate limit) | last copy served; next attempt after 60s |
| GitHub answers 401 (private or deleted) | cached copy deleted; client gets 404 `repository not found or not public` |
| never cached and GitHub unreachable | 502 `upstream unavailable, no cached copy`; the same answer, without retrying, for 60s |
| free disk below the floor | no new clones: 503 `cache disk full` (cached repos still served) |
| clone takes longer than 5 minutes | abandoned, nothing kept; 504 `clone took longer than 300s` |

So during an outage a moving ref like `?ref=main` serves whatever it was at the last
successful refresh; tags and SHAs are unaffected. Only `git-upload-pack` (clone and
fetch) is served, never push. Each repo is bounded by time, not size: 5 minutes to
clone, 10 seconds to refresh. The disk is bounded in total by a sweep every 10 minutes:
a repo unused for 60 days is removed, and while the cache is over 10 GB or the disk is
under the free floor the least recently used go first. The sweep also runs
`git gc --auto` on each mirror. Owner and repo names are case-insensitive, as on
GitHub: `ACME/Mod` and `acme/mod.git` are one cache entry.

Settings (environment variables on the git container):

| Variable | Default |
| --- | --- |
| `GIT_CACHE_MAX_TOTAL_MB` | `10240` |
| `GIT_CACHE_CLONE_SECONDS` (time limit for a first clone; above ~330 also raise nginx's `fastcgi_read_timeout` and Caddy's `response_header_timeout`) | `300` |
| `GIT_CACHE_MIN_FREE_MB` (free-disk floor: no new clones below it, and the sweep evicts to restore it) | `2048` |
| `GIT_CACHE_EVICT_DAYS` | `60` |
| `GIT_CACHE_REFRESH_SECONDS` | `60` |
| `GIT_CACHE_UPSTREAM` (tests only) | `https://github.com` |

## Operating

Both images run as uid 101 and support a read-only root filesystem, which then needs
a tmpfs at `/tmp`. `/cache` must be a writable volume owned by 101; the git image
refuses to start otherwise. Configuration is baked into the images; the git
container also reads the environment variables above. Each exposes `GET /healthz` on
:8080 and stops cleanly on SIGTERM.

- Logs: `docker logs` shows every request; the provider log has the cache status
  (`HIT`, `MISS`, `STALE`, …) and responses carry `X-Cache-Status`. git lines read
  `git-cache: repo=<owner>/<repo> event=<hit|clone|refresh|stale|head-moved>`;
  failures are `event=<probe-failed|clone-failed|refresh-failed> rc=… err="…"`, every
  error reply is `status=<code> msg="…"`, and each sweep ends with
  `git-cache: event=sweep mirrors=… used_mb=… free_mb=… evicted=…` (plus
  `event=evict reason=<unused|size>` per removed repo).
- Purge one git repo: delete `/cache/github.com/<owner>/<repo>.git`.
- Purge a provider file: delete the `/cache/dl` entry (`grep -rl '<url path>' /cache/dl`),
  or the whole `/cache/dl` directory.

## Development

Everything runs in Docker:

```bash
bash test/e2e/run.sh              # builds both images, runs the full suite, cleans up
E2E_SLOW=1 bash test/e2e/run.sh   # also waits out the 2m API TTL to test STALE (nightly CI)
```

The suite puts clients on a network that reaches only Caddy, so any download that
skipped the cache would fail. Providers come from the real registries; git modules
come from a fake GitHub (`test/fake-github`) so outages, private repos, moving refs
and clone time limits are deterministic. Phases: cold install, warm install (all hits,
plus the oldest supported tofu), outage with both caches restarted offline (including a
burst of concurrent requests), private and turned-private repos, moving refs, case
folding and default-branch renames, clone time limit, disk floor and eviction, refused
requests, and container lifecycle. Per-run output lands in `test/e2e/out/`.

Releases: Conventional Commits on `main` drive release-please; merging its release
PR tags `vX.Y.Z` (the first is v1.0.0), which publishes both images. The workflow summary prints the
`tag@digest` pins for the mirror-stack installer. New GHCR packages start private;
both must be public for anonymous pulls.
