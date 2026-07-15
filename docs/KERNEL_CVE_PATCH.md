# Kernel CVE Patch — Field Guide

How to turn a Linux kernel CVE into a backport patch carried in this
Yocto layer, when the upstream fix isn't yet in your pinned `SRCREV`.

**Worked example (illustrative):** CVE-2026-31431 (`crypto: algif_aead`
write-to-page-cache, CISA KEV), stable backport `fafe0fa2` for `linux-6.18.y`,
applied against an example pin of `v6.18.13`. The commands and workflow are
real; the specific CVE, SRCREV, and the `0011-…` patch are a teaching example,
not shipped in the tree. Substitute the current pin (see
`linux-iotgw-mainline-common.inc`) and your actual CVE.

---

## When to use this approach

| Situation | Use |
|-----------|-----|
| CVE is fixed in a stable release past your `SRCREV` but you can't bump the kernel right now | **This guide** |
| You can bump `SRCREV_machine` forward to a release that includes the fix | Bump and drop any open backport patches for that CVE |
| The CVE is not yet patched upstream (no commit to backport) | Hold; track the kernel mailing list — out of scope here |
| Userspace CVE (openssl, glibc, etc.) | Bump the recipe `PV`/`SRCREV` or carry a `.bbappend` patch — same mechanics, different recipe |

For the automated triage that *finds* applicable CVEs, see
`INHERIT += "cve-check"` and the [Security guide](SECURITY.md). This
field guide is what you do **after** triage flags an unfixed CVE.

### Patch vs `SRCREV` bump — picking between them

When the fix has landed in a stable release **and** your branch tip is
ahead of that release, you have two valid options. They aren't
equivalent — pick deliberately:

| Factor | Carry a backport patch | Bump `SRCREV_machine` to a release containing the fix |
|---|---|---|
| Blast radius | One commit, one file, byte-clean revert | Hundreds of commits across the kernel — every stable backport since your pin |
| Verification effort | Targeted: `do_patch` clean + smoke test the affected subsystem | Broader smoke pass: boot, all live subsystems, regression watch over time |
| Time to remediation | Hours | Days (validation, regression triage) |
| Maintenance | Technical debt — must be dropped on next bump | None once landed |
| Other CVEs / regressions in the window | Not addressed | Picked up "for free" |
| Reproducibility of the in-flight release | Preserved (same kernel as last validated state) | Changed (now a different validated state) |

**Use the patch path when:**
- There's a hard deadline (CISA KEV `cisaActionDue`, customer SLA).
- You just shipped a release on the current `SRCREV` and don't want to
  invalidate its validation envelope.
- The vulnerable subsystem is narrow and easy to smoke-test in isolation.

**Use the `SRCREV` bump path when:**
- You're between releases (no in-flight validation to preserve).
- The gap between your pin and stable tip is large enough that you're
  almost certainly missing other security fixes.
- You have time for a broader smoke pass.

**Use both, in sequence**, when both apply:
1. Ship the carry-patch immediately for fast remediation.
2. Open a follow-up issue to bump `SRCREV_machine` to (or past) the
   stable release that contains the upstream fix, dropping the carry
   patch in the same commit.

The CVE-2026-31431 work in this repo took option (1) under CISA-KEV
pressure with the v0.4.0 release fresh, and queued a follow-up for the
6.18.13 → current-tip bump. Both moves are valid; the failure mode is
treating the carry-patch as permanent.

---

## 1. Pin down what you're patching

Before touching anything, two facts:

```bash
# (a) Kernel branch and pinned commit in the layer
grep -rE "BRANCH|SRCREV_machine|LINUX_VERSION" meta-iot-gateway/recipes-kernel/linux/

# (b) What's actually running on the device
ssh iotgw "uname -r"
```

For our example: `linux-6.18.y`, `SRCREV_machine = 25e0b1c2…` (= `v6.18.13`).

## 2. Read the CVE record as JSON, not prose

