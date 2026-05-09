# Release Process (Lightweight, Reproducible)

This project uses a lightweight release flow suited for personal infrastructure:

- Cheap CI checks on GitHub Actions (no full Yocto build on hosted runners)
- Deterministic local build from a tagged commit
- Published release evidence (manifest + checksums)

## 1. Release Branch and Scope

1. Create a release branch from `main`:
   `git checkout -b release-vX.Y.Z`
2. Freeze scope to release-only changes:
   - version bump
   - changelog
   - docs/runbook updates
   - critical release fixes only

## 2. Version Bump

Update:

- `meta-iot-gateway/conf/distro/include/iotgw-common.inc`
  - `IOTGW_VERSION_MAJOR`
  - `IOTGW_VERSION_MINOR`
  - `IOTGW_VERSION_PATCH`
- `CHANGELOG.md`
  - cut `## [X.Y.Z] - YYYY-MM-DD` from `Unreleased`
  - update bottom compare links

## 3. Tag First, Then Build

Build only from an annotated tag:

```bash
git checkout main
git merge --ff-only release-vX.Y.Z
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin main vX.Y.Z
```

## 4. Deterministic Local Build (Heavy Step)

Use release wrapper from clean tree:

```bash
scripts/release-build.sh \
  --version X.Y.Z \
  --build-id YYYYMMDDHHMM \
  --image dev \
  --bundle full-fit
```

For production profile:

```bash
scripts/release-build.sh \
  --version X.Y.Z \
  --build-id YYYYMMDDHHMM \
  --image prod \
  --bundle full
```

## 5. Release Evidence Bundle

Generate manifest and checksums:

```bash
scripts/release-manifest.sh \
  --tag vX.Y.Z \
  --version X.Y.Z \
  --build-id YYYYMMDDHHMM
```

Output directory:

- `release/vX.Y.Z/manifest.txt`
- `release/vX.Y.Z/checksums.sha256`

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

Attach to GitHub release:

- `CHANGELOG.md` notes
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
- `CHANGELOG.md` has `[Unreleased]:` link and at least one
  `## [X.Y.Z] - YYYY-MM-DD` section
- `IOTGW_VERSION_{MAJOR,MINOR,PATCH}` variable form is present in
  `iotgw-common.inc`

Triggers: PRs targeting `main`, pushes to `main` and `release-*`,
manual `workflow_dispatch`.

It does **not** attempt full Yocto builds, recipe parsing, or `kas dump`
on free-tier runners.
