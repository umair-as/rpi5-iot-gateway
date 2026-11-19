# Keep finished artifacts, and the boot chain they were built with, outside
# BitBake's control.
#
# DEPLOY_DIR_IMAGE belongs to sstate. When a build in another composition
# starts (even `bitbake -n`), sstate_eventhandler_reachablestamps removes the
# deploy outputs of task hashes that build does not reach. A dev bundle, its
# kernel and its U-Boot disappear as soon as a desktop or prod build starts,
# and getting them back means re-running the target. This task copies them into
# IOTGW_ARTIFACT_ARCHIVE_DIR right after they are deployed, where nothing in
# BitBake deletes them.
#
# Off unless IOTGW_ARTIFACT_ARCHIVE_DIR is set (kas/local.yml). Inherited by
# images and bundles. Each archives:
#   - its own deploy set (images: IOTGW_ARTIFACT_ARCHIVE_GLOBS only);
#   - each recipe in IOTGW_ARTIFACT_ARCHIVE_BOOTCHAIN (kernel, U-Boot, boot
#     script, firmware, FIT bootfiles), whole.
# What a recipe deployed is read from its sstate manifest, so version-bearing
# file names need no list here.
#
# Layout: <dir>/<name>/<stamp>/<deploy-relative paths> + SHA256SUMS, where
# <stamp> is the UTC mtime of the newest file in the set. sstate restores
# mtimes unchanged, so re-running a target, or restoring it from sstate, finds
# the folder already complete and does nothing, and dev and desktop share one
# U-Boot folder while each kernel gets its own. Image and bundle folders carry
# a BOOTCHAIN file naming the boot-chain folders they were built with. Files of
# IOTGW_ARTIFACT_ARCHIVE_LINK_MIN bytes or more (images, bundles) are hardlinked
# when the archive shares the filesystem; smaller ones are copied, because the
# FIT signing tools rewrite FITs and the bootfiles archive in place, which would
# change a hardlinked copy. Symlinks are recreated. The newest
# IOTGW_ARTIFACT_ARCHIVE_KEEP folders are kept per recipe, the one just written
# always among them.

IOTGW_ARTIFACT_ARCHIVE_DIR ??= ""
IOTGW_ARTIFACT_ARCHIVE_KEEP ??= "5"
IOTGW_ARTIFACT_ARCHIVE_LINK_MIN ??= "104857600"
# The sstate task whose manifest lists this recipe's artifacts.
IOTGW_ARTIFACT_ARCHIVE_TASK ??= "deploy"
# fnmatch patterns on deploy-relative names; empty = everything deployed.
IOTGW_ARTIFACT_ARCHIVE_GLOBS ??= ""
# Folder for this recipe's own set. One recipe that builds several artifacts
# (the bundle, one per image) sets a name per artifact so each keeps its own
# history.
IOTGW_ARTIFACT_ARCHIVE_NAME ??= "${PN}"
IOTGW_ARTIFACT_ARCHIVE_BOOTCHAIN ??= " \
    ${PREFERRED_PROVIDER_virtual/kernel} \
    u-boot \
    rpi-u-boot-scr \
    rpi-bootfiles \
    rpi-bootfiles-archive-fit \
"

def iotgw_archive_set(d, pn, task, globs, dest_root, keep, link_min, name=None):
    import fnmatch, hashlib, os, re, shutil, time

    ctrl = d.getVar('SSTATE_MANIFESTS')
    # Exact names: a glob on the PN suffix would also match foo-<pn>.
    mans = [m for m in (os.path.join(ctrl, 'manifest-%s-%s.%s' % (a, pn, task))
                        for a in sorted(set((d.getVar('SSTATE_ARCHS') or '').split())))
            if os.path.exists(m)]
    if not mans:
        bb.fatal('artifact archive: no sstate manifest for %s.%s in %s' % (pn, task, ctrl))
    man = max(mans, key=os.path.getmtime)
    deploy = d.getVar('DEPLOY_DIR_IMAGE').rstrip('/') + '/'
    with open(man) as f:
        paths = [l.strip() for l in f if l.strip() and not l.strip().endswith('/')]
    rel = [p[len(deploy):] for p in paths if p.startswith(deploy) and os.path.lexists(p)]

    def wanted(r):
        return not globs or any(fnmatch.fnmatch(os.path.basename(r), g) for g in globs)

    picked = set(r for r in rel if wanted(r))
    # A selected link brings its target along; a dated file left over from an
    # older build is kept only when a selected link still points to it.
    targets = set()
    for r in list(picked):
        p = deploy + r
        if os.path.islink(p):
            t = os.path.relpath(os.path.realpath(p), deploy)
            if t.startswith('..') or not os.path.exists(deploy + t):
                bb.fatal('artifact archive: link %s points outside %s or to a missing file' % (r, deploy))
            targets.add(t)
    dated = re.compile(r'-\d{14}(\.|$)')
    picked = set(r for r in picked if os.path.islink(deploy + r) or r in targets or not dated.search(r))
    picked |= targets
    if not picked:
        bb.fatal('artifact archive: nothing selected from %s (globs: %s)' % (man, ' '.join(globs)))

    reals = [r for r in picked if not os.path.islink(deploy + r)]
    newest = max(os.stat(deploy + r).st_mtime for r in reals)
    stamp = time.strftime('%Y%m%dT%H%M%S', time.gmtime(newest))
    name = name or pn
    base = os.path.join(dest_root, name)
    bb.utils.mkdirhier(base)
    # An image and its bundle archive the same boot-chain folders in parallel
    # tasks: one writer per folder at a time.
    lock = bb.utils.lockfile(os.path.join(base, '.lock'))
    try:
        return iotgw_archive_write(d, deploy, picked, base, name, stamp, keep, link_min)
    finally:
        bb.utils.unlockfile(lock)

