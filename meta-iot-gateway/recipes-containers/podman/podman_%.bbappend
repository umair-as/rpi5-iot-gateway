# CVE_STATUS — narrowly-evidenced VEX for sbom-cve-check matches.
#
# CVE-2019-10152 (podman cp path traversal, fixed 1.4.0) and CVE-2020-1726
# (volume copy-up, fixed 1.8.1 by commit c140ecdc9b41): both fixes are
# ancestors of the shipped SRCREV.
CVE_STATUS[CVE-2019-10152] = "fixed-version: fixed in 1.4.0"
CVE_STATUS[CVE-2020-1726] = "fixed-version: fixed in 1.8.1 (commit c140ecdc9b41)"
#
# CVE-2022-2738 / CVE-2022-2739: the CVE records describe a Red Hat packaging
# regression: the podman 1.6.4-32.el7_9 RPM shipped in RHEL 7 Extras was
# built without the fixes for CVE-2020-8945 and CVE-2020-14370. The only
# affected version listed is that RPM; Debian classifies both as NOT-FOR-US
# ("Red Hat specific release error"). This recipe builds upstream podman 5.x
# from git; the underlying gpgme-wrapper issue (CVE-2020-8945) is fixed in
# the vendored github.com/proglottis/gpgme v0.1.5.
#   https://www.cve.org/CVERecord?id=CVE-2022-2738
#   https://www.cve.org/CVERecord?id=CVE-2022-2739
CVE_STATUS[CVE-2022-2738] = "not-applicable-platform: RHEL 7 Extras podman 1.6.4-32.el7_9 packaging regression only"
CVE_STATUS[CVE-2022-2739] = "not-applicable-platform: RHEL 7 Extras podman 1.6.4-32.el7_9 packaging regression only"

# Containers run rootless as the iotgw-ctr principal from its user manager
# (iotgw-ctr-user); the rootful engine stays installed for administration
# from a root shell but no unit starts it: neither the system podman.socket
# API nor the per-user units (the recipe's SYSTEMD_SERVICE covers both, and
# an explicit enable is not undone by a preset).
SYSTEMD_AUTO_ENABLE:${PN} = "disable"

# No docker compatibility shim: the `docker` wrapper script, its profile.d
# aliases and the user-tmpfiles entry that links a docker.sock into every
# user's runtime directory serve interactive use only, and the tmpfiles entry
# runs in every user manager, the container principal's included.
PODMAN_FEATURES = ""

# podman's own install target leaves the default seccomp profile in the
# source tree; ship it so the syscall allowlist can be read on the device
# (containers.conf seccomp_profile). Without the file podman applies the same
# profile from its binary, so this changes what is auditable, not what runs.
do_install:append() {
    profile=""
    for p in vendor/go.podman.io/common/pkg/seccomp/seccomp.json \
             vendor/github.com/containers/common/pkg/seccomp/seccomp.json; do
        if [ -f ${S}/src/import/$p ]; then
            profile=${S}/src/import/$p
            break
        fi
    done
    if [ -z "$profile" ]; then
        bbfatal "default seccomp profile not found in the podman source tree"
    fi
    install -d ${D}${datadir}/containers
    install -m 0644 $profile ${D}${datadir}/containers/seccomp.json
}

FILES:${PN} += "${datadir}/containers/seccomp.json"
