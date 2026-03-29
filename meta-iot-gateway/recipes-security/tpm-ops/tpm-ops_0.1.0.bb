SUMMARY = "TPM 2.0 operations CLI for Infineon SLB9672"
DESCRIPTION = "Rust CLI tool for TPM info, TRNG, PCR reads, hashing, and signing via tss-esapi"
HOMEPAGE = "https://github.com/umair-as/tpm-ops"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=bf72105a69d303b78352c6a39239bc69"

SRC_URI = "git://github.com/umair-as/tpm-ops.git;protocol=https;branch=main"
SRCREV = "e6fdda8eff836f2e819a3cb6f907ca1d3f4a3793"

S = "${WORKDIR}/git"

inherit cargo_bin

# tss-esapi links against libtss2 via pkg-config
DEPENDS = "tpm2-tss"
RDEPENDS:${PN} = "libtss2 libtss2-tcti-device"

CARGO_BUILD_PROFILE = "release"
CARGO_INSTALL_DIR = "${D}${bindir}"
do_compile[network] = "1"
# Upstream Cargo.toml may set strip=true; disable to satisfy Yocto QA/debug split.
export CARGO_PROFILE_RELEASE_STRIP = "false"

FILES:${PN} += "${bindir}/tpm-ops"
