SUMMARY = "IoT Gateway TUI Banner Generator (Rust/ratatui)"
DESCRIPTION = "Professional TUI banner generator with real-time system information using Rust, ratatui, and crossterm"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://Cargo.toml \
    file://src/main.rs \
"

S = "${WORKDIR}"

inherit cargo systemd

# Pass distro variables as environment variables at compile time
DISTRO_NAME ??= "IoT Gateway OS"
DISTRO_VERSION ??= "1.0.0"

# Set environment variables for the build
export DISTRO_NAME
export DISTRO_VERSION
export MACHINE

# Cargo build configuration
CARGO_BUILD_FLAGS = "--release"

do_compile() {
    # Build the Rust project
    cargo build ${CARGO_BUILD_FLAGS}
}

do_install() {
    # Install the binary
    install -d ${D}${bindir}
    install -m 0755 ${B}/target/${RUST_TARGET_SYS}/release/iotgw-banner-tui ${D}${bindir}/iotgw-banner-tui

    # Optionally install systemd service for auto-display at boot
    # (commented out by default - enable if you want TUI on every boot)
    # install -d ${D}${systemd_system_unitdir}
    # install -m 0644 ${WORKDIR}/iotgw-banner-tui.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} = "${bindir}/iotgw-banner-tui"

# Runtime dependencies
RDEPENDS:${PN} = "rauc"

# Note: First build will take 30+ minutes to compile Rust and dependencies
# Subsequent builds will be much faster due to cargo caching
