SUMMARY = "TPM 2.0 operations CLI for Infineon SLB9672"
DESCRIPTION = "Rust CLI tool for TPM info, TRNG, PCR reads, hashing, and signing via tss-esapi"
HOMEPAGE = "https://github.com/umair-as/tpm-ops"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=bf72105a69d303b78352c6a39239bc69"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Fetch by pinned SRCREV without enforcing branch containment checks.
# Cargo.lock is shipped here because upstream does not commit one; OE-Core
# cargo builds offline (--frozen) and needs it. The crate:// dependencies it
# pins are vendored via tpm-ops-crates.inc (regenerate with
# `bitbake -c update_crates tpm-ops` after any dependency bump).
SRC_URI = "git://github.com/umair-as/tpm-ops.git;protocol=https;nobranch=1 \
           file://Cargo.lock"

require tpm-ops-crates.inc

inherit cargo pkgconfig

# tss-esapi-sys links against libtss2 via pkg-config. `inherit pkgconfig`
# provides pkg-config in the native sysroot (its build.rs invokes it through
# the Rust pkg-config crate); PKG_CONFIG_ALLOW_CROSS lets that crate resolve
# the target tss2-sys.pc during cross-compilation.
DEPENDS = "tpm2-tss"
export PKG_CONFIG_ALLOW_CROSS = "1"
RDEPENDS:${PN} = "libtss2 libtss2-tcti-device"

CARGO_BUILD_PROFILE = "release"
CARGO_INSTALL_DIR = "${D}${bindir}"
# Upstream Cargo.toml may set strip=true; disable to satisfy Yocto QA/debug split.
export CARGO_PROFILE_RELEASE_STRIP = "false"

# The fetched source has no Cargo.lock; place the shipped one where cargo_common
# expects it (CARGO_LOCK_PATH) before the frozen build reads it.
do_configure:prepend() {
    install -D -m 0644 ${UNPACKDIR}/Cargo.lock ${CARGO_LOCK_PATH}
}

FILES:${PN} += "${bindir}/tpm-ops"
