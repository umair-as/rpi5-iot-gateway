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
the GitHub Release body from `cliff.toml`. The parser reads the Conventional
Commit subjects the `commit-msg` hook enforces (AGENTS.md §Conventions).

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

For production, build the image only, let the operator sign the slot FITs,
then assemble the bundle (the assembly gate refuses unsigned slot FITs; see
[FIT Boot Signing](FIT_BOOT_SIGNING.md)):

```bash
scripts/release/release-build.sh \
  --version X.Y.Z \
  --build-id YYYYMMDDHHMM \
  --image prod \
  --bundle none
make sign-slot-fits-yk SLOT_FITS_IMAGE=iot-gw-image-prod   # operator: YubiKey PIN + touch
make bundle IMAGE=prod
```

Do not start a build in another composition (dev, desktop, even `bitbake -n`)
between the prod image build and `make bundle IMAGE=prod`. Starting one
makes sstate remove the prod deploy outputs, including the slot FITs you just
signed, and the image has to be rebuilt and signed again.

## 5. SBOM / CVE Scan

Not automated by the release scripts; run it by hand.

**Refresh the database pin first.** The scanner databases are pinned by SRCREV
in `meta-iot-gateway/conf/distro/include/iotgw-cve-db.inc`, so a scan reports what was known at the pinned cutoff, not
what is known today. Shipping a count measured against a stale pin is the
failure mode this step exists to prevent — it produces a healthy-looking number
that is silently blind to everything published since. Procedure, cadence and
the traps: `SBOM_CVE.md` §"Refreshing the pin".

**Scan dev; it covers prod when prod is a subset.** Prod installs a subset of
dev's packages. A CVE row's verdict depends only on the package and its
version, so when every prod package is also in dev at the same version, the
dev report contains every row the prod report would, and its counts are an
upper bound for prod. Scan dev:

```bash
make sbom-cve IMAGE=dev
```

Then prove the subset from buildhistory of the two builds being released:

```bash
B=build/buildhistory/images/raspberrypi5/glibc
comm -13 <(sort $B/iot-gw-image-dev/installed-package-names.txt) \
         <(sort $B/iot-gw-image-prod/installed-package-names.txt)   # prod-only packages
join <(awk 'NF>=4{print $1,$4}' $B/iot-gw-image-dev/installed-package-info.txt | sort) \
     <(awk 'NF>=4{print $1,$4}' $B/iot-gw-image-prod/installed-package-info.txt | sort) \
  | awk '$2 != $3'                                                     # shared packages whose version differs
```

Every prod-only package needs its own CVE check (for v0.7.0: our SSH hardening
config package, the prod packagegroup and `psplash`, none with CVE records). A
shared package at a different version, or a prod-only package with CVE
records, means the subset argument does not hold: scan prod itself with
`make sbom-cve IMAGE=prod`, which builds it in its own
composition. Record the release's CVE numbers as "dev, upper bound for prod".

**Then read back the exact report you just produced, not "the newest one".**
`make cve-report` resolves the most recent report in the deploy directory; if a
scan of the other profile is sitting there and is newer, you will read its
numbers and believe they are this release's. Bind the reader to the dated file
and confirm its identity:

```bash
ls -1t build/tmp/deploy/images/<machine>/*.sbom-cve-check.yocto.json

python3 scripts/sbom-cve/cve-report.py \
  -i build/tmp/deploy/images/<machine>/<image>-<machine>.rootfs-<BUILDNAME>.sbom-cve-check.yocto.json \
  --strict --require-latest
```

The provenance line it prints names the file that was read — check the image
name in it is the profile you released. `--strict` fails on a broken cohort
(missing or mismatched companion); `--require-latest` fails if the image was
rebuilt after the scan.

**Re-derive the kernel rows against the CVE feed.** The pinned scanner database
under-reports kernel CVEs whose per-branch fix boundary was published after the
pin, so rows can move `Patched → Unpatched` after re-derivation. A release recorded
from the raw report alone therefore understates the kernel. Run the CNA
re-derivation (procedure, commands and the mandatory `not applicable config: 0`
check: `KERNEL_CVE_APPLICABILITY.md` §"Running the CNA re-derivation") and record its result
alongside the raw one.

The enriched report is a **derived artifact**: it has no `.manifest` /
`.testdata.json` companions and cannot pass the same-build cohort check. Prove
integrity on the source report with `--strict --require-latest` first, then
attach the provenance block (source stem, source sha256, feed commit,
derivation command) that ties the derived numbers back to that validated build.

Record with the release:

- the **database cutoff** the scan was measured against (read it from
  `meta-iot-gateway/conf/distro/include/iotgw-cve-db.inc`, not from memory);
- the **CVE-feed commit** the re-derivation used, and its kernel totals
  (`vulnerable` / `version-not-in-range` / `from kernel CNA`);
- the **image profile** scanned, and the dated report filename;
- the `# status totals:` line verbatim (`Ignored` / `Patched` / `Unpatched`);
- the **kernel vs userland split** (`--kernel` includes the kernel rows, which
  are hidden by default);
- the Unpatched rows themselves — `--csv` dumps every row for attachment;
- for anything left open, why. "Unverified" and "accepted" are valid states;
  a confident sentence covering for one is not.

> **Do not report an "actionable vs dispositioned" split — the reader does not
> produce one, and the buckets do not mean that.** `Ignored` and `Patched` each
> mix scanner conclusions with human `CVE_STATUS` dispositions, and `Unpatched`
> holds both untriaged findings and ones deliberately left open as
> `vulnerable-investigating`. No documented command separates those, so any such
> figure would be hand-made and unreproducible. If that split is wanted as
> release evidence it needs a triage register that does not yet exist.

**Never publish a CVE figure without the cutoff beside it.** A bare count is
unfalsifiable and invites the reader to assume it means "current".

> **Deferred.** Scan artifacts are not yet part of the evidence bundle in §6,
> and the release scripts do not invoke or verify the scan. Wiring that up —
> along with reproducibility guarantees for the scan itself — follows the CVE
> triage work; until then this step is documented, not enforced.

## 6. Release Evidence Bundle

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
`build/tmp-glibc/deploy`). Override for non-standard layouts:

```bash
IOTGW_DEPLOY_ROOT=/path/to/deploy scripts/release/release-manifest.sh ...
```

## 7. Device Verification (Minimum)

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

## 8. Publish Release

The tag workflow creates or updates the GitHub Release notes automatically.
When no images are distributed, the release is the tag and its notes: §4 and
§6 are optional, and the board pass of the tested images stands in for §7.
Otherwise, attach release evidence to the GitHub Release:

- `release/vX.Y.Z/manifest.txt`
- `release/vX.Y.Z/checksums.sha256`
- serial/log evidence links (if available)

## 9. What GitHub Actions Does

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
