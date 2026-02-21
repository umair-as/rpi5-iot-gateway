#!/usr/bin/env bash
set -euo pipefail

HOST="${1:-iotgw}"
DEST="${2:-/data/otbr-test}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RPM_DIR="${ROOT_DIR}/build/tmp-glibc/deploy/rpm/cortexa76"

RPM_CLIENT="$(ls -1 "${RPM_DIR}"/iotgw-otbrctl-*.rpm | head -n 1)"
RPM_LIB="$(ls -1 "${RPM_DIR}"/libsdbus-c++2-*.rpm | head -n 1)"

RPM2CPIO="${ROOT_DIR}/build/tmp-glibc/sysroots-components/x86_64/rpm-native/usr/bin/rpm2cpio"
RPM2CPIO_LIBDIR="${ROOT_DIR}/build/tmp-glibc/sysroots-components/x86_64/rpm-native/usr/lib"
BZ2_LIBDIR="${ROOT_DIR}/build/tmp-glibc/sysroots-components/x86_64/bzip2-native/usr/lib"

if [[ ! -x "${RPM2CPIO}" ]]; then
  echo "rpm2cpio not found: ${RPM2CPIO}"
  exit 1
fi

if [[ ! -f "${RPM_CLIENT}" || ! -f "${RPM_LIB}" ]]; then
  echo "Missing RPMs in ${RPM_DIR}"
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "Extracting RPMs..."
LD_LIBRARY_PATH="${RPM2CPIO_LIBDIR}:${BZ2_LIBDIR}" \
  "${RPM2CPIO}" "${RPM_LIB}" | cpio -idmv -D "${WORK_DIR}" >/dev/null
LD_LIBRARY_PATH="${RPM2CPIO_LIBDIR}:${BZ2_LIBDIR}" \
  "${RPM2CPIO}" "${RPM_CLIENT}" | cpio -idmv -D "${WORK_DIR}" >/dev/null

echo "Copying to ${HOST}:${DEST}"
ssh "root@${HOST}" "mkdir -p ${DEST}"
scp -r "${WORK_DIR}/usr" "root@${HOST}:${DEST}/"

cat <<EOF
Done.
On target:
  export LD_LIBRARY_PATH=${DEST}/usr/lib
  ${DEST}/usr/bin/iotgw-otbrctl scan
EOF
