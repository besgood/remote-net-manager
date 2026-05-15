#!/bin/bash
# Remote Network Manager
# Manages virtual NICs and Guest WiFi while maintaining SSH connectivity.

set -e

# Require Root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (or with sudo) to configure network interfaces."
  exit 1
fi

# Check Dependencies
check_dependencies() {
    local deps=("ip" "nmcli" "iw" "sysctl" "awk" "grep")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo "[!] Missing required dependencies: ${missing[*]}"
        echo "[*] Please install them. For Debian/Kali/Ubuntu:"
        echo "    sudo apt-get update && sudo apt-get install -y iproute2 network-manager iw procps gawk grep"
        exit 1
    fi
}

check_dependencies

# Globals
MAIN_IFACE=""
MAIN_GW=""
WIFI_IFACE=""
WIFI_CONN_NAME="guest_wifi_test"
CONFIRMED=0

trap 'if [ "$CONFIRMED" -eq 0 ] && [ -n "$MAIN_IFACE" ]; then echo -e "[!] Abnormal exit or timeout detected. Cleaning up..."; cleanup; fi' EXIT

log() { echo -e "[*] $1"; }
err() { echo -e "[!] $1" >&2; }

detect_primary_interface() {
    # Detect the interface with the active default route
    MAIN_IFACE=$(ip route show default | grep -Po "(?<=dev )[^ ]+" | head -n 1)
    MAIN_GW=$(ip route show default | grep -Po "(?<=via )[^ ]+" | head -n 1)

    if [ -z "$MAIN_IFACE" ]; then
        err "Could not detect primary interface with default route. Assuming SSH might be at risk. Exiting."
        exit 1
    fi
    log "Detected primary interface: $MAIN_IFACE (Gateway: $MAIN_GW). This interface will be protected."

    # Prevent Accidental Bridging (Disable IP Forwarding)
    log "Disabling IP forwarding to prevent accidental bridging/routing..."
    sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null 2>&1 || true

    # Strict SSH Origin Route Pinning
    if [ -n "$SSH_CONNECTION" ]; then
        SSH_CLIENT_IP=$(echo $SSH_CONNECTION | awk '{print $1}')
        log "Pinning SSH origin route for $SSH_CLIENT_IP via $MAIN_GW dev $MAIN_IFACE..."
        ip route add "$SSH_CLIENT_IP/32" via "$MAIN_GW" dev "$MAIN_IFACE" >/dev/null 2>&1 || true
    else
        log "Warning: SSH_CONNECTION is not set. If connected via SSH, run with 'sudo -E' so origin pinning works."
    fi
}

cleanup() {
    CONFIRMED=1
    log "Starting cleanup mode..."

    # 1. Cleanup VLANs and Routing Rules
    for vlan_iface in $(ip -br link show type vlan 2>/dev/null | awk '{print $1}' | cut -d@ -f1); do
        if [ -n "$vlan_iface" ] && [ "$vlan_iface" != "$MAIN_IFACE" ]; then
            log "Removing VLAN interface: $vlan_iface"
            ip link set dev "$vlan_iface" down 2>/dev/null || true
            ip link delete dev "$vlan_iface" 2>/dev/null || true
        fi
    done
    for rule_pref in $(ip rule show 2>/dev/null | awk '$NF ~ /^[0-9]+$/ && $NF >= 100 && $NF < 32000 {print $1}' | tr -d ':'); do
        ip rule del pref "$rule_pref" 2>/dev/null || true
    done

    # 2. Cleanup Guest WiFi
    if nmcli connection show "$WIFI_CONN_NAME" &>/dev/null; then
        log "Removing Guest WiFi connection profile..."
        nmcli connection delete "$WIFI_CONN_NAME" >/dev/null 2>&1 || true
    fi

    # Ensure default route is restored just in case it was somehow altered
    if ! ip route show default | grep -q "dev $MAIN_IFACE"; then
        log "Restoring default route on $MAIN_IFACE via $MAIN_GW..."
        ip route add default via "$MAIN_GW" dev "$MAIN_IFACE" >/dev/null 2>&1 || true
    fi

    # Remove SSH pinned route
    if [ -n "$SSH_CONNECTION" ]; then
        SSH_CLIENT_IP=$(echo $SSH_CONNECTION | awk '{print $1}')
        ip route del "$SSH_CLIENT_IP/32" via "$MAIN_GW" dev "$MAIN_IFACE" >/dev/null 2>&1 || true
    fi

    log "Cleanup complete."
}

