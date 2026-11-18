# Runtime root dm-verity for the A/B images.
#
# Inherited by every image recipe (iot-gw-image-base.inc): runtime dm-verity is
# the only root flow, as signed FIT boot is the only boot flow.
#
# What it builds
# --------------
# 1. <image>.ext4.verity: the rootfs ext4 image with a dm-verity hash tree
#    appended (meta-oe image_types_verity). One self-contained file, written to
#    BOTH root slots by the WKS and shipped in the RAUC bundle as a raw slot
#    image.
# 2. <image>.fitImage-a / .fitImage-b: one signed FIT per slot. Each carries the
#    kernel and a copy of the board device tree whose /chosen/bootargs is the
#    complete kernel command line, including the dm-verity table and therefore
#    the root hash. U-Boot boots that device tree with its own `bootargs`
#    cleared (see the verity boot-path patch for U-Boot), so verifying the FIT
#    signature authenticates the root hash: a modified or substituted rootfs no
#    longer matches, the kernel cannot assemble /dev/dm-0, and the RAUC boot
#    counter eventually falls back to the other slot.
#
# The two FITs differ only in the slot device and the rauc.slot= argument. The
# root hash is the same because both slots receive the same image.
#
# Limits worth knowing
# --------------------
# * The kernel command line is fixed at build time. The firmware cmdline.txt
#   content and IOTGW_VERITY_KERNEL_ARGS are baked in; the writable U-Boot
#   EXTRA_KERNEL_ARGS variable does not influence the boot.
# * Device-tree changes the firmware applies to its own copy at boot
#   (config.txt dtoverlay= / dtparam= entries) do not reach the FIT's device
#   tree. The image ships no overlay .dtbo files today, so no overlay is lost
#   in practice; a feature that needs one must patch the board DTB instead.
# * A rootfs-only update cannot boot: the new root hash is only in the FIT, so
#   the bundle must carry the matching per-slot FITs. That is fail-closed by
#   construction.
# * The per-slot FITs are signed in-band with the file key only. Under the
#   release-trust profile the DTB does not trust that key, so the FITs built
#   here are intermediates: iotgw-fit-gate checks them against the build key,
#   the operator re-signs the pair with the HSM key (sign_fit.py
#   sign-slot-fits), and the bundle recipe refuses to assemble FITs that do not
#   verify against the release anchor it ships. See docs/FIT_BOOT_SIGNING.md.
# * The U-Boot environment of a development image is still writable, so this
#   authenticates the root against offline tampering and a corrupt slot; it is
#   not a hardware-rooted chain.

inherit image_types_verity kernel-arch uboot-config
require conf/image-fitimage.conf

python () {
    # meta-selinux's selinux-autorelabel relabels and reboots while
    # /.autorelabel exists, then deletes it. On a read-only dm-verity root it can
    # never be deleted: the device would relabel and reboot forever.
    if d.getVar('FIRST_BOOT_RELABEL') == '1':
        bb.fatal("FIRST_BOOT_RELABEL=1 puts /.autorelabel on the read-only dm-verity "
                 "root, which selinux-autorelabel can never remove: an endless "
                 "relabel-and-reboot loop. The root is labelled at build time.")
    if (d.getVar('UBOOT_SIGN_KEYDIR') or '').startswith('pkcs11:'):
        bb.fatal("Runtime dm-verity signs the per-slot FITs with mkimage -k <keydir>; "
                 "a PKCS#11 UBOOT_SIGN_KEYDIR is not supported for them yet.")
}

IMAGE_FSTYPES:append = " verity"

# A stable per-image salt keeps the image reproducible while avoiding the
# shared class default. The root hash still changes with the image content.
VERITY_SALT = "${@__import__('hashlib').sha256(('%s:%s:%s' % (d.getVar('PN'), d.getVar('MACHINE'), d.getVar('DISTRO'))).encode()).hexdigest()}"

# Device tree that carries the command line, and the FIT node names derived from
# it (matching the FIT assembled for the non-verity flow).
IOTGW_VERITY_DTB ?= "bcm2712-rpi-5-b.dtb"

# Block device of each root slot as the kernel names it. The WKS layout puts the
# boot partition first, the U-Boot environment second, then root A and root B.
IOTGW_VERITY_SLOT_A_DEV ?= "/dev/mmcblk0p3"
IOTGW_VERITY_SLOT_B_DEV ?= "/dev/mmcblk0p4"

# Extra kernel arguments baked into the signed command line.
IOTGW_VERITY_KERNEL_ARGS ?= ""

