#!/usr/bin/env bash
set -euo pipefail

TARGET="${TARGET:-iotgw}"
REMOTE_ROOT="${REMOTE_ROOT:-/data/otbr-webui}"
RESTART_SERVICE=1

usage() {
    cat <<'EOF'
Usage: scripts/otbr-webui-dev-rollback.sh [options]

Rollback otbr-webui dev override and return to packaged artifacts under
/usr/share/otbr-webui.

Options:
  -t, --target <host>       SSH target (default: iotgw or $TARGET)
  -r, --remote-root <dir>   Remote dev root path (default: /data/otbr-webui)
      --no-restart          Do not restart service
  -h, --help                Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -t|--target)
            TARGET="$2"
            shift 2
            ;;
        -r|--remote-root)
            REMOTE_ROOT="$2"
            shift 2
            ;;
        --no-restart)
            RESTART_SERVICE=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 2
            ;;
    esac
done

echo "[rollback] target=${TARGET}"
echo "[rollback] remote_root=${REMOTE_ROOT}"

ssh "${TARGET}" "rm -f /run/systemd/system/otbr-webui.service.d/override.conf"
ssh "${TARGET}" "rmdir /run/systemd/system/otbr-webui.service.d 2>/dev/null || true"

ssh "${TARGET}" "rm -f /data/overlays/etc/upper/systemd/system/otbr-webui.service.d/override.conf"
ssh "${TARGET}" "rmdir /data/overlays/etc/upper/systemd/system/otbr-webui.service.d 2>/dev/null || true"

# Optional cleanup of dev workspace. Keep user data conservative: remove symlink only.
ssh "${TARGET}" "if [ -L '${REMOTE_ROOT}/node_modules' ]; then rm -f '${REMOTE_ROOT}/node_modules'; fi"

if [ "${RESTART_SERVICE}" -eq 1 ]; then
    ssh "${TARGET}" "systemctl daemon-reload && systemctl restart otbr-webui"
    ssh "${TARGET}" "systemctl --no-pager status otbr-webui.service -l"
    ssh "${TARGET}" "systemctl cat otbr-webui.service | sed -n '1,160p'"
    ssh "${TARGET}" "curl -fsS -o /dev/null http://127.0.0.1:80/ && echo '[verify] http://127.0.0.1:80 ok'"
    ssh "${TARGET}" "curl -fsS -o /dev/null http://127.0.0.1:80/api/node && echo '[verify] http://127.0.0.1:80/api/node ok'"
fi

echo "[rollback] completed"
