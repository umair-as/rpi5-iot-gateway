# AGENTS.md

Canonical orientation for AI coding agents working in this repository. Agent-agnostic — Claude Code, Codex, Cursor, Copilot, etc. Claude-specific extras (skills, MCP servers) live in `CLAUDE.md`.

**This project is agent-driven.** Its commits, patches and docs are written by AI coding agents (Claude Code, Codex, Kiro) under the maintainer's direction and review; the maintainer is the commit author and answers for every change. Because that holds for the whole repository, individual commits do not carry an AI attribution trailer — see §"AI attribution".

## What this repo is

A Yocto/OpenEmbedded distribution (`iotgw`) for the Raspberry Pi 5, built with KAS. Produces hardened IoT-gateway images that boot SELinux enforcing on every image and ship rootless Podman containers as a first-class feature, with mandatory signed FIT boot, a dm-verity root, RAUC A/B OTA, and optional OpenThread Border Router, TPM and DEEPX DX-M1 support. AppArmor is not used.

- Yocto release: **wrynose** (Yocto 6.0 LTS; colon-based override syntax — see `.claude/rules/yocto-patterns.md`, which applies to any agent regardless of name)
- Target machine: `raspberrypi5` (aarch64, hard-float)
- Distro: `iotgw` (defined in `meta-iot-gateway/conf/distro/`)
- KAS entry point: `rpi5.yml` (base) — composed with overlays in `kas/*.yml`

## Build commands

Everything goes through the `Makefile`, which wraps `kas shell -c bitbake ...` and forwards feature toggles through `BB_ENV_PASSTHROUGH_ADDITIONS`. **Always prefer `make` over raw `kas`/`bitbake`** — the env-passthrough wiring matters.

```bash
make help                # authoritative target catalogue — check before raw bitbake
make dev|prod|base       # image variants (desktop lab image: make desktop)
make bundle IMAGE=dev    # FIT-format RAUC bundle (IMAGE=dev|desktop|prod)
make parse               # bitbake -p (parse-only sanity — cheapest validation)
make layers              # bitbake-layers show-layers
make test                # host test suites (SUITE= picks one; no build)
make info                # effective composition for IMAGE= (no build)
make shell               # interactive kas shell in IMAGE='s composition (ad-hoc bitbake)
make clean-lock          # remove a stale bitbake.lock (refuses a live one)
```

