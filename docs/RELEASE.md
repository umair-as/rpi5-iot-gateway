# Release Process (Lightweight, Reproducible)

This project uses a lightweight release flow suited for personal infrastructure:

- Cheap CI checks on GitHub Actions (no full Yocto build on hosted runners)
- Deterministic local build from a tagged commit
- Generated GitHub Release notes plus published release evidence
  (manifest + checksums)

## 1. Release Branch and Scope

1. Create a release branch from `main`:
   `git checkout -b release-vX.Y.Z`
2. Freeze scope to release-only changes:
   - version bump
   - release notes/doc updates
   - docs/runbook updates
   - critical release fixes only

## 2. Version Bump

Update:

- `meta-iot-gateway/conf/distro/include/iotgw-common.inc`
  - `IOTGW_VERSION_MAJOR`
  - `IOTGW_VERSION_MINOR`
  - `IOTGW_VERSION_PATCH`

`CHANGELOG.md` is historical/manual release evidence. It may carry a curated
summary when useful, but GitHub Release notes are generated from git history and
are not committed back to the branch by CI.

## 3. Tag First, Then Build

Build only from an annotated tag:

```bash
git checkout main
git merge --ff-only release-vX.Y.Z
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin main vX.Y.Z
```

Pushing the tag triggers `.github/workflows/release-notes.yml`, which generates
the GitHub Release body from `cliff.toml`. The parser is intentionally adapted
to this repository's existing commit history; it does not impose a new
commit-message format.

Optional local preview before tagging, if `git-cliff` is installed:

```bash
GITHUB_REPO=umair-as/rpi5-iot-gateway git-cliff --config cliff.toml --unreleased --strip header --offline
```

## 4. Deterministic Local Build (Heavy Step)

Use release wrapper from clean tree:

```bash
scripts/release/release-build.sh \
  --version X.Y.Z \
  --build-id YYYYMMDDHHMM \
  --image dev \
  --bundle full-fit
```

For production profile:

```bash
scripts/release/release-build.sh \
  --version X.Y.Z \
  --build-id YYYYMMDDHHMM \
  --image prod \
  --bundle full
```

## 5. Release Evidence Bundle

Generate manifest and checksums:

```bash
scripts/release/release-manifest.sh \
  --tag vX.Y.Z \
  --version X.Y.Z \
  --build-id YYYYMMDDHHMM
```

Output directory:

- `release/vX.Y.Z/manifest.txt` (includes `deploy_root` field)
- `release/vX.Y.Z/checksums.sha256`

The deploy directory is auto-detected (`build/tmp/deploy` or
`build/tmp/deploy`). Override for non-standard layouts:

```bash
IOTGW_DEPLOY_ROOT=/path/to/deploy scripts/release/release-manifest.sh ...
```

## 6. Device Verification (Minimum)

On target after install/reboot:

```bash
cat /etc/os-release
cat /etc/buildinfo
rauc status
```

Confirm:

- `DISTRO_VERSION=igw.X.Y.Z`
- expected release track (`dev` or `prod`)
- expected active slot and boot status

## 7. Publish Release

The tag workflow creates or updates the GitHub Release notes automatically.
Attach release evidence to the GitHub Release:

- `release/vX.Y.Z/manifest.txt`
- `release/vX.Y.Z/checksums.sha256`
- serial/log evidence links (if available)

## 8. What GitHub Actions Does

The workflow intentionally runs only fast hygiene checks (no Yocto build):

- release docs/scripts presence
- `bash -n` syntax check on release scripts
- `shellcheck -S warning` on all tracked `scripts/*.sh`
- `yamllint` on tracked `kas/*.yml` and `.github/workflows/*.yml`
  (rules in `.yamllint`)
- `cliff.toml` is present for generated release notes
- historical `CHANGELOG.md` has `[Unreleased]:` link and at least one
  `## [X.Y.Z] - YYYY-MM-DD` section
- `IOTGW_VERSION_{MAJOR,MINOR,PATCH}` variable form is present in
  `iotgw-common.inc`

Triggers: PRs targeting `main`, pushes to `main` and `release-*`,
manual `workflow_dispatch`.

It does **not** attempt full Yocto builds, recipe parsing, or `kas dump`
on free-tier runners.
