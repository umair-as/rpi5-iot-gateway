SUMMARY = "IoT Gateway TUI Banner Generator (Rust/ratatui)"
DESCRIPTION = "Professional TUI banner generator with real-time system information using Rust, ratatui, and crossterm"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://Cargo.toml \
    file://src/main.rs \
"

S = "${WORKDIR}"

inherit cargo_bin systemd

# Pass distro variables as environment variables at compile time
DISTRO_NAME ??= "IoT Gateway OS"
DISTRO_VERSION ??= "1.0.0"

# Set environment variables for the build
export DISTRO_NAME
export DISTRO_VERSION
export MACHINE

# Cargo build configuration
CARGO_BUILD_PROFILE = "release"
CARGO_INSTALL_DIR = "${D}${bindir}"
do_compile[network] = "1"
# Ensure binaries are not pre-stripped; Yocto handles debug split/strip.
export CARGO_PROFILE_RELEASE_STRIP = "false"

FILES:${PN} += "${bindir}/iotgw-banner-tui"

# Runtime dependencies
RDEPENDS:${PN} = "rauc"

# Note: First build will take 30+ minutes to compile Rust and dependencies
# Subsequent builds will be much faster due to cargo caching