```bash
curl -fsSL "https://services.nvd.nist.gov/rest/json/cves/2.0?cveId=CVE-2026-31431" > /tmp/cve.json

# Affected version range for your kernel line
jq -r '.vulnerabilities[0].cve.configurations[].nodes[].cpeMatch[]
       | "\(.criteria) | start=\(.versionStartIncluding // "-") end_excl=\(.versionEndExcluding // "-")"' \
  /tmp/cve.json | grep linux_kernel
```

This tells you whether you're in range and which release closes it. For
CVE-2026-31431, the 6.x rows show `6.13 ≤ x < 6.18.22` — so 6.18.13 is
vulnerable, fix lands in 6.18.22.

Pull the reference URLs:

```bash
jq -r '.vulnerabilities[0].cve.references[].url' /tmp/cve.json | grep git.kernel.org
```

The `git.kernel.org/stable/c/<sha>` URLs are the fix commits: one mainline
plus N stable backports.

## 3. Identify which backport is for your branch

The stable backports for one CVE all carry the same `Subject:` and an
`[ Upstream commit <sha> ]` trailer — you can't tell them apart from the
patch headers alone.

Ask cgit for the log of the affected file scoped to your branch and grep
for the SHAs from step 2:

```bash
curl -fsSL "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/log/crypto/algif_aead.c?h=linux-6.18.y" \
  | grep -oE 'id=[0-9a-f]{40}' | head -10
```

The SHA that appears in both lists (NVD references **and** your branch's
file log) is your backport. For this CVE: `fafe0fa2`.

> If you don't know the affected file: grab any of the backports'
> patches (`curl ".../patch/?id=<any-sha>" | grep '^---'`) — the diff
> headers tell you which files changed.

## 4. Fetch the patch in `git format-patch` form

cgit's `/patch/` endpoint returns a ready-to-`git am` mail:

```bash
curl -fsSL "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/patch/?id=fafe0fa2995a0f7073c1c358d7d3145bcc9aedd8" \
  > /tmp/fix.patch
```

This format is exactly what Yocto's `do_patch` (git am / Quilt) expects.
**Do not post-process the diff** — leave it byte-identical to upstream.
Hand-editing the hunks is a sign you grabbed the wrong backport.

## 5. Annotate for Yocto QA

`oe-core` requires two lines for `cve-check.bbclass` and the patch-status
QA to recognise the patch:

```
Upstream-Status: Backport [https://git.kernel.org/.../?id=<sha>]
CVE: CVE-XXXX-XXXXX
```

Place them **above** the `---` diff separator (so `git am` doesn't choke).
Easiest is an awk one-liner:

```bash
awk 'BEGIN{a=0} /^---$/ && !a {
       print "Upstream-Status: Backport [https://git.kernel.org/.../?id=<sha>]"
       print "CVE: CVE-XXXX-XXXXX"
       print ""
       print; a=1; next
     } {print}' /tmp/fix.patch \
  > meta-iot-gateway/recipes-kernel/linux/files/0011-CVE-2026-31431-...patch
```

Valid `Upstream-Status:` values: `Backport`, `Pending`, `Inappropriate`,
`Submitted`, `Denied`, `Inactive-Upstream`. For a stable backport, always
**`Backport`** with the URL of the cherry-pick commit.

## 6. Wire it into the recipe

The `linux-iotgw-mainline-fit` provider consumes patches via the shared
`linux-iotgw-mainline-common.inc`. Add the patch there once:

```bitbake
# Security: CVE-2026-31431 (algif_aead in-place write-to-page-cache; CISA KEV).
# Stable 6.18.y backport (fafe0fa2) lands in 6.18.22; we pin 6.18.13 so apply
# the patch directly. Drop this line on the next SRCREV bump past v6.18.22.
SRC_URI:append = " file://0011-CVE-2026-31431-crypto-algif_aead-revert-to-out-of-place.patch"
```

Unconditional — security patches don't go behind feature flags. Even if
the vulnerable kconfig is off in today's image (e.g. our
`# CONFIG_CRYPTO_USER_API_AEAD is not set`), patching the source means a
developer who flips the kconfig on later picks up the fixed code.

