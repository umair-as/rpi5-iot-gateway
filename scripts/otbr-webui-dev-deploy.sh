#!/usr/bin/env bash
set -euo pipefail

TARGET="${TARGET:-iotgw}"
LOCAL_WEBUI_DIR="${LOCAL_WEBUI_DIR:-$HOME/GitRepos/otbr-webui}"
REMOTE_ROOT="${REMOTE_ROOT:-/data/otbr-webui}"
APPLY_PERSISTENT=1
RESTART_SERVICE=1

usage() {
    cat <<'EOF'
Usage: scripts/otbr-webui-dev-deploy.sh [options]

Push local otbr-webui dist artifacts to target /data and switch otbr-webui.service
to run from /data for fast iteration.

Options:
  -t, --target <host>       SSH target (default: iotgw or $TARGET)
  -s, --source <dir>        Local otbr-webui checkout (default: ~/GitRepos/otbr-webui)
  -r, --remote-root <dir>   Remote root path (default: /data/otbr-webui)
      --no-persistent       Skip persistent drop-in under /data/overlays (runtime only)
      --no-restart          Do not restart service after deploy
  -h, --help                Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -t|--target)
            TARGET="$2"
            shift 2
            ;;
        -s|--source)
            LOCAL_WEBUI_DIR="$2"
            shift 2
            ;;
        -r|--remote-root)
            REMOTE_ROOT="$2"
            shift 2
            ;;
        --no-persistent)
            APPLY_PERSISTENT=0
            shift
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

DIST_SERVER="${LOCAL_WEBUI_DIR}/dist/server"
DIST_CLIENT="${LOCAL_WEBUI_DIR}/dist/client"

if [ ! -d "${DIST_SERVER}" ] || [ ! -d "${DIST_CLIENT}" ]; then
    echo "Missing build artifacts under ${LOCAL_WEBUI_DIR}/dist. Run: npm run build" >&2
    exit 1
fi

echo "[deploy] target=${TARGET}"
echo "[deploy] source=${LOCAL_WEBUI_DIR}"
echo "[deploy] remote_root=${REMOTE_ROOT}"

ssh "${TARGET}" "mkdir -p '${REMOTE_ROOT}/dist/server' '${REMOTE_ROOT}/dist/client'"

# Sync only the build output; node_modules stays on image and is linked below.
if command -v rsync >/dev/null 2>&1; then
    rsync -az --delete -e ssh "${DIST_SERVER}/" "${TARGET}:${REMOTE_ROOT}/dist/server/"
    rsync -az --delete -e ssh "${DIST_CLIENT}/" "${TARGET}:${REMOTE_ROOT}/dist/client/"
else
    scp -r "${DIST_SERVER}/." "${TARGET}:${REMOTE_ROOT}/dist/server/"
    scp -r "${DIST_CLIENT}/." "${TARGET}:${REMOTE_ROOT}/dist/client/"
fi

OVERRIDE_CONTENT=$(cat <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/node ${REMOTE_ROOT}/dist/server/index.js
EnvironmentFile=
UnsetEnvironment=STATIC_DIR
Environment=PORT=80
Environment=HOST=0.0.0.0
Environment=OTBR_AGENT_URL=http://localhost:8081
Environment=STATIC_DIR=${REMOTE_ROOT}/dist/client
Environment=OT_CTL_PATH=/usr/sbin/ot-ctl
EOF
)

# Runtime drop-in for immediate effect.
printf '%s\n' "${OVERRIDE_CONTENT}" | ssh "${TARGET}" \
    "mkdir -p /run/systemd/system/otbr-webui.service.d && cat > /run/systemd/system/otbr-webui.service.d/override.conf"

if [ "${APPLY_PERSISTENT}" -eq 1 ]; then
    # Persistent drop-in in overlay upperdir; takes effect after reboot.
    printf '%s\n' "${OVERRIDE_CONTENT}" | ssh "${TARGET}" \
        "mkdir -p /data/overlays/etc/upper/systemd/system/otbr-webui.service.d && cat > /data/overlays/etc/upper/systemd/system/otbr-webui.service.d/override.conf"
fi

# ESM resolution from /data path needs node_modules in or above that tree.
ssh "${TARGET}" "ln -sfn /usr/share/otbr-webui/node_modules '${REMOTE_ROOT}/node_modules'"

if [ "${RESTART_SERVICE}" -eq 1 ]; then
    ssh "${TARGET}" "systemctl daemon-reload && systemctl restart otbr-webui"
    ssh "${TARGET}" "systemctl --no-pager status otbr-webui.service -l"
    ssh "${TARGET}" "MAINPID=\$(systemctl show -p MainPID --value otbr-webui); tr '\0' '\n' < /proc/\${MAINPID}/environ | grep -E '^(STATIC_DIR|PORT|HOST|OTBR_AGENT_URL|OT_CTL_PATH)='"
    ssh "${TARGET}" "curl -fsS -o /dev/null http://127.0.0.1:80/ && echo '[verify] http://127.0.0.1:80 ok'"
    ssh "${TARGET}" "curl -fsS -o /dev/null http://127.0.0.1:80/api/node && echo '[verify] http://127.0.0.1:80/api/node ok'"
fi

echo "[deploy] completed"
if [ "${APPLY_PERSISTENT}" -eq 1 ]; then
    echo "[note] persistent override written to /data/overlays/... and will be visible after reboot"
fi
