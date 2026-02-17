#!/bin/bash
#
# OpenThread Border Router D-Bus Wrapper Script
# Provides convenient functions to interact with otbr-agent via D-Bus
#

# D-Bus configuration constants
readonly DBUS_SERVICE="io.openthread.BorderRouter.wpan0"
readonly DBUS_OBJECT="/io/openthread/BorderRouter/wpan0"
readonly DBUS_INTERFACE="io.openthread.BorderRouter"
readonly DBUS_PROPERTIES_INTERFACE="org.freedesktop.DBus.Properties"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Utility functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if otbr-agent service is running
check_service() {
    if ! systemctl is-active --quiet otbr-agent; then
        log_error "otbr-agent service is not running"
        return 1
    fi

    if ! busctl list | grep -q "$DBUS_SERVICE"; then
        log_error "D-Bus service $DBUS_SERVICE not found"
        return 1
    fi

    log_info "otbr-agent service is running"
    return 0
}

# Introspect the D-Bus interface
dbus_introspect() {
    log_info "Introspecting D-Bus interface..."
    dbus-send --system --dest="$DBUS_SERVICE" --print-reply \
        "$DBUS_OBJECT" \
        org.freedesktop.DBus.Introspectable.Introspect
}

# List available properties on the OTBR interface
list_properties() {
    log_info "Listing properties for $DBUS_INTERFACE..."
    dbus-send --system --dest="$DBUS_SERVICE" --print-reply \
        "$DBUS_OBJECT" \
        "$DBUS_PROPERTIES_INTERFACE".GetAll \
        string:"$DBUS_INTERFACE" \
        | awk '/string ".*"/ {gsub(/.*string "/,""); gsub(/".*/,""); print}' \
        | sort -u
}

# Get a specific property
# Usage: get_property <property_name>
get_property() {
    local property="$1"
    if [ -z "$property" ]; then
        log_error "Property name required"
        return 1
    fi

    log_info "Getting property: $property"
    dbus-send --system --dest="$DBUS_SERVICE" --print-reply \
        "$DBUS_OBJECT" \
        "$DBUS_PROPERTIES_INTERFACE".Get \
        string:"$DBUS_INTERFACE" string:"$property"
}

# Get multiple properties using GetProperties method
# Usage: get_properties <property1,property2,...>
get_properties() {
    local properties="$1"
    if [ -z "$properties" ]; then
        log_error "Properties list required"
        return 1
    fi

    log_info "Getting properties: $properties"
    dbus-send --system --dest="$DBUS_SERVICE" --print-reply \
        "$DBUS_OBJECT" \
        "$DBUS_INTERFACE".GetProperties \
        "array:string:$properties"
}

# Set a property (for writable properties)
# Usage: set_property <property_name> <value> <type>
set_property() {
    local property="$1"
    local value="$2"
    local type="${3:-s}"

    if [ -z "$property" ] || [ -z "$value" ]; then
        log_error "Property name and value required"
        return 1
    fi

    log_info "Setting property $property to $value"
    dbus-send --system --dest="$DBUS_SERVICE" --print-reply \
        "$DBUS_OBJECT" \
        "$DBUS_PROPERTIES_INTERFACE".Set \
        string:"$DBUS_INTERFACE" string:"$property" \
        variant:"$type:$value"
}

# Call a D-Bus method
# Usage: call_method <method_name> [args...]
call_method() {
    local method="$1"
    shift
    local args=("$@")

    if [ -z "$method" ]; then
        log_error "Method name required"
        return 1
    fi

    log_info "Calling method: $method"
    dbus-send --system --dest="$DBUS_SERVICE" --print-reply \
        "$DBUS_OBJECT" \
        "$DBUS_INTERFACE"."$method" "${args[@]}"
}

# Common property getters
get_device_role() {
    get_property "DeviceRole"
}

get_network_name() {
    get_property "NetworkName"
}

get_channel() {
    get_property "Channel"
}

get_pan_id() {
    get_property "PanId"
}

get_ext_pan_id() {
    get_property "ExtPanId"
}

get_otbr_version() {
    get_property "OtbrVersion"
}

get_thread_version() {
    get_property "ThreadVersion"
}

get_eui64() {
    get_property "Eui64"
}

get_radio_spinel_metrics() {
    get_property "RadioSpinelMetrics"
}

get_rcp_interface_metrics() {
    get_property "RcpInterfaceMetrics"
}

# Network operations
scan_networks() {
    log_info "Scanning for Thread networks..."
    call_method "Scan"
}

energy_scan() {
    local duration="${1:-1000}"  # Default 1 second
    log_info "Performing energy scan (duration: ${duration}ms)..."
    call_method "EnergyScan" "uint32:$duration"
}