IOTGW_VERITY_LOADADDRESS ?= "${UBOOT_LOADADDRESS}"
IOTGW_VERITY_ENTRYPOINT ?= "${UBOOT_ENTRYPOINT}"

IOTGW_VERITY_FIT_A ?= "${IMAGE_LINK_NAME}.fitImage-a"
IOTGW_VERITY_FIT_B ?= "${IMAGE_LINK_NAME}.fitImage-b"
IOTGW_VERITY_IMAGE_FILE ?= "${IMGDEPLOYDIR}/${IMAGE_LINK_NAME}.ext4.verity"

# Root slots come from the prebuilt verity image. No --label: the rawcopy plugin
# would run a filesystem labeller on the copied image, rewriting the ext4
# superblock after the hash tree was computed and invalidating the root hash.
IOTGW_WKS_ROOT_A_ARGS = '--source rawcopy --sourceparams="file=${IOTGW_VERITY_IMAGE_FILE}"'
IOTGW_WKS_ROOT_B_ARGS = '--source rawcopy --sourceparams="file=${IOTGW_VERITY_IMAGE_FILE}"'

# /boot carries the two slot FITs and not the generic FIT: the verity boot path
# has no fallback to an image without a verity table.
IMAGE_BOOT_FILES:remove = "fitImage"
IMAGE_BOOT_FILES:append = " ${IMGDEPLOYDIR}/${IOTGW_VERITY_FIT_A};fitImage-a ${IMGDEPLOYDIR}/${IOTGW_VERITY_FIT_B};fitImage-b"

# Parse the meta-oe .verity-params file. Only simple KEY=value lines are
# accepted, because the values end up in a kernel command line.
def iotgw_verity_parse_params(text):
    import re

    required = ("VERITY_DATA_BLOCKS", "VERITY_DATA_BLOCK_SIZE",
                "VERITY_HASH_BLOCK_SIZE", "VERITY_HASH_ALGORITHM",
                "VERITY_ROOT_HASH", "VERITY_SALT", "VERITY_DATA_SECTORS")
    params = {}
    for raw in text.splitlines():
        raw = raw.strip()
        if not raw:
            continue
        if not re.fullmatch(r"[A-Z0-9_]+=[A-Za-z0-9_-]*", raw):
            raise ValueError("unsafe dm-verity parameter line: %r" % raw)
        key, value = raw.split("=", 1)
        params[key] = value
    missing = sorted(key for key in required if not params.get(key))
    if missing:
        raise ValueError("missing dm-verity parameters: %s" % ", ".join(missing))
    return params

# The dm-mod.create= table: a self-contained image has its hash tree directly
# after the data blocks, so the hash start block equals the data block count.
def iotgw_verity_dm_table(params, device):
    return ("vroot,,,ro,0 {sectors} verity 1 {dev} {dev} {data_bs} {hash_bs} "
            "{data_blocks} {data_blocks} {algorithm} {root_hash} {salt} "
            "1 restart_on_corruption").format(
        sectors=params["VERITY_DATA_SECTORS"], dev=device,
        data_bs=params["VERITY_DATA_BLOCK_SIZE"],
        hash_bs=params["VERITY_HASH_BLOCK_SIZE"],
        data_blocks=params["VERITY_DATA_BLOCKS"],
        algorithm=params["VERITY_HASH_ALGORITHM"],
        root_hash=params["VERITY_ROOT_HASH"], salt=params["VERITY_SALT"])

# Complete kernel command line for one slot. Arguments that would contradict the
# authenticated root are dropped from the firmware command line; the dm table is
# the only thing allowed to define it.
def iotgw_verity_bootargs(slot, device, table, firmware_cmdline, extra_args):
    drop_prefixes = ("root=", "rootfstype=", "rootflags=", "rauc.slot=",
                     "dm-mod.", "dm=")
    drop_exact = ("ro", "rw", "rootwait")
    tokens = [t for t in firmware_cmdline.split()
              if t not in drop_exact and not t.startswith(drop_prefixes)]
    extra = extra_args.split()
    for token in tokens + extra:
        if '"' in token:
            raise ValueError("quote in kernel argument %r" % token)
    parts = ["root=/dev/dm-0", "rootfstype=ext4", "ro", "rootwait",
             "rauc.slot=%s" % slot,
             "dm-mod.waitfor=%s" % device,
             'dm-mod.create="%s"' % table] + tokens + extra
    bootargs = " ".join(parts)
    # arm64 COMMAND_LINE_SIZE is 2048 including the terminator.
    if len(bootargs) >= 2000:
        raise ValueError("kernel command line is %d bytes, too close to the "
                         "2048-byte kernel limit" % len(bootargs))
    return bootargs