rollback_timer() {
    log "Initiating safety rollback timer (120 seconds)..."
    log "Please confirm the connection is stable and you still have SSH access."

    user_input=""
    read -t 120 -p "Type \"confirm\" to keep settings, or press Enter to rollback: " user_input || true
    echo ""

    if [[ "$user_input" == "confirm" ]]; then
        log "Configuration confirmed by operator. Rollback cancelled."
        CONFIRMED=1
    else
        log "Timeout or operator rollback requested. Reverting network changes..."
        CONFIRMED=1
        cleanup
        exit 1
    fi
}

vlan_mode() {
    detect_primary_interface

    echo "Available physical interfaces:"
    ip -br link show | awk '$2 != "DOWN" && $1 != "lo" {print $1}'

    read -p "Enter base interface for VLANs (e.g., eth0): " base_iface
    if [ "$base_iface" == "$MAIN_IFACE" ]; then
        log "Warning: You are adding VLANs to the primary SSH interface. Routing will not be touched."
    fi

    read -p "Enter VLAN IDs to create (comma-separated, e.g., 10,20,30): " vlan_ids

    IFS="," read -ra ADDR <<< "$vlan_ids"
    for vlan in "${ADDR[@]}"; do
        vlan=$(echo "$vlan" | xargs) # trim whitespace
        if [ -z "$vlan" ]; then continue; fi

        if ! [[ "$vlan" =~ ^[0-9]+$ ]] || [ "$vlan" -lt 1 ] || [ "$vlan" -gt 4094 ]; then
            err "Invalid VLAN ID: $vlan"
            continue
        fi

        read -p "Enter static IP/CIDR for VLAN $vlan (e.g., 192.168.10.5/24): " ip_cidr
        read -p "Enter custom MAC address for VLAN $vlan (leave blank to inherit primary MAC): " custom_mac

        vlan_iface="${base_iface}.${vlan}"
        log "Creating VLAN interface $vlan_iface..."
        ip link add link "$base_iface" name "$vlan_iface" type vlan id "$vlan"

        if [ -n "$custom_mac" ]; then
            log "Assigning custom MAC address $custom_mac to $vlan_iface..."
            ip link set dev "$vlan_iface" address "$custom_mac"
        fi

        if [ -n "$ip_cidr" ]; then
            log "Assigning IP $ip_cidr to $vlan_iface..."
            ip addr add "$ip_cidr" dev "$vlan_iface"
        fi

        log "Bringing up $vlan_iface..."
        ip link set dev "$vlan_iface" up

        if [ -n "$ip_cidr" ]; then
            read -p "Enter VLAN Gateway IP (optional, for Source-Based Routing to CDE): " vlan_gw
            if [ -n "$vlan_gw" ]; then
                vlan_ip=$(echo "$ip_cidr" | cut -d/ -f1)
                table_id=$((vlan + 100)) # Unique table ID based on VLAN
                log "Configuring Source-Based Routing for $vlan_ip via $vlan_gw (Table $table_id)..."
                ip route add default via "$vlan_gw" dev "$vlan_iface" table "$table_id" || err "Failed to add route to table $table_id."
                ip rule add from "$vlan_ip" lookup "$table_id" || err "Failed to add ip rule."
                log "Routing configured. Any traffic originating from $vlan_ip will be forced through $vlan_iface."
            fi
        fi
    done

    log "VLAN setup complete."
    rollback_timer
}