attach_to_network() {
    local networkkey="$1"
    local panid="$2"
    local networkname="$3"
    local extpanid="$4"
    local pskc="$5"
    local channel_mask="$6"

    log_info "Attaching to network: $networkname"
    call_method "Attach" \
        "array:byte:$networkkey" \
        "uint16:$panid" \
        "string:$networkname" \
        "uint64:$extpanid" \
        "array:byte:$pskc" \
        "uint32:$channel_mask"
}

detach_from_network() {
    log_info "Detaching from network..."
    call_method "Detach"
}

factory_reset() {
    log_warn "Performing factory reset..."
    call_method "FactoryReset"
}

# Border Agent operations
permit_unsecure_join() {
    local port="${1:-0}"      # Default any port
    local timeout="${2:-60}"   # Default 60 seconds

    log_info "Permitting unsecure join (port: $port, timeout: ${timeout}s)..."
    call_method "PermitUnsecureJoin" "uint16:$port" "uint32:$timeout"
}

# Show common status information
show_status() {
    echo "=== OpenThread Border Router Status ==="
    echo
    echo "Service Status:"
    check_service
    echo

    echo "Basic Information:"
    echo "  Device Role: $(get_device_role | grep -o '"[^"]*"' | tr -d '"')"
    echo "  Network Name: $(get_network_name | grep -o '"[^"]*"' | tr -d '"')"
    echo "  Channel: $(get_channel | grep -o 'uint16 [0-9]*' | cut -d' ' -f2)"
    echo "  PAN ID: $(get_pan_id | grep -o 'uint16 [0-9]*' | cut -d' ' -f2)"
    echo "  Ext PAN ID: $(get_ext_pan_id | grep -o 'uint64 [0-9]*' | cut -d' ' -f2)"
    echo

    echo "Version Information:"
    echo "  OTBR Version: $(get_otbr_version | grep -o '"[^"]*"' | tr -d '"')"
    echo "  Thread Version: $(get_thread_version | grep -o 'uint16 [0-9]*' | cut -d' ' -f2)"
    echo

    echo "Interface Information:"
    echo "  EUI-64: $(get_eui64 | grep -o 'uint64 [0-9]*' | cut -d' ' -f2)"
    echo
}

# Show help
show_help() {
    cat << EOF
OpenThread Border Router D-Bus Wrapper Script

Usage: $0 [COMMAND] [OPTIONS]

Commands:
    check                    Check if otbr-agent service is running
    introspect               Introspect D-Bus interface
    list-properties          List available OTBR properties
    status                   Show common status information

    Property Operations:
    get <property>           Get a specific property
    get-properties <list>    Get multiple properties (comma-separated)
    set <property> <value>   Set a property value

    Common Properties:
    device-role              Get device role
    network-name             Get network name
    channel                  Get channel
    pan-id                   Get PAN ID
    ext-pan-id               Get extended PAN ID
    otbr-version             Get OTBR version
    thread-version           Get Thread version
    eui64                    Get EUI-64
    radio-spinel-metrics     Get radio spinel metrics
    rcp-interface-metrics    Get RCP interface metrics

    Network Operations:
    scan                     Scan for Thread networks
    energy-scan [duration]   Perform energy scan (default 1000ms)
    attach <args>            Attach to network (see below)
    detach                   Detach from network
    factory-reset            Perform factory reset

    Border Agent:
    permit-join [port] [timeout]  Permit unsecure join

Examples:
    $0 status                           # Show status
    $0 get DeviceRole                   # Get device role
    $0 get-properties "DeviceRole,Channel"  # Get multiple properties
    $0 scan                            # Scan for networks
    $0 permit-join 0 60                # Permit join for 60s

Note: Some properties like ChannelMonitorAllChannelQualities may return
      'NotFound' errors due to disabled features in the build.
EOF
}

# Main script logic
main() {
    case "${1:-help}" in
        check)
            check_service
            ;;
        introspect)
            dbus_introspect
            ;;
        list-properties)
            list_properties
            ;;
        status)
            show_status
            ;;
        get)
            get_property "$2"
            ;;
        get-properties)
            get_properties "$2"
            ;;
        set)
            set_property "$2" "$3" "$4"
            ;;
        device-role)
            get_device_role
            ;;
        network-name)
            get_network_name
            ;;
        channel)
            get_channel
            ;;
        pan-id)
            get_pan_id
            ;;
        ext-pan-id)
            get_ext_pan_id
            ;;
        otbr-version)
            get_otbr_version
            ;;
        thread-version)
            get_thread_version
            ;;
        eui64)
            get_eui64
            ;;
        radio-spinel-metrics)
            get_radio_spinel_metrics
            ;;
        rcp-interface-metrics)
            get_rcp_interface_metrics
            ;;
        scan)
            scan_networks
            ;;
        energy-scan)
            energy_scan "$2"
            ;;
        attach)
            attach_to_network "$2" "$3" "$4" "$5" "$6" "$7"
            ;;
        detach)
            detach_from_network
            ;;
        factory-reset)
            factory_reset
            ;;
        permit-join)
            permit_unsecure_join "$2" "$3"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $1"
            show_help
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
