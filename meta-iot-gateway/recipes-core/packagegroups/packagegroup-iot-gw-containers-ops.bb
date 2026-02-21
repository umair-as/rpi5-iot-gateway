SUMMARY = "IoT GW Container operations tools"
DESCRIPTION = "Useful day-2 CLI tools for containerized microservice operations."
LICENSE = "MIT"

inherit packagegroup

PACKAGE_ARCH = "${MACHINE_ARCH}"

RDEPENDS:${PN} = " \
    jq \
    socat \
"