def iotgw_verity_its(slot, kernel, dtb, dtb_name, arch, compression, load, entry, hash_alg, sign_alg, pad_alg, keyname):
    # Built from indented list lines on purpose: BitBake ends a `def` block at
    # the first column-0 line, so a column-0 template string would break it.
    def quote(value):
        return value.replace("\\", "\\\\").replace('"', '\\"')

    fdt = "fdt-" + dtb_name
    conf = "conf-" + dtb_name
    lines = [
        "/dts-v1/;",
        "",
        "/ {",
        '    description = "IoT Gateway OS dm-verity slot %s";' % slot,
        "    #address-cells = <1>;",
        "    images {",
        "        kernel-1 {",
        '            description = "Linux kernel";',
        '            type = "kernel";',
        '            compression = "%s";' % compression,
        '            data = /incbin/("%s");' % quote(kernel),
        '            arch = "%s";' % arch,
        '            os = "linux";',
        "            load = <%s>;" % load,
        "            entry = <%s>;" % entry,
        "            hash-1 {",
        '                algo = "%s";' % hash_alg,
        "            };",
        "        };",
        "        %s {" % fdt,
        '            description = "Slot %s device tree carrying the dm-verity command line";' % slot,
        '            type = "flat_dt";',
        '            compression = "none";',
        '            data = /incbin/("%s");' % quote(dtb),
        '            arch = "%s";' % arch,
        "            hash-1 {",
        '                algo = "%s";' % hash_alg,
        "            };",
        "        };",
        "    };",
        "    configurations {",
        '        default = "%s";' % conf,
        "        %s {" % conf,
        '            description = "Linux kernel and slot %s verity device tree";' % slot,
        '            kernel = "kernel-1";',
        '            fdt = "%s";' % fdt,
        "            hash-1 {",
        '                algo = "%s";' % hash_alg,
        "            };",
        "            signature-1 {",
        '                algo = "%s,%s";' % (hash_alg, sign_alg),
        '                key-name-hint = "%s";' % keyname,
        '                padding = "%s";' % pad_alg,
        '                sign-images = "kernel", "fdt";',
        "            };",
        "        };",
        "    };",
        "};",
    ]
    return "\n".join(lines) + "\n"

do_image_verity_fit[depends] += " \
    virtual/kernel:do_deploy \
    rpi-cmdline:do_deploy \
    u-boot-tools-native:do_populate_sysroot \
    dtc-native:do_populate_sysroot \
"
do_image_verity_fit[dirs] = "${WORKDIR}/verity-fit"
do_image_verity_fit[cleandirs] = "${WORKDIR}/verity-fit"
do_image_verity_fit[file-checksums] += "${UBOOT_SIGN_KEYDIR}/${UBOOT_SIGN_KEYNAME}.key:True ${UBOOT_SIGN_KEYDIR}/${UBOOT_SIGN_KEYNAME}.crt:True"