`make help` is the source of truth for the full catalogue (prod bundles, HSM re-signing, signing-tool tests, uv venv). FIT/HSM signing is **operator-driven** (YubiKey PIN+touch, or SoftHSM for YK-less devs) — profiles, tooling (`scripts/fit-signing/sign_fit.py`), and the resign flow are documented in `docs/FIT_BOOT_SIGNING.md`; do not run HSM signing targets unattended. **FIT signed boot is the only flow and is mandatory:** the distro selects the FIT kernel unconditionally and image builds hard-fail (at u-boot `do_configure`, via `iotgw-fit-signing-guard.bbclass`) unless the build-time FIT signing key (`UBOOT_SIGN_KEYDIR` / `UBOOT_SIGN_KEYNAME`, `fit_signing` block: a file key, or a PKCS#11 URI) is configured in `kas/local.yml`. A YubiKey cannot sign the build-time FIT; it is a DTB trust root and the post-build re-signer. Metadata inspection (`make parse`, `bitbake -e`) is not blocked.

Feature toggles (env vars; default off unless an overlay sets them):

```
IOTGW_ENABLE_OTBR
IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS
IOTGW_ENABLE_BTF_CORE_DEV
IOTGW_ENABLE_DEEPX_DXM1
```

Example: `IOTGW_ENABLE_OTBR=1 make bundle IMAGE=dev`.

The container runtime is not a toggle: every image ships it (`iotgw-common.inc`).

### KAS composition

The Makefile picks `BASE = kas/local.yml` if present, else `kas/rauc.yml` (RAUC is enabled by default). Other overlays under `kas/` are composed via `:`-separated paths:

- `kas/local.yml` — developer-local secrets/WiFi/RAUC keys and shared cache paths (gitignored; copy from `local.yml.example`)
- `kas/rauc.yml` — RAUC OTA stack
- `kas/otbr.yml`, `kas/tpm.yml`, `kas/cve.yml`, `kas/spdx.yml` — feature overlays
- `kas/uboot-prod-hardening.yml` — composed with `prod` and `bundle IMAGE=prod`; required (the target fails if it is missing)
- `kas/fit-release-trust.yml` — release FIT trust profile (YubiKey anchor only); composed with `prod` and `bundle IMAGE=prod`; required
- `kas/deepx.yml` — DEEPX DX-M1 layer + `IOTGW_ENABLE_DEEPX_DXM1=1`; composed by every non-prod composition (`base`, `dev`, their bundles, and `parse`/`layers`/`shell`/`sbom-cve` at the default `IMAGE=dev`) and included by `kas/desktop.yml`. Prod stays without it until the module-signing key is protected (`docs/DEEPX_DXM1.md` §7)
- `kas/desktop.yml` — desktop image variant; includes `kas/deepx.yml` (the desktop is the AI demo station)

Shared layers are not cloned manually: kas checks them out into the gitignored `.kas/` (`KAS_WORK_DIR`) using bare-mirror alternates from `KAS_REPO_REF_DIR` (an operator-local layer cache set by `scripts/env.sh`), preserving the SHA pins in `rpi5.yml`. `kas/local.yml` supplies the shared `DL_DIR`/`SSTATE_DIR`.

### Standalone `kas` invocations — source the env first

The Makefile exports `KAS_WORK_DIR`/`KAS_BUILD_DIR`/`KAS_REPO_REF_DIR` only to
its own sub-processes. A bare `kas shell …` in any other shell falls back to
kas' default `KAS_WORK_DIR = CWD` and **re-clones the entire upstream layer
stack into the repo root**. When a raw kas call is unavoidable (e.g.
`bitbake -e` variable inspection), source the env in the same command:

```bash
. scripts/env.sh && kas shell -c 'bitbake -e rauc' kas/local.yml
```

Interactive shells get this automatically via `.envrc` (direnv, after a
one-time `direnv allow`). Non-interactive shells — including AI-agent tool
shells, CI steps, and scripts — do **not** trigger direnv and must source
`scripts/env.sh` explicitly or go through `make`. If the accident happens
anyway: the stray root clones are untracked; confirm
`build/conf/bblayers.conf` points at `.kas/` before deleting them.

Build artifacts land in `build/tmp/deploy/images/raspberrypi5/`. Flash the `.wic.zst` with `zstdcat … | dd` — or `bmaptool copy` plus deleting `uboot.env` from the `ubootenv` partition (p2); plain `bmaptool` can leave a stale U-Boot env file on reused cards. Never zero p2 itself — the vfat and its label must survive or the `/uboot-env` mount fails at boot. Full flashing/provisioning runbook: `docs/OPERATIONS.md`.

### Image variants

`iot-gw-image-base | -dev | -prod | -desktop` — recipes live in `meta-iot-gateway/recipes-core/images/`. The `.inc` is shared scaffolding.

### Releases & CI

- Release helper: `scripts/release/release-build.sh` + `scripts/release/release-manifest.sh` — process in `docs/RELEASE.md`
- CI: `.github/workflows/release-hygiene.yml` (release-hygiene lint only — no Yocto builds in CI)
- Changelog assembled in batches before release — do not add an entry for every trivial bump

## Repo layout (orient yourself fast)

```
rpi5.yml                     # KAS base config (layers + machine + distro)
kas/                         # KAS overlays (feature toggles, secrets, desktop, etc.)
Makefile                     # build entry point — use this, not raw kas/bitbake
meta-iot-gateway/            # the custom layer (everything project-specific lives here)
  conf/distro/               # iotgw distro definition
  recipes-bsp/               # u-boot, rpi-eeprom, bootfiles, bootlogo
  recipes-core/images/       # iot-gw-image-{base,dev,prod,desktop}.bb
  recipes-kernel/            # linux-iotgw* recipes, kernel fragments, bpftool
  recipes-ota/               # rauc, bundles, ota-updater, ota-certs, ota-user
  recipes-connectivity/      # openssh, otbr (custom OTBR overlay), wpa-supplicant, avahi
  recipes-containers/        # podman/buildah/skopeo wiring
  recipes-observability/     # logging/metrics
  recipes-security/          # nftables, SELinux refpolicy + relabel, audit, hardening bits
  recipes-support/           # misc project utilities
  files/wic/                 # partition layouts (RAUC A/B WKS variants)
docs/                        # OPERATIONS, SECURITY, KERNEL, PARTITIONS, RAUC_UPDATE,
                             #   OTBR, FIT_BOOT_SIGNING, PERSISTENT_STATE, …
scripts/                     # host-side tooling (release, OTA bench, signing, TPM utils)
.claude/
  rules/yocto-patterns.md    # wrynose syntax + parser limits + identity/rootfs patterns
  rules/recipe-conventions.md # read before authoring a recipe or shipping a patch
  rules/cross-compilation.md # aarch64-poky-linux SDK notes — read before app cross-builds
  skills/devtool-workflow/   # devtool modify→finish cycle, patch export + verification
  skills/yocto-worktree/     # isolated-worktree workflow for parallel/build-heavy agents
```

## Conventions

- **Colon override syntax (Scarthgap+)** — `RDEPENDS:${PN}`, `do_install:append()`, `SRC_URI:append:raspberrypi5`. Never the deprecated underscore form. See `.claude/rules/yocto-patterns.md`.
- **No hardcoded paths in recipes** — use `${bindir}`, `${sysconfdir}`, `${systemd_system_unitdir}`, etc.
- **Recipe & patch conventions** — HOMEPAGE, patch identity/attribution, `Upstream-Status` taxonomy, `/root` paths, `SYSTEMD_AUTO_ENABLE`, and the sstate patch-header rebuild gotcha live in `.claude/rules/recipe-conventions.md`. Read it before authoring a recipe or shipping a patch.
- **Cross-compile target is aarch64-poky-linux** — `.claude/rules/cross-compilation.md` covers SDK setup, CMake/Rust/Go specifics, and verification commands.
- **Public-repo discipline** — committed files reference only repo-relative paths or public `docs/`; never absolute `/home/<user>/...` paths, device IPs, or home-lab topology. Operator-local material goes in `kas/local.yml` / `scripts/env.sh`-managed locations (gitignored).
- **Commit style**: `<type>(<scope>): <subject>` — imperative, no period. Types: `feat|fix|docs|refactor|test|chore|build|ci|perf|style|revert` — the set `cliff.toml` parses; anything else lands in the changelog's "Other" bucket. Scopes may be hyphenated (`ota-certs`, `sbom-cve`) or comma-composed (`fit,uboot`). Enforced by the `commit-msg` hook. Prefer a lowercase subject, but leading initialisms (`CVE`, `FIT`, `TPM`) are fine and the hook does not block them. No AI attribution trailers — see §"AI attribution".
- **Commit body length scales with the change**: trivial (bump, rename, typo, a few lines) — no body or 1–2 lines; normal — at most 10 lines: what and why, plus one line on what verified it; large or behaviour-changing — at most 25. Long evidence goes in `docs/` or the PR, and the body points to it. The `commit-msg` hook blocks bodies over 25 lines (trailers and blank lines not counted).
- **Branch naming**: `<type>-<scope>-<subject>`, matching commit style (e.g. `feat-rauc-pki-yubikey-stage1`).
- **PR scope**: bundle trivial recipe/version bumps into a related feature PR rather than landing them standalone.
- **Don't write CHANGELOG entries for trivial bumps** — changelog is assembled in batches before a release.

## Git hooks

Tracked in `scripts/hooks/`, activated per clone by `core.hooksPath`:

```bash
make hooks     # run once after cloning; idempotent
```

- `pre-commit` — refuses staged private-key material and anything under
  `keys/`. Defense-in-depth over `.gitignore`, which does not stop
  `git add -f` or a `git mv` into `keys/`. Checks renames too.
- `commit-msg` — enforces the Conventional Commit subject above, so the
  git-cliff release notes stay parseable, the 25-line body cap, and no AI
  `Co-Authored-By:` (§"AI attribution"). Merge/revert/fixup subjects skip
  the subject check; the AI co-author and pattern checks apply to every
  message.
- Both also apply an optional per-clone pattern list,
  `.git/info/commit-patterns` (untracked; one regex per line), to added
  lines and commit messages. No file, no check.

`core.hooksPath` is local config, not a tracked file: a fresh clone has
**both hooks silently disabled** until `make hooks` runs. Neither hook is
a security control on its own — CI and review still are. Escape hatch for
a hook you are certain is wrong: `git commit --no-verify`.

## AI attribution

The project is agent-driven (top of this file), so attribution is stated once,
here, instead of on every commit.

- **No `Assisted-by:` trailer** on new commits or newly written patches.
  Commits and patches that already carry one keep it: history is not rewritten,
  and a patch header edit forces a rebuild (`.claude/rules/recipe-conventions.md`).
- **No `Co-Authored-By:` for an AI tool** — not in commits, not in PR bodies. It
  claims authorship by something that cannot hold it. The `commit-msg` hook
  blocks it.
- **No generated-with footer in PR bodies** (e.g. "🤖 Generated with Claude
  Code"): it is the same per-change attribution, stated once at the top of
  this file instead. A bot co-author that is not an AI tool (e.g. `dependabot[bot]`)
  passes.
- **The maintainer is the author** and is responsible for having reviewed what
  the agents produced. No agent adds a `Signed-off-by:` on its own initiative.
- When how a change was made matters to its review — a model-written
  migration, a fix taken from an automated finding — say so in the PR
  description, where it can be explained, not in a trailer.
- Patches sent upstream follow the receiving project's rules at submission
  time.

Background: the Linux kernel asked for an `Assisted-by:` tag from 7.0 and
removed it again in mainline commit `1e035297ffda` ("docs: remove Assisted-by
references"): a per-patch tag that many contributors leave off gives no
reliable signal, and how tools were used belongs in the cover letter. This
repository took the trailer from there and drops it for the same reason.

## Validating behaviour changes

A green build and an approving review are not evidence. Both are produced by
reasoning over the same artifact with the same blind spots — an agent reviewing an
agent's change converges on *plausible*, not *correct*. Before claiming a change is
right, produce a check whose answer comes from something other than a model.

Applies to any change that decides something about real inputs:

- matching, filtering or classifying logic — parsers, regexes, globs, version
  comparisons, dedupe/merge rules
- security metadata that suppresses findings — `CVE_STATUS` dispositions, VEX
  claims, exclusion lists. These fail **silently**: a wrong entry removes a CVE from
  the report instead of turning something red, and downstream tooling that trusts
  `CVE_STATUS` inherits the mistake.
- anything whose failure mode is "the output looks fine but something is missing"

Ranked by what the evidence is worth:

1. **Differential run** — keep the old behaviour beside the new, run both over real
   data, diff the outputs. Every disagreement is a change you must be able to
   explain. Check **both** directions: what stopped matching, and what started.
2. **Per-claim verification against an independent source** — for metadata
   dispositions, check each claim (shipped version vs fixed boundary, product
   mismatch) against upstream CVE data, *not* against the scanner that produced the
   finding. What may suppress a finding and what may only deprioritise it:
   `docs/CVE_APPLICABILITY.md`; where each kind of statement is authored:
   `docs/SBOM_CVE.md`.
3. **On-target validation** — for runtime behaviour the board is the oracle.
4. A build, lint run, or test suite — necessary, but only covers what someone
   already thought of.

What makes it actually work:

- **Classify the whole delta, not the top N.** The tail is where the wrong ones hide.
- **Isolate the variable** — set local changes aside and re-measure the raw baseline
  first, so the delta is attributable to the change and not to image drift.
- **State which axis is clean** when the underlying data drifts, rather than quoting
  a total that mixes signal with feed noise.
- **Keep the commands re-runnable** and logged next to the work, so the numbers can
  be reproduced instead of believed.
- **Put the result in the commit body** — one line: what was run, what it showed
  (longer evidence goes in `docs/` or the PR). When a claim could not be verified,
  say so plainly. "Unverified" is a valid state; a confident
  sentence covering for one is not.

## Working economically

- Inspect narrowly before scanning broadly — a recipe name or `bitbake-getvar` beats a repo-wide grep.
- Validate progressively: `make parse` → the affected recipe's task → image build. Don't launch a full image build to test a parse-level change.
- On build failure, extract the **first causal error** from the task log and cite log files by path (`build/tmp/work/.../temp/log.do_*`); don't paste whole BitBake logs into the conversation.
- Don't re-run an equivalent failing command hoping for a different result — change one variable per retry.
- No speculative adjacent refactors; keep the diff scoped to the request.
- Subagents and isolated worktrees only when parallelism or build pollution justifies the cost (Claude: `yocto-worktree` skill).
- **Long-running builds (>~10 min): use the shared tmux launcher, never the agent harness's background-process mechanism.** From an ordinary foreground tool call in the selected worktree:

  ```bash
  . scripts/env.sh
  python3 scripts/agent-build/agent-build.py start <topic> -- <make-target>
  ```

  Immediately give the operator the printed read-only attach command, run directory and log path. Follow it with `agent-build.py status` or `agent-build.py wait --timeout N` (exit 0 ok, 1 failed, 2 interrupted/unknown, 3 still running), never with plain `tmux`; only a recorded zero exit code means success. Do not clean up running sessions when the agent turn ends. The helper preserves a terminal, logs before make starts, records make's status and rejects concurrent helper builds for the same build directory. HSM signing remains operator-driven. Details, environment forwarding, cleanup and limitations: `docs/AGENT_BUILDS.md`. Keep monitoring already-running `setsid nohup` builds through their existing logs. Neither launch method guarantees survival against host shutdown or enclosing cgroup cleanup; for critical builds, the operator can launch from their own terminal.
- Stop at the requested milestone; report remaining work instead of continuing unprompted.

## Where detailed guidance lives

| Task | Read |
|---|---|
| Authoring recipes / shipping patches | `.claude/rules/recipe-conventions.md` |
| Yocto syntax, parser limits, identity/rootfs patterns | `.claude/rules/yocto-patterns.md` |
| Cross-compiling apps outside bitbake | `.claude/rules/cross-compilation.md` |
| FIT boot signing, HSM/YubiKey/SoftHSM | `docs/FIT_BOOT_SIGNING.md` |
| Flashing, provisioning, target ops, SSH sessions and SELinux login domains | `docs/OPERATIONS.md` |
| RAUC OTA install/rollback | `docs/RAUC_UPDATE.md`, `docs/OTA_UPDATE.md` |
| Kernel config / CVE & driver backports | `docs/KERNEL.md`, `docs/KERNEL_CVE_PATCH.md`, `docs/KERNEL_DRIVER_BACKPORT.md` |
| SBOM / CVE scanning, reading reports, userspace triage | `docs/SBOM_CVE.md` |
| DEEPX DX-M1 accelerator: build gates, module signing, device policy | `docs/DEEPX_DXM1.md` |
| AI accelerators — new to the domain, vocabulary, the host/target model | `docs/AI_ACCELERATION_101.md` |
| AI accelerators — pipeline diagram, what's built by whom, extending to a second vendor | `docs/AI_ACCELERATION_ARCHITECTURE.md` |
| Deciding whether a CVE applies: stages, evidence, what may suppress | `docs/CVE_APPLICABILITY.md` |
| Kernel applicability — build-object oracle, CNA re-derivation, the compiled-source blind spot | `docs/KERNEL_CVE_APPLICABILITY.md` |
| Release workflow | `docs/RELEASE.md` |
| Shared sstate not reused across builds; hash-equivalence DB; measuring with `bitbake -n` | `docs/SSTATE_SHARING.md` |
| Partition layouts | `docs/PARTITIONS.md` |
| Persistent state, pre-init, `/data`, degraded boot | `docs/PERSISTENT_STATE.md` |
| SELinux concepts, local wiring, reading a denial | `docs/SELINUX.md` |
| SELinux enforcing: runtime trials, open findings | `docs/SELINUX_ENFORCING.md` |

One operational warning worth carrying everywhere: on running targets, an SSH login as `root` lands in the SELinux `staff_t` domain, not `sysadm_t` (only the serial console does). Under enforcing, a `Permission denied` for root over SSH is usually that domain, not a file mode, a mount or a broken `/etc` — check `id -Z` and the AVC denials before diagnosing anything else. Root over SSH elevates with `newrole -r sysadm_r` only (root has no sudoers entry); named admin accounts in the `sudo` group (e.g. `devel`) use `sudo -i`. SSH shells share PID1's mount namespace, so mounts seen from them are the real ones. Details: `docs/OPERATIONS.md` §10.