wifi_mode() {
    detect_primary_interface

    WIFI_IFACE=$(iw dev | awk '$1=="Interface"{print $2}' | head -n 1)
    if [ -z "$WIFI_IFACE" ]; then
        err "No WiFi interface detected. Make sure the wireless adapter is connected."
        exit 1
    fi
    log "Using WiFi interface: $WIFI_IFACE"

    # Ensure WiFi interface is up
    ip link set dev "$WIFI_IFACE" up || true

    read -p "Do you want to scan for SSIDs? (y/n): " do_scan
    if [[ "$do_scan" =~ ^[Yy]$ ]]; then
        log "Scanning for networks (this may take a few seconds)..."
        nmcli device wifi list ifname "$WIFI_IFACE"
    fi

    read -p "Enter target SSID (or manual/hidden SSID): " ssid
    read -s -p "Enter WiFi password (leave blank for open): " password
    echo ""

    log "Configuring Guest WiFi..."

    # Delete old profile if it exists
    if nmcli connection show "$WIFI_CONN_NAME" &>/dev/null; then
        nmcli connection delete "$WIFI_CONN_NAME" &>/dev/null
    fi

    # We add it as a connection first so we can manipulate metrics to protect SSH route
    if [ -n "$password" ]; then
        nmcli connection add type wifi con-name "$WIFI_CONN_NAME" ifname "$WIFI_IFACE" ssid "$ssid" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$password" >/dev/null
    else
        nmcli connection add type wifi con-name "$WIFI_CONN_NAME" ifname "$WIFI_IFACE" ssid "$ssid" >/dev/null
    fi

    # Prevent DHCP route hijacking by deprioritizing the WiFi default route
    log "Securing routing table (deprioritizing WiFi routes to protect SSH)..."
    nmcli connection modify "$WIFI_CONN_NAME" ipv4.route-metric 999 ipv6.route-metric 999 ipv4.never-default no ipv6.never-default no

    log "Connecting to $ssid..."
    if ! nmcli connection up "$WIFI_CONN_NAME"; then
        err "Failed to connect to WiFi."
        cleanup
        exit 1
    fi

    log "WiFi connection successful. Waiting to acquire DHCP..."
    sleep 5
    ip -br addr show dev "$WIFI_IFACE"

    WIFI_GW=$(ip route show default dev "$WIFI_IFACE" 2>/dev/null | awk '/default/ {print $3}')
    WIFI_IP=$(ip -4 addr show dev "$WIFI_IFACE" 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1)

    if [ -n "$WIFI_GW" ] && [ -n "$WIFI_IP" ]; then
        table_id=300
        log "Configuring Source-Based Routing for WiFi IP $WIFI_IP via $WIFI_GW (Table $table_id)..."
        ip route add default via "$WIFI_GW" dev "$WIFI_IFACE" table "$table_id" 2>/dev/null || true
        ip rule add from "$WIFI_IP" lookup "$table_id" 2>/dev/null || true
        log "Routing configured. Any traffic originating from $WIFI_IP will be forced through $WIFI_IFACE."
    else
        log "Warning: Could not detect WiFi IP or Gateway. Source-Based Routing not applied."
    fi

    rollback_timer
}

usage() {
    echo "======================================"
    echo "        Remote Network Manager        "
    echo "======================================"
    echo "Usage: $0 {vlan|wifi|cleanup}"
    echo "  vlan    - Interactive VLAN creation (batch support)"
    echo "  wifi    - Interactive Guest WiFi setup (DHCP-safe)"
    echo "  cleanup - Remove all VLANs and WiFi test profiles"
    echo "======================================"
}

if [ $# -eq 0 ]; then
    usage
    exit 1
fi

case "$1" in
    vlan)
        vlan_mode
        ;;
    wifi)
        wifi_mode
        ;;
    cleanup)
        CONFIRMED=1
        detect_primary_interface
        cleanup
        ;;
    *)
        usage
        exit 1
        ;;
esac