python do_image_verity_fit() {
    import os
    import shutil
    import subprocess

    if d.getVar("UBOOT_SIGN_ENABLE") != "1":
        bb.fatal("Runtime dm-verity needs a signed FIT: UBOOT_SIGN_ENABLE is not 1.")

    image_deploy = d.getVar("IMGDEPLOYDIR")
    deploy = d.getVar("DEPLOY_DIR_IMAGE")
    work = os.path.join(d.getVar("WORKDIR"), "verity-fit")
    link_name = d.getVar("IMAGE_LINK_NAME")
    params_path = os.path.join(image_deploy, link_name + ".ext4.verity-params")
    verity_path = d.getVar("IOTGW_VERITY_IMAGE_FILE")

    if not os.path.getsize(os.path.realpath(verity_path)):
        bb.fatal("dm-verity image is empty: %s" % verity_path)
    try:
        with open(params_path, encoding="ascii") as stream:
            params = iotgw_verity_parse_params(stream.read())
    except (OSError, ValueError) as err:
        bb.fatal("dm-verity parameters unusable (%s): %s" % (params_path, err))

    kernel = os.path.join(deploy, d.getVar("FIT_LINUX_BIN"))
    dtb_name = d.getVar("IOTGW_VERITY_DTB")
    dtb = os.path.join(deploy, dtb_name)
    cmdline_path = os.path.join(deploy, d.getVar("BOOTFILES_DIR_NAME") or "bootfiles", "cmdline.txt")
    comp_path = os.path.join(deploy, "linux_comp")
    for path in (kernel, dtb, cmdline_path, comp_path):
        if not os.path.isfile(path):
            bb.fatal("Signed verity FIT input not found: %s" % path)
    with open(comp_path, encoding="ascii") as stream:
        compression = stream.read().strip()
    with open(cmdline_path, encoding="utf-8") as stream:
        firmware_cmdline = stream.read()

    keydir = d.getVar("UBOOT_SIGN_KEYDIR")
    keyname = d.getVar("UBOOT_SIGN_KEYNAME")
    for suffix in (".key", ".crt"):
        key = os.path.join(keydir, keyname + suffix)
        if not os.path.isfile(key):
            bb.fatal("FIT signing key not found: %s" % key)

    for slot, device, output_name in (
            ("A", d.getVar("IOTGW_VERITY_SLOT_A_DEV"), d.getVar("IOTGW_VERITY_FIT_A")),
            ("B", d.getVar("IOTGW_VERITY_SLOT_B_DEV"), d.getVar("IOTGW_VERITY_FIT_B"))):
        if not device:
            bb.fatal("IOTGW_VERITY_SLOT_%s_DEV is empty. The device is written into the "
                     "signed dm-verity table, so a wrong value gives a correctly "
                     "signed image that cannot mount its own root." % slot)
        table = iotgw_verity_dm_table(params, device)
        try:
            bootargs = iotgw_verity_bootargs(slot, device, table, firmware_cmdline,
                                             d.getVar("IOTGW_VERITY_KERNEL_ARGS") or "")
        except ValueError as err:
            bb.fatal("Cannot build the slot %s kernel command line: %s" % (slot, err))

        slot_dtb = os.path.join(work, "verity-%s.dtb" % slot)
        shutil.copyfile(dtb, slot_dtb)
        subprocess.run(["fdtput", "-p", "-t", "s", slot_dtb, "/chosen", "bootargs", bootargs],
                       check=True)
        stored = subprocess.run(["fdtget", slot_dtb, "/chosen", "bootargs"], check=True,
                                capture_output=True, text=True).stdout.rstrip("\n")
        if stored != bootargs:
            bb.fatal("Slot %s device tree did not store the command line verbatim." % slot)

        its = iotgw_verity_its(slot, kernel, slot_dtb, dtb_name, d.getVar("UBOOT_ARCH"),
                               compression, d.getVar("IOTGW_VERITY_LOADADDRESS"),
                               d.getVar("IOTGW_VERITY_ENTRYPOINT"), d.getVar("FIT_HASH_ALG"),
                               d.getVar("FIT_SIGN_ALG"), d.getVar("FIT_PAD_ALG"), keyname)
        its_path = os.path.join(work, "verity-%s.its" % slot)
        fit = os.path.join(work, "fitImage-%s" % slot)
        with open(its_path, "w", encoding="ascii") as stream:
            stream.write(its)
        subprocess.run([d.getVar("UBOOT_MKIMAGE"), "-f", its_path, "-k", keydir, "-r", fit],
                       check=True)
        listing = subprocess.run([d.getVar("UBOOT_MKIMAGE"), "-l", fit], check=True,
                                 capture_output=True, text=True).stdout
        if "Sign value" not in listing:
            bb.fatal("Slot %s FIT carries no signature value; refusing to deploy it." % slot)
        shutil.copyfile(fit, os.path.join(image_deploy, output_name))
        bb.note("slot %s: root hash %s -> %s" % (slot, params["VERITY_ROOT_HASH"], output_name))
}

addtask image_verity_fit after do_image_verity before do_image_wic do_image_complete

# selinux-image drops /.autorelabel into the rootfs when build-time labelling
# fails (a warning only). Under dm-verity that is the endless relabel-and-reboot
# loop described above, so stop before the ext4 image is made from the rootfs.
python iotgw_verity_no_autorelabel() {
    import os
    if os.path.exists(os.path.join(d.getVar('IMAGE_ROOTFS'), '.autorelabel')):
        bb.fatal("The rootfs carries /.autorelabel (build-time SELinux labelling failed; "
                 "see the selinux_set_labels warning). On the read-only dm-verity root "
                 "selinux-autorelabel could never remove it and would reboot forever.")
}
do_image_ext4[prefuncs] += "iotgw_verity_no_autorelabel"
