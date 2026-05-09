#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/release-manifest.sh --tag vX.Y.Z --version X.Y.Z --build-id ID [--outdir release/vX.Y.Z]
EOF
}

tag=""
version=""
build_id=""
outdir=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag) tag="${2:-}"; shift 2 ;;
        --version) version="${2:-}"; shift 2 ;;
        --build-id) build_id="${2:-}"; shift 2 ;;
        --outdir) outdir="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ -z "$tag" || -z "$version" || -z "$build_id" ]]; then
    echo "error: --tag, --version, --build-id are required" >&2
    usage
    exit 1
fi

if [[ -z "$outdir" ]]; then
    outdir="release/${tag}"
fi

mkdir -p "$outdir"

manifest="${outdir}/manifest.txt"
checksums="${outdir}/checksums.sha256"

if [[ -z "$(git status --porcelain)" ]]; then
    git_status_clean=yes
else
    git_status_clean=no
fi

kas_files=""
for f in kas/*.yml; do
    [[ -f "$f" ]] && kas_files+="$(basename "$f") "
done
distro_version_default="$(grep -nE 'IOTGW_VERSION_(MAJOR|MINOR|PATCH) \?=' meta-iot-gateway/conf/distro/include/iotgw-common.inc | tr '\n' ';')"

{
    echo "release_tag=${tag}"
    echo "release_version=${version}"
    echo "build_id=${build_id}"
    echo "generated_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "git_commit=$(git rev-parse HEAD)"
    echo "git_commit_short=$(git rev-parse --short HEAD)"
    echo "git_branch=$(git branch --show-current)"
    echo "git_status_clean=${git_status_clean}"
    echo "kas_files=${kas_files}"
    echo "distro_version_default=${distro_version_default}"
} > "$manifest"

# Checksums of common deploy artifacts when present.
tmp_list="$(mktemp)"
find build/tmp/deploy -type f \( \
    -name "*.raucb" -o \
    -name "*.wic" -o \
    -name "*.wic.bz2" -o \
    -name "fitImage*" -o \
    -name "u-boot.bin" -o \
    -name "Image" -o \
    -name "kernel_2712.img" \
    \) -print0 2>/dev/null | sort -z > "$tmp_list" || true

if [[ -s "$tmp_list" ]]; then
    xargs -0 sha256sum < "$tmp_list" > "$checksums"
else
    : > "$checksums"
fi

rm -f "$tmp_list"

echo "[release-manifest] wrote ${manifest}"
echo "[release-manifest] wrote ${checksums}"
