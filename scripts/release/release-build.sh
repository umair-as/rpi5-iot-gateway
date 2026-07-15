#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/release/release-build.sh --version X.Y.Z --build-id ID [--image dev|prod|base] [--bundle none|full|full-fit]

Examples:
  scripts/release/release-build.sh --version 0.4.0 --build-id 202605091930 --image dev --bundle full-fit
  scripts/release/release-build.sh --version 0.4.0 --build-id 202605091930 --image prod --bundle full
EOF
}

require_clean_tree() {
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "error: working tree must be clean before release build" >&2
        exit 1
    fi
}

version=""
build_id=""
image="dev"
bundle="none"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="${2:-}"; shift 2 ;;
        --build-id) build_id="${2:-}"; shift 2 ;;
        --image) image="${2:-}"; shift 2 ;;
        --bundle) bundle="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ -z "$version" || -z "$build_id" ]]; then
    echo "error: --version and --build-id are required" >&2
    usage
    exit 1
fi

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: --version must be semantic X.Y.Z (got: ${version})" >&2
    exit 1
fi

case "$image" in
    dev|prod|base) ;;
    *) echo "error: invalid --image: $image" >&2; exit 1 ;;
esac

case "$bundle" in
    none|full|full-fit) ;;
    *) echo "error: invalid --bundle: $bundle" >&2; exit 1 ;;
esac

require_clean_tree

export IOTGW_VERSION_MAJOR="${version%%.*}"
rest="${version#*.}"
export IOTGW_VERSION_MINOR="${rest%%.*}"
export IOTGW_VERSION_PATCH="${version##*.}"
export IOTGW_BUILD_ID="$build_id"

echo "[release-build] version=${version} build_id=${build_id} image=${image} bundle=${bundle}"
echo "[release-build] git=$(git rev-parse --short HEAD)"

make_target=""
case "$image" in
    dev) make_target="dev" ;;
    prod) make_target="prod" ;;
    base) make_target="base" ;;
esac

echo "[release-build] building image target: make ${make_target}"
make "${make_target}"

if [[ "$bundle" != "none" ]]; then
    bundle_target=""
    case "$bundle:$image" in
        full:dev) bundle_target="bundle-dev-full-fit" ;;
        full:prod) bundle_target="bundle-prod-full-fit" ;;
        full-fit:dev) bundle_target="bundle-dev-full-fit" ;;
        full-fit:prod) bundle_target="bundle-prod-full-fit" ;;
        *)
            echo "error: unsupported image/bundle combination: image=${image}, bundle=${bundle}" >&2
            exit 1
            ;;
    esac
    echo "[release-build] building bundle target: make ${bundle_target}"
    make "${bundle_target}"
fi

echo "[release-build] completed"