def iotgw_archive_write(d, deploy, picked, base, name, stamp, keep, link_min):
    import hashlib, os, shutil
    dest_dir = os.path.join(base, stamp)
    done = os.path.join(dest_dir, 'SHA256SUMS')
    if os.path.exists(done):
        bb.note('artifact archive: %s/%s already kept' % (name, stamp))
        return '%s/%s' % (name, stamp)

    tmp_dir = dest_dir + '.partial'
    shutil.rmtree(tmp_dir, ignore_errors=True)
    sums = []
    for r in sorted(picked):
        src = deploy + r
        dst = os.path.join(tmp_dir, r)
        bb.utils.mkdirhier(os.path.dirname(dst))
        if os.path.islink(src):
            os.symlink(os.readlink(src), dst)
            continue
        linked = False
        if os.path.getsize(src) >= link_min:
            try:
                os.link(src, dst)
                linked = True
            except OSError:
                pass
        if not linked:
            shutil.copy2(src, dst)
        h = hashlib.sha256()
        with open(dst, 'rb') as f:
            for chunk in iter(lambda: f.read(1 << 20), b''):
                h.update(chunk)
        sums.append('%s  %s\n' % (h.hexdigest(), r))
    with open(os.path.join(tmp_dir, 'SHA256SUMS'), 'w') as f:
        f.writelines(sums)
    shutil.rmtree(dest_dir, ignore_errors=True)
    os.rename(tmp_dir, dest_dir)
    bb.plain('artifact archive: %s/%s (%d files)' % (name, stamp, len(sums)))

    others = sorted(e for e in os.listdir(base)
                    if e != stamp and os.path.isdir(os.path.join(base, e)) and not e.endswith('.partial'))
    for old in (others[:len(others) - (keep - 1)] if keep > 0 else []):
        shutil.rmtree(os.path.join(base, old))
        bb.note('artifact archive: pruned %s/%s' % (name, old))
    return '%s/%s' % (name, stamp)

python do_iotgw_archive() {
    import os
    dest_root = (d.getVar('IOTGW_ARTIFACT_ARCHIVE_DIR') or '').strip()
    if not dest_root:
        return
    if not os.path.isabs(dest_root):
        bb.fatal('artifact archive: IOTGW_ARTIFACT_ARCHIVE_DIR must be an absolute path, not %r' % dest_root)
    try:
        keep = int(d.getVar('IOTGW_ARTIFACT_ARCHIVE_KEEP') or '0')
        link_min = int(d.getVar('IOTGW_ARTIFACT_ARCHIVE_LINK_MIN') or '0')
    except ValueError:
        bb.fatal('artifact archive: IOTGW_ARTIFACT_ARCHIVE_KEEP and _LINK_MIN must be integers')
    chain = []
    for pn in (d.getVar('IOTGW_ARTIFACT_ARCHIVE_BOOTCHAIN') or '').split():
        chain.append(iotgw_archive_set(d, pn, 'deploy', [], dest_root, keep, link_min))
    own = iotgw_archive_set(d, d.getVar('PN'), d.getVar('IOTGW_ARTIFACT_ARCHIVE_TASK'),
                            (d.getVar('IOTGW_ARTIFACT_ARCHIVE_GLOBS') or '').split(),
                            dest_root, keep, link_min, d.getVar('IOTGW_ARTIFACT_ARCHIVE_NAME'))
    with open(os.path.join(dest_root, own, 'BOOTCHAIN'), 'w') as f:
        f.writelines('%s\n' % c for c in chain)
}
# Runs on every build of the target, including when the deploy tasks were
# restored from sstate (then they do not run themselves); a no-op when the
# folders are already complete. The boot-chain deploys must be present, so they
# are pulled in only when the archive is enabled: unset, the task adds nothing
# to the task graph.
do_iotgw_archive[nostamp] = "1"
do_iotgw_archive[depends] += "${@' '.join('%s:do_deploy' % pn for pn in (d.getVar('IOTGW_ARTIFACT_ARCHIVE_BOOTCHAIN') or '').split()) if (d.getVar('IOTGW_ARTIFACT_ARCHIVE_DIR') or '').strip() else ''}"