The inline `# Drop on next SRCREV bump past vX.Y.Z` note prevents the
patch from ossifying after the next kernel update.

## 7. Verify the patch applies

```bash
bitbake -c cleansstate virtual/kernel
bitbake -c patch virtual/kernel    # stops after do_patch; faster than full build

grep -E "Applying patch|FAILED|Hunk" \
  build/tmp/work/*-poky-linux/linux-iotgw-mainline*/*/temp/log.do_patch
```

A clean `Applying patch 0011-...` with **no** `FAILED` / `Hunk` lines
proves the diff matched your tree exactly.

Belt-and-suspenders after a full build — grep the patched source for a
string unique to the fix:

```bash
grep -l "operating out-of-place" \
  build/tmp/work/*-poky-linux/linux-iotgw-mainline*/*/git/crypto/algif_aead.c
```

For CVE-2026-31431 specifically, the AEAD path isn't compiled into our
production kernel (`# CONFIG_CRYPTO_USER_API_AEAD is not set`), so no
runtime test exercises it on the default config. See the [Security
guide](SECURITY.md) for the live crypto surface (`dm-crypt`,
TPM/openssl, RAUC bundle decrypt) — none of those touch `algif_aead`.

## 8. Track the sunset

Every backport patch is technical debt. Track it in three places:

1. **Inline recipe comment** — *"drop on next SRCREV bump past vX.Y.Z"*.
2. **Patch filename** — prefix with `CVE-<id>` so a `git grep CVE-`
   surfaces all of them.
3. **CHANGELOG** — note the CVE under "Security" for the next release.

When you bump `SRCREV_machine`, sanity-check:

```bash
# Does the new SRCREV already contain the upstream fix?
git -C $DL_DIR/git2/git.kernel.org.pub.scm.linux.kernel.git.stable.linux.git \
    log <old_SRCREV>..<new_SRCREV> -- <affected-file>
```

If you see the cherry-pick in the log, delete the patch file and the
`SRC_URI:append` line in the same commit as the bump.

---

## Anti-patterns

- **Don't hand-edit the diff** to force hunks to apply. If a hunk fails,
  you grabbed the wrong backport — redo step 3.
- **Don't gate security patches behind feature flags.** Even if the
  vulnerable kconfig is off today, ship the patched source.
- **Don't skip `Upstream-Status:`.** It looks pedantic but `cve-check`
  and PatchTest CI rely on it; a patch without it is invisible to the
  CVE manifest.
- **Don't combine multiple CVEs into one patch.** The "drop when SRCREV
  passes vX.Y.Z" tracking only works if each patch closes exactly one CVE.
- **Put the patch in the shared include.** Put the
  `SRC_URI:append` in `linux-iotgw-mainline-common.inc`, not in the
  provider `.bb`.

## Cheat-sheet

| Task | Command |
|---|---|
| What CVEs affect me? | `INHERIT += "cve-check"`; `bitbake -c cve_check <image>`; inspect `tmp/log/cve/<image>.cve` |
| Is the fix in my `SRCREV`? | `git log <SRCREV>.. -- <affected-file>` — if you see the commit, you're patched |
| Which stable branch a SHA is on | `git.kernel.org/.../log/<file>?h=<branch>` and grep for the SHA |
| Raw patch in `git am` form | append `/patch/?id=<sha>` to the kernel.org repo URL |
| Mailing-list context | `oss-security` archive URLs in the NVD references — usually best for PoC links and disclosure timeline |

---

## See also

- [Security guide](SECURITY.md) — distribution-wide security posture, KSPP alignment, audit framework
- [Kernel driver backport — field guide](KERNEL_DRIVER_BACKPORT.md) — sibling guide for backporting *drivers* (not CVE fixes) into the mainline kernel recipe
- [Operations guide](OPERATIONS.md) — runbook for rolling a security fix to fleet (build → bundle → RAUC OTA → verify)
