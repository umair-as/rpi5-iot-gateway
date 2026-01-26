#!/bin/sh
#
# OTBR Container Entrypoint Script
# Starts OpenThread Border Router services
#

set -e

# Configuration
OTBR_INFRA_IF="${OTBR_INFRA_IF:-eth0}"
OTBR_RCP_BUS="${OTBR_RCP_BUS:-ttyACM0}"
OTBR_LOG_LEVEL="${OTBR_LOG_LEVEL:-info}"

echo "========================================="
echo "  OpenThread Border Router (OTBR)"
echo "  Platform: Raspberry Pi 5"
echo "========================================="
echo ""
echo "Configuration:"
echo "  Infrastructure Interface: ${OTBR_INFRA_IF}"
echo "  RCP Serial Device: /dev/${OTBR_RCP_BUS}"
echo "  Log Level: ${OTBR_LOG_LEVEL}"
echo ""

# Check if RCP device exists
if [ ! -e "/dev/${OTBR_RCP_BUS}" ]; then
    echo "ERROR: RCP device /dev/${OTBR_RCP_BUS} not found!"
    echo "Make sure to run container with: --device=/dev/${OTBR_RCP_BUS}"
    exit 1
fi

# Check if infrastructure interface exists
# Check infra interface if 'ip' is available; otherwise skip check
if command -v ip >/dev/null 2>&1; then
    if ! ip link show "${OTBR_INFRA_IF}" >/dev/null 2>&1; then
        echo "WARNING: Infrastructure interface ${OTBR_INFRA_IF} not found!"
        echo "Container may not have network access."
    fi
fi

# Start Avahi daemon (mDNS)
echo "Starting Avahi mDNS daemon..."
avahi-daemon --daemonize --no-chroot || {
    echo "WARNING: Failed to start Avahi daemon"
}

# Give Avahi time to start
sleep 2

# Start OTBR Agent
echo "Starting OTBR Agent..."
echo "  Command: otbr-agent -I wpan0 -d${OTBR_LOG_LEVEL} spinel+hdlc+uart:///dev/${OTBR_RCP_BUS}"
/usr/sbin/otbr-agent \
    -I wpan0 \
    -d"${OTBR_LOG_LEVEL}" \
    "spinel+hdlc+uart:///dev/${OTBR_RCP_BUS}" &

OTBR_AGENT_PID=$!

# Give OTBR agent time to start
sleep 3

OTBR_WEB_PID=""
if command -v otbr-web >/dev/null 2>&1; then
    echo "Starting OTBR Web Interface..."
    echo "  Listening on: http://0.0.0.0:80"
    /usr/sbin/otbr-web &
    OTBR_WEB_PID=$!
else
    echo "OTBR Web disabled or not present; skipping web UI startup."
fi

echo ""
echo "========================================="
echo "  OTBR Services Started Successfully"
echo "========================================="
echo "  OTBR Agent PID: ${OTBR_AGENT_PID}"
if [ -n "${OTBR_WEB_PID}" ]; then
  echo "  OTBR Web PID: ${OTBR_WEB_PID}"
fi
echo ""
echo "  Web Interface: http://<host-ip>:80"
echo "  Thread Network: wpan0"
echo ""
echo "Container is running. Press Ctrl+C to stop."
echo "========================================="

# Function to handle shutdown
shutdown() {
    echo ""
    echo "Shutting down OTBR services..."
    if [ -n "${OTBR_WEB_PID}" ]; then
      kill -TERM "${OTBR_WEB_PID}" 2>/dev/null || true
    fi
    kill -TERM "${OTBR_AGENT_PID}" 2>/dev/null || true
    if command -v pgrep >/dev/null 2>&1; then
        kill -TERM "$(pgrep avahi-daemon)" 2>/dev/null || true
    fi
    echo "OTBR stopped."
    exit 0
}

# Trap signals
trap shutdown SIGTERM SIGINT

# Wait for processes (keeps container running)
wait "${OTBR_AGENT_PID}" "${OTBR_WEB_PID}"
